import Foundation
import MicropodCore

/// A finished command: exit status and captured output.
public struct HVFCommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a command to completion; injected so the builder setup runs under
/// test without a docker CLI.
public protocol HVFCommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> HVFCommandResult
}

/// `Process`, with stdout and stderr drained concurrently and a deadline.
public struct HVFProcessRunner: HVFCommandRunning {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(60)) { self.timeout = timeout }

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String]) throws
        -> HVFCommandResult
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let captured = HVFCapturedOutput()
        let drained = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            drained.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                captured.set(data, stdout: isOut)
                drained.leave()
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw MicropodError.message(
                "deadlineExceeded: `\(executable.lastPathComponent) \(arguments.joined(separator: " "))` "
                    + "did not finish within \(timeout)")
        }
        _ = drained.wait(timeout: .now() + 5)
        let (stdout, stderr) = captured.values
        return HVFCommandResult(
            status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self))
    }
}

private final class HVFCapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(_ data: Data, stdout: Bool) {
        lock.withLock {
            if stdout { out = data } else { err = data }
        }
    }

    var values: (Data, Data) { lock.withLock { (out, err) } }
}

/// The fallback `docker build` path for engines that cannot serve it on
/// their Docker socket (no `/grpc`): a docker context `micropod` on the
/// machine's Docker socket and a remote buildx builder `micropod-buildkit`
/// on its BuildKit socket that loads every result into the current docker
/// endpoint (`default-load=true`), made the default builder of the
/// `micropod` context only, so the result lands in the machine.
///
/// It never changes the current docker context, buildx's current builder
/// or any other builder. `buildCommand` selects it: the docker CLI hands
/// `docker build` to buildx with `BUILDX_BUILDER=<current context>` unless
/// that is already set, so plain `docker --context micropod build` would
/// get the context's own docker-driver builder (which, for such an engine,
/// falls back to a docker-container builder that cannot run there).
/// `docker --context micropod buildx build` uses the context default too,
/// but buildx then rewrites its `current` file, forgetting a builder the
/// user chose without `--default` for another context. Each build costs a
/// tarball load (about 0.7–1 s for a 64 MB image) and leaves an
/// `import-<date>@sha256:…` image record.
///
/// Every call is idempotent; `remove` undoes exactly what `install`
/// created and leaves a same-named context or builder that points
/// elsewhere alone.
public struct HVFBuilderSetup: Sendable {
    /// The docker context on the machine's Docker socket.
    public static let contextName = "micropod"
    /// How to build through it, changing no buildx state.
    public static let buildCommand = "BUILDX_BUILDER=micropod-buildkit docker --context micropod build"
    /// The remote buildx builder on its BuildKit socket. Not the context's
    /// name: buildx gives every docker context an implicit builder of the
    /// same name and refuses `buildx create --name <context>` ("instance
    /// name … already exists as context builder").
    public static let builderName = "micropod-buildkit"

    public let layout: HVFMachineLayout
    public let docker: URL
    let environment: [String: String]
    let runner: any HVFCommandRunning

    public init(
        layout: HVFMachineLayout, docker: URL, environment: [String: String],
        runner: any HVFCommandRunning = HVFProcessRunner()
    ) {
        self.layout = layout
        self.docker = docker
        self.environment = environment
        self.runner = runner
    }

    /// With the docker CLI found on `PATH` (or `MICROPOD_DOCKER_CLI`).
    public init(
        layout: HVFMachineLayout, environment: [String: String],
        runner: any HVFCommandRunning = HVFProcessRunner()
    ) throws {
        guard let docker = Self.dockerCLI(environment: environment) else {
            throw MicropodError.message(
                "failedPrecondition: the docker CLI was not found on PATH (set MICROPOD_DOCKER_CLI to its path)")
        }
        self.init(layout: layout, docker: docker, environment: environment, runner: runner)
    }

    /// `MICROPOD_DOCKER_CLI`, else the first executable `docker` on `PATH`.
    public static func dockerCLI(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        if let configured = environment["MICROPOD_DOCKER_CLI"], !configured.isEmpty {
            return fileManager.isExecutableFile(atPath: configured) ? URL(fileURLWithPath: configured) : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("docker")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// buildx's state directory: `BUILDX_CONFIG`, else `$DOCKER_CONFIG/buildx`.
    var buildxDirectory: URL {
        if let configured = environment["BUILDX_CONFIG"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        let config =
            environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".docker").path
        return URL(fileURLWithPath: config).appendingPathComponent("buildx")
    }

    /// The CLI's environment: the caller's, without the selectors that
    /// would point a command somewhere other than where it says.
    var childEnvironment: [String: String] {
        var environment = self.environment
        environment["DOCKER_CONTEXT"] = nil
        environment["DOCKER_HOST"] = nil
        environment["BUILDX_BUILDER"] = nil
        return environment
    }

    // MARK: Status

    public enum Piece: String, Codable, Sendable, Equatable {
        /// Nothing by that name.
        case absent
        /// Present and pointing at this machine.
        case ok
        /// Present, but pointing somewhere else: not ours to change.
        case mismatch
    }

    public struct Status: Codable, Sendable, Equatable {
        /// docker context `micropod` → `unix://<root>/run/docker.sock`.
        public var context: Piece
        public var contextHost: String?
        /// buildx builder `micropod` → `unix://<root>/run/buildkit.sock`.
        public var builder: Piece
        public var builderEndpoint: String?
        public var builderDriver: String?
        /// The builder is the default of the `micropod` context.
        public var contextDefault: Bool

        public var installed: Bool { context == .ok && builder == .ok && contextDefault }
    }

    public func status() throws -> Status {
        let (context, host) = try contextState()
        let (builder, endpoint, driver) = try builderState()
        let contextDefault = context == .ok && builder == .ok && (try? defaultBuilderOfContext()) == Self.builderName
        return Status(
            context: context, contextHost: host, builder: builder, builderEndpoint: endpoint, builderDriver: driver,
            contextDefault: contextDefault)
    }

    private func docker(_ arguments: [String]) throws -> HVFCommandResult {
        try runner.run(docker, arguments, environment: childEnvironment)
    }

    private func failure(_ arguments: [String], _ result: HVFCommandResult) -> MicropodError {
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .message(
            "internal: `docker \(arguments.joined(separator: " "))` exited with status \(result.status): \(detail)")
    }

    /// docker context `micropod`: absent, this machine's, or another's
    /// (and the host it names). Never contacts BuildKit.
    public func contextState() throws -> (Piece, String?) {
        let arguments = ["context", "inspect", Self.contextName]
        let result = try docker(arguments)
        guard result.status == 0 else {
            if Self.saysMissing(result) { return (.absent, nil) }
            throw failure(arguments, result)
        }
        let host = Self.contextHost(fromInspect: result.stdout)
        return (host == layout.dockerEndpoint ? .ok : .mismatch, host)
    }

    func builderState() throws -> (Piece, String?, String?) {
        let arguments = ["buildx", "inspect", Self.builderName]
        let result = try docker(arguments)
        guard result.status == 0 else {
            if Self.saysMissing(result) { return (.absent, nil, nil) }
            throw failure(arguments, result)
        }
        let (endpoint, driver) = Self.builderEndpoint(fromInspect: result.stdout)
        return (endpoint == layout.buildkitEndpoint && driver == "remote" ? .ok : .mismatch, endpoint, driver)
    }

    /// The builder `docker --context micropod buildx build` would use. Asking
    /// buildx has a side effect: under a context with no default builder
    /// of its own, it resets its `current` file to that context, losing
    /// the selection the user made for theirs. So it runs inside
    /// `preservingCurrentBuilder`.
    func defaultBuilderOfContext() throws -> String? {
        let result = try preservingCurrentBuilder { try docker(["--context", Self.contextName, "buildx", "inspect"]) }
        guard result.status == 0 else { return nil }
        return Self.field("Name", in: result.stdout)
    }

    /// "context "x" does not exist", "no builder "x" found", "not found".
    static func saysMissing(_ result: HVFCommandResult) -> Bool {
        let text = (result.stderr + "\n" + result.stdout).lowercased()
        return text.contains("does not exist") || text.contains("not found") || text.contains("no builder")
    }

    /// `Endpoints.docker.Host` from `docker context inspect` (a JSON array).
    static func contextHost(fromInspect output: String) -> String? {
        guard let list = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [[String: Any]],
            let endpoints = list.first?["Endpoints"] as? [String: Any],
            let docker = endpoints["docker"] as? [String: Any]
        else { return nil }
        return docker["Host"] as? String
    }

    /// The first node's `Endpoint:` and the builder's `Driver:` from
    /// `docker buildx inspect`.
    static func builderEndpoint(fromInspect output: String) -> (endpoint: String?, driver: String?) {
        (field("Endpoint", in: output), field("Driver", in: output))
    }

    /// The first `Key: value` line's value.
    static func field(_ key: String, in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + ":") else { continue }
            let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: Install

    /// Creates whatever is missing; returns what it did, one line each.
    public func install() throws -> [String] {
        let missing = layout.missingBuildKitFiles()
        guard missing.isEmpty else {
            throw MicropodError.message(
                "failedPrecondition: the tool bundle in \(layout.tools.path) lacks buildkitd (missing "
                    + "\(missing.joined(separator: ", "))): there is no BuildKit for a builder to use")
        }
        // Both checked before anything is created: a refusal changes nothing.
        let context = try contextState()
        let builder = try builderState()
        if case (.mismatch, let host) = context {
            throw MicropodError.message(
                "failedPrecondition: docker context '\(Self.contextName)' already exists and points at "
                    + "\(host ?? "another endpoint"), not \(layout.dockerEndpoint); remove it "
                    + "(`docker context rm \(Self.contextName)`) and run this again")
        }
        if case (.mismatch, let endpoint, let driver) = builder {
            throw MicropodError.message(
                "failedPrecondition: buildx builder '\(Self.builderName)' already exists (driver \(driver ?? "?"), endpoint "
                    + "\(endpoint ?? "?")), not a remote builder on \(layout.buildkitEndpoint); remove it "
                    + "(`docker buildx rm \(Self.builderName)`) and run this again")
        }
        var done: [String] = []
        if context.0 == .ok {
            done.append("docker context '\(Self.contextName)' already points at \(layout.dockerEndpoint)")
        } else {
            let arguments = [
                "context", "create", Self.contextName, "--description", "micropod hvf machine (\(layout.root.path))",
                "--docker", "host=\(layout.dockerEndpoint)",
            ]
            let result = try docker(arguments)
            guard result.status == 0 else { throw failure(arguments, result) }
            done.append("created docker context '\(Self.contextName)' → \(layout.dockerEndpoint)")
        }
        if builder.0 == .ok {
            done.append("buildx builder '\(Self.builderName)' already uses \(layout.buildkitEndpoint)")
        } else {
            let arguments = [
                "buildx", "create", "--name", Self.builderName, "--driver", "remote", "--driver-opt",
                "default-load=true",
                layout.buildkitEndpoint,
            ]
            let result = try docker(arguments)
            guard result.status == 0 else { throw failure(arguments, result) }
            done.append(
                "created buildx builder '\(Self.builderName)' (remote, default-load) → \(layout.buildkitEndpoint)")
        }
        if (try? defaultBuilderOfContext()) == Self.builderName {
            done.append("'\(Self.builderName)' is already the default builder of docker context '\(Self.contextName)'")
        } else {
            // `buildx use` always rewrites buildx's `current` file, the
            // selection of whatever context the user works in; keep theirs.
            // Once the context has a default builder of its own, buildx no
            // longer resets `current` when it is used.
            let arguments = ["--context", Self.contextName, "buildx", "use", "--default", Self.builderName]
            let result = try preservingCurrentBuilder { try docker(arguments) }
            guard result.status == 0 else { throw failure(arguments, result) }
            done.append("made '\(Self.builderName)' the default builder of docker context '\(Self.contextName)' only")
        }
        return done
    }

    // MARK: Remove

    /// Removes the builder and the context if they are this machine's.
    public func remove() throws -> [String] {
        var done: [String] = []
        switch try builderState() {
        case (.ok, _, _):
            let arguments = ["buildx", "rm", Self.builderName]
            let result = try preservingCurrentBuilder(unlessItNames: Self.builderName) { try docker(arguments) }
            guard result.status == 0 else { throw failure(arguments, result) }
            done.append("removed buildx builder '\(Self.builderName)'")
        case (.mismatch, let endpoint, _):
            done.append(
                "left buildx builder '\(Self.builderName)' alone: it is not this machine's (\(endpoint ?? "?"))")
        case (.absent, _, _):
            done.append("no buildx builder '\(Self.builderName)'")
        }
        switch try contextState() {
        case (.ok, _):
            let arguments = ["context", "rm", Self.contextName]
            let result = try docker(arguments)
            guard result.status == 0 else { throw failure(arguments, result) }
            done.append("removed docker context '\(Self.contextName)'")
        case (.mismatch, let host):
            done.append("left docker context '\(Self.contextName)' alone: it is not this machine's (\(host ?? "?"))")
        case (.absent, _):
            done.append("no docker context '\(Self.contextName)'")
        }
        return done
    }

    /// Runs `body`, then puts buildx's `current` file back as it was (or
    /// removes it if there was none), unless the saved one selected
    /// `unlessItNames`: that builder is being removed.
    func preservingCurrentBuilder<T>(unlessItNames removed: String? = nil, _ body: () throws -> T) throws -> T {
        let current = buildxDirectory.appendingPathComponent("current")
        let saved = try? Data(contentsOf: current)
        let result = try body()
        if let saved {
            let selected = (try? JSONSerialization.jsonObject(with: saved)) as? [String: Any]
            if removed == nil || selected?["Name"] as? String != removed {
                let now = try? Data(contentsOf: current)
                if now != saved { try HVFFiles.writeAtomically(saved, to: current, mode: 0o600) }
            }
        } else if FileManager.default.fileExists(atPath: current.path) {
            try FileManager.default.removeItem(at: current)
        }
        return result
    }
}
