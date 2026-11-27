import Darwin
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
/// elsewhere alone. `HVFDockerWiring` (`micropod docker …`) builds the
/// user-facing wiring from `ensureContext` and `ensureBuilder`.
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
        return (Self.sameEndpoint(host, layout.dockerEndpoint) ? .ok : .mismatch, host)
    }

    func builderState() throws -> (Piece, String?, String?) {
        guard let state = try builderStateIfBuildx() else {
            throw MicropodError.message(
                "failedPrecondition: the docker buildx plugin was not found: a buildx builder needs it")
        }
        return state
    }

    /// `builderState`, or nil when the docker CLI has no buildx plugin (so
    /// no builder can exist through it).
    func builderStateIfBuildx() throws -> (Piece, String?, String?)? {
        let arguments = ["buildx", "inspect", Self.builderName]
        let result = try docker(arguments)
        guard result.status == 0 else {
            if Self.saysNoBuildx(result) { return nil }
            if Self.saysMissing(result) { return (.absent, nil, nil) }
            throw failure(arguments, result)
        }
        let (endpoint, driver) = Self.builderEndpoint(fromInspect: result.stdout)
        let ours = Self.sameEndpoint(endpoint, layout.buildkitEndpoint) && driver == "remote"
        return (ours ? .ok : .mismatch, endpoint, driver)
    }

    /// "docker: unknown command: docker buildx" (docker 25 and later), or
    /// "docker: 'buildx' is not a docker command." (earlier).
    static func saysNoBuildx(_ result: HVFCommandResult) -> Bool {
        let text = (result.stderr + "\n" + result.stdout).lowercased()
        return text.contains("unknown command: docker buildx") || text.contains("'buildx' is not a docker command")
    }

    /// Two docker endpoints name the same socket: equal, or `unix://` paths
    /// that resolve to one file, so `/tmp/x` and `/private/tmp/x` (or a
    /// link to the socket) are the same machine. A path is resolved as far
    /// as it exists: a stopped machine has no socket file yet.
    public static func sameEndpoint(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }
        let scheme = "unix://"
        guard lhs.hasPrefix(scheme), rhs.hasPrefix(scheme) else { return false }
        return resolvedPath(String(lhs.dropFirst(scheme.count)))
            == resolvedPath(String(rhs.dropFirst(scheme.count)))
    }

    /// `path` with every symlink in its existing prefix resolved and the
    /// components that do not exist yet appended unchanged.
    static func resolvedPath(_ path: String) -> String {
        var head = path
        var tail: [String] = []
        while !head.isEmpty {
            if let real = realpath(head, nil) {
                defer { free(real) }
                return tail.reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
            }
            let parent = (head as NSString).deletingLastPathComponent
            guard parent != head else { break }
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = parent
        }
        return path
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
        try requireBuildKit()
        // Both checked before anything is created: a refusal changes nothing.
        let context = try contextState()
        let builder = try builderState()
        if case (.mismatch, let host) = context {
            throw contextRefusal(
                host: host, remedy: "remove it (`docker context rm \(Self.contextName)`) and run this again")
        }
        try refuseForeignBuilder(builder)
        var done: [String] = []
        switch try applyContext(context, force: false) {
        case .present:
            done.append("docker context '\(Self.contextName)' already points at \(layout.dockerEndpoint)")
        case .created, .updated:
            done.append("created docker context '\(Self.contextName)' → \(layout.dockerEndpoint)")
        }
        done += try applyBuilder(builder)
        return done
    }

    /// What `ensureContext` did to docker context `micropod`.
    public enum ContextChange: String, Codable, Sendable, Equatable {
        case created
        /// It already pointed at this machine.
        case present
        /// It pointed elsewhere and `force` repointed it.
        case updated
    }

    /// docker context `micropod` on this machine's Docker socket, created
    /// when absent. One that points elsewhere is refused, naming its host,
    /// unless `force` repoints it (`docker context update`).
    public func ensureContext(force: Bool) throws -> ContextChange {
        try applyContext(try contextState(), force: force)
    }

    /// The remote builder `micropod-buildkit` on this machine's BuildKit
    /// socket, made the default builder of context `micropod` only. Refuses
    /// a bundle without BuildKit and a same-named builder that is not ours
    /// before creating anything.
    public func ensureBuilder() throws -> [String] {
        try requireBuildKit()
        let builder = try builderState()
        try refuseForeignBuilder(builder)
        return try applyBuilder(builder)
    }

    func requireBuildKit() throws {
        let missing = layout.missingBuildKitFiles()
        guard missing.isEmpty else {
            throw MicropodError.message(
                "failedPrecondition: the tool bundle in \(layout.tools.path) lacks buildkitd (missing "
                    + "\(missing.joined(separator: ", "))): there is no BuildKit for a builder to use")
        }
    }

    func contextRefusal(host: String?, remedy: String) -> MicropodError {
        .message(
            "failedPrecondition: docker context '\(Self.contextName)' already exists and points at "
                + "\(host ?? "another endpoint"), not \(layout.dockerEndpoint); \(remedy)")
    }

    func refuseForeignBuilder(_ builder: (Piece, String?, String?)) throws {
        if case (.mismatch, let endpoint, let driver) = builder {
            throw MicropodError.message(
                "failedPrecondition: buildx builder '\(Self.builderName)' already exists (driver \(driver ?? "?"), endpoint "
                    + "\(endpoint ?? "?")), not a remote builder on \(layout.buildkitEndpoint); remove it "
                    + "(`docker buildx rm \(Self.builderName)`) and run this again")
        }
    }

    /// The context as `state` found it, made to point here.
    func applyContext(_ state: (Piece, String?), force: Bool) throws -> ContextChange {
        let description = "micropod hvf machine (\(layout.root.path))"
        let arguments: [String]
        let change: ContextChange
        switch state {
        case (.ok, _):
            return .present
        case (.mismatch, let host):
            guard force else {
                throw contextRefusal(host: host, remedy: "pass --force to point it at this machine")
            }
            arguments = [
                "context", "update", Self.contextName, "--description", description,
                "--docker", "host=\(layout.dockerEndpoint)",
            ]
            change = .updated
        case (.absent, _):
            arguments = [
                "context", "create", Self.contextName, "--description", description,
                "--docker", "host=\(layout.dockerEndpoint)",
            ]
            change = .created
        }
        let result = try docker(arguments)
        guard result.status == 0 else { throw failure(arguments, result) }
        return change
    }

    /// The builder as `builder` found it (absent or ours), created and made
    /// the default of context `micropod`.
    func applyBuilder(_ builder: (Piece, String?, String?)) throws -> [String] {
        var done: [String] = []
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

    /// Removes the builder and the context if they are this machine's. A
    /// selected `micropod` context is first replaced by the one
    /// `micropod docker install --use` recorded (else `default`): the docker
    /// CLI refuses to remove the context in use. `HVFDockerWiring.uninstall`.
    public func remove() throws -> [String] {
        try HVFDockerWiring(setup: self).uninstall(force: false).actions
    }

    /// `micropod-buildkit` removed when it is this machine's; one line.
    func removeBuilderIfOurs() throws -> String {
        guard let state = try builderStateIfBuildx() else {
            return "no buildx plugin: no buildx builder to remove"
        }
        switch state {
        case (.ok, _, _):
            let arguments = ["buildx", "rm", Self.builderName]
            let result = try preservingCurrentBuilder(unlessItNames: Self.builderName) { try docker(arguments) }
            guard result.status == 0 else { throw failure(arguments, result) }
            return "removed buildx builder '\(Self.builderName)'"
        case (.mismatch, let endpoint, _):
            return "left buildx builder '\(Self.builderName)' alone: it is not this machine's (\(endpoint ?? "?"))"
        case (.absent, _, _):
            return "no buildx builder '\(Self.builderName)'"
        }
    }

    /// The docker CLI with `arguments`, failing on a non-zero exit.
    func dockerChecked(_ arguments: [String]) throws -> HVFCommandResult {
        let result = try docker(arguments)
        guard result.status == 0 else { throw failure(arguments, result) }
        return result
    }

    /// The docker CLI with `arguments`, whatever it exits with.
    func dockerUnchecked(_ arguments: [String]) throws -> HVFCommandResult {
        try docker(arguments)
    }

    /// Restores buildx's current selection even if the command fails. A
    /// successful removal may clear the selection of the removed builder.
    func preservingCurrentBuilder(
        unlessItNames removed: String? = nil, _ body: () throws -> HVFCommandResult
    ) throws -> HVFCommandResult {
        let current = buildxDirectory.appendingPathComponent("current")
        let saved: Data?
        do {
            saved = try Data(contentsOf: current)
        } catch CocoaError.fileReadNoSuchFile {
            saved = nil
        }
        let result = Result(catching: body)
        if let saved {
            let selected = (try? JSONSerialization.jsonObject(with: saved)) as? [String: Any]
            let removedSelection =
                removed != nil && selected?["Name"] as? String == removed
                && (try? result.get().status) == 0
            if !removedSelection, (try? Data(contentsOf: current)) != saved {
                try HVFFiles.writeAtomically(saved, to: current, mode: 0o600)
            }
        } else if unlink(current.path) != 0, errno != ENOENT {
            throw HVFFiles.posixError("unlink \(current.path)")
        }
        return try result.get()
    }
}
