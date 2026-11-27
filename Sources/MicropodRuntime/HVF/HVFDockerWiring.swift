import CryptoKit
import Darwin
import Foundation
import MicropodCore

/// `micropod docker install|uninstall|status`: the docker CLI, compose and
/// buildx pointed at the hvf machine the way Docker Desktop and OrbStack
/// users expect, through a docker context named `micropod` on
/// `<root>/run/docker.sock`.
///
/// Everything goes through the docker CLI (`MICROPOD_DOCKER_CLI`, else
/// `docker` on `PATH`); no docker file is written by hand, so
/// `DOCKER_CONFIG` decides whose configuration changes. The current
/// context changes only with `use`; the one it replaced is recorded in
/// `<root>/docker-wiring.json` and `uninstall` selects it again. Nothing
/// here starts the machine, and nothing runs `sudo`: the
/// `/var/run/docker.sock` link is advice for the user to run.
public struct HVFDockerWiring: Sendable {
    public static let contextName = HVFBuilderSetup.contextName
    public static let recordFileName = "docker-wiring.json"
    /// The guest engine's `MinAPIVersion`: an older docker CLI is refused.
    public static let minimumClientAPI = "1.44"
    /// Contexts other Docker runtimes on a Mac create.
    public static let otherRuntimeContexts = ["desktop-linux", "orbstack", "colima", "rancher-desktop"]
    /// Where Homebrew and /usr/local installs put docker CLI plugins, which
    /// a docker CLI does not search unless `cliPluginsExtraDirs` names them.
    public static let pluginDirectories = ["/opt/homebrew/lib/docker/cli-plugins", "/usr/local/lib/docker/cli-plugins"]
    public static let systemSocketPath = "/var/run/docker.sock"

    /// Which buildx builder `docker build` on context `micropod` uses.
    public enum BuilderMode: String, Codable, Sendable, CaseIterable {
        /// The context's own builder when the engine builds on its Docker
        /// socket, else `remote`.
        case auto
        /// `micropod-buildkit`, a remote builder on the BuildKit socket.
        case remote
        /// No builder is added.
        case none
    }

    /// The machine as the caller found it. Passed in, never probed here:
    /// the wiring neither boots nor contacts the machine.
    public struct Machine: Sendable, Equatable {
        public var missing: [String]
        public var phase: HVFMachinePhase
        public var dockerBuild: HVFMachineCapabilities.DockerBuild

        public var installed: Bool { missing.isEmpty }

        public init(missing: [String], phase: HVFMachinePhase, dockerBuild: HVFMachineCapabilities.DockerBuild) {
            self.missing = missing
            self.phase = phase
            self.dockerBuild = dockerBuild
        }
    }

    /// `<root>/docker-wiring.json`: what `install` did that `uninstall`
    /// undoes.
    public struct Record: Codable, Sendable, Equatable {
        /// The context `install --use` replaced; never `micropod`.
        public var previousContext: String?
        /// `install --use` selected `micropod`.
        public var selectedByMicropod: Bool
        /// `install` set up `micropod-buildkit`.
        public var builderInstalled: Bool
        public var endpoint: String
        public var installedAt: Date

        public init(
            previousContext: String?, selectedByMicropod: Bool, builderInstalled: Bool, endpoint: String,
            installedAt: Date
        ) {
            self.previousContext = previousContext
            self.selectedByMicropod = selectedByMicropod
            self.builderInstalled = builderInstalled
            self.endpoint = endpoint
            self.installedAt = installedAt
        }
    }

    /// What `install` or `uninstall` did.
    public struct Outcome: Codable, Sendable, Equatable {
        /// One line per thing done or found, for stdout.
        public var actions: [String]
        /// Problems that do not fail the command, for stderr as `note:`.
        public var notes: [String]
        /// Commands for the user to run (they need sudo); never run.
        public var manual: [String]
    }

    public let layout: HVFMachineLayout
    /// nil when no docker CLI was found.
    public let docker: URL?
    let environment: [String: String]
    let runner: any HVFCommandRunning
    let systemSocket: String
    /// Where a plugin the CLI did not find is looked for, for the hint.
    var pluginSearch = Self.pluginDirectories

    public init(
        layout: HVFMachineLayout, environment: [String: String],
        runner: any HVFCommandRunning = HVFProcessRunner(), systemSocket: String = Self.systemSocketPath
    ) {
        self.init(
            layout: layout, docker: HVFBuilderSetup.dockerCLI(environment: environment), environment: environment,
            runner: runner, systemSocket: systemSocket)
    }

    public init(
        layout: HVFMachineLayout, docker: URL?, environment: [String: String],
        runner: any HVFCommandRunning = HVFProcessRunner(), systemSocket: String = Self.systemSocketPath
    ) {
        self.layout = layout
        self.docker = docker
        self.environment = environment
        self.runner = runner
        self.systemSocket = systemSocket
    }

    init(setup: HVFBuilderSetup) {
        self.init(
            layout: setup.layout, docker: setup.docker, environment: setup.environment, runner: setup.runner)
    }

    public var recordURL: URL { layout.root.appendingPathComponent(Self.recordFileName) }

    /// The docker CLI's configuration directory: `DOCKER_CONFIG`, else
    /// `~/.docker`. Read for credential helpers only; never written.
    var configDirectory: URL {
        if let configured = environment["DOCKER_CONFIG"], !configured.isEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".docker")
    }

    private func setup(_ docker: URL) -> HVFBuilderSetup {
        HVFBuilderSetup(layout: layout, docker: docker, environment: environment, runner: runner)
    }

    private func noCLI(_ consequence: String) -> MicropodError {
        .message(
            "failedPrecondition: the docker CLI was not found on PATH (set MICROPOD_DOCKER_CLI to its path). "
                + consequence)
    }

    // MARK: Record

    /// nil when there is none; throws when it does not parse.
    public func loadRecord() throws -> Record? {
        let data: Data
        do {
            data = try Data(contentsOf: recordURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Record.self, from: data)
    }

    func saveRecord(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try HVFFiles.writeAtomically(try encoder.encode(record), to: recordURL, mode: 0o600)
    }

    /// The record, or nil with a note when it is unreadable.
    private func readRecord(_ notes: inout [String]) -> Record? {
        do {
            return try loadRecord()
        } catch {
            notes.append("ignored \(recordURL.path), which does not parse (\(error.localizedDescription))")
            return nil
        }
    }

    // MARK: Install

    /// docker context `micropod` on this machine, the builder `mode` asks
    /// for, and with `use` the context selected. The machine may be stopped;
    /// it is not started.
    public func install(use: Bool, builder mode: BuilderMode, force: Bool, machine: Machine) throws -> Outcome {
        guard let docker else {
            throw noCLI("Without it: export DOCKER_HOST=\(layout.dockerEndpoint)")
        }
        let setup = setup(docker)
        var notes: [String] = []
        let wantsRemote = mode == .remote || (mode == .auto && machine.dockerBuild == .fallback)
        // Checked before anything changes: a refusal changes nothing.
        let context = try setup.contextState()
        if case (.mismatch, let host) = context, !force {
            throw setup.contextRefusal(host: host, remedy: "pass --force to point it at this machine")
        }
        var builderState: (HVFBuilderSetup.Piece, String?, String?)?
        var builderLine = "builder: \(Self.builderSummary(machine))"
        if wantsRemote {
            try setup.requireBuildKit()
            if let state = try setup.builderStateIfBuildx() {
                try setup.refuseForeignBuilder(state)
                builderState = state
            } else if mode == .remote {
                throw MicropodError.message(
                    "failedPrecondition: the docker buildx plugin was not found, and the remote builder "
                        + "\(HVFBuilderSetup.builderName) needs it\(pluginHint("docker-buildx"))")
            } else {
                builderLine =
                    "builder: none (this engine builds only on \(HVFBuilderSetup.builderName), which needs the "
                    + "docker buildx plugin: install it, then run `micropod docker install` again)"
            }
        }
        let previous = readRecord(&notes)

        var actions: [String] = []
        let change = try setup.applyContext(context, force: force)
        actions.append("docker context \(Self.contextName) -> \(layout.dockerEndpoint) (\(change.rawValue))")
        var builderInstalled = previous?.builderInstalled ?? false
        if let builderState {
            let created = builderState.0 == .absent
            _ = try setup.applyBuilder(builderState)
            builderInstalled = true
            builderLine =
                "builder: \(HVFBuilderSetup.builderName) (remote, \(created ? "created" : "present"), the default of "
                + "context \(Self.contextName) only) -> \(layout.buildkitEndpoint)"
        }
        actions.append(builderLine)

        var record = Record(
            previousContext: previous?.previousContext, selectedByMicropod: previous?.selectedByMicropod ?? false,
            builderInstalled: builderInstalled, endpoint: layout.dockerEndpoint,
            installedAt: previous?.installedAt ?? Date())
        let current = try currentContext(setup)
        let selection: String
        if use, current != Self.contextName {
            _ = try setup.dockerChecked(["context", "use", Self.contextName])
            record.previousContext = current
            record.selectedByMicropod = true
            selection =
                "current context: \(Self.contextName) (was \(current); `micropod docker uninstall` restores it)"
        } else if current == Self.contextName {
            let restores = record.previousContext.map { "; `micropod docker uninstall` restores \($0)" } ?? ""
            selection = "current context: \(Self.contextName) (already selected\(restores))"
        } else {
            selection =
                "current context: \(current) (unchanged; select with `micropod docker install --use` or "
                + "`docker context use \(Self.contextName)`)"
        }
        try saveRecord(record)

        let client = probeClient(setup)
        let compose = probeCompose(setup)
        let buildx = probeBuildx(setup)
        actions.append("compose: \(compose.version ?? "missing")    buildx: \(buildx.version ?? "missing")")
        actions.append(selection)
        notes += commonNotes(client: client, compose: compose, buildx: buildx, machine: machine)
        return Outcome(actions: actions, notes: notes, manual: [])
    }

    /// The `builder:` line when `micropod-buildkit` is not in use.
    static func builderSummary(_ machine: Machine) -> String {
        guard machine.installed else {
            return "none yet (the machine is not installed; run `micropod docker install` again once it is)"
        }
        switch machine.dockerBuild {
        case .ready:
            return "the context's own builder (the engine builds on its Docker socket)"
        case .fallback:
            return
                "none (this engine cannot build on its Docker socket: `micropod docker install --builder remote` adds "
                + "\(HVFBuilderSetup.builderName))"
        case .unavailable:
            return "none (the machine's tool bundle has no BuildKit: docker build does not work on it)"
        }
    }

    // MARK: Uninstall

    /// Undoes `install`, in order: the selection (when `micropod` is
    /// current, the recorded previous context if it still exists, else
    /// `default`), the builder if it is this machine's, the context if it
    /// is this machine's (`force`: whatever it points at), the record. A
    /// `/var/run/docker.sock` that still leads here is reported in
    /// `manual`, not removed.
    public func uninstall(force: Bool) throws -> Outcome {
        guard let docker else {
            throw noCLI("Nothing was removed; without it, remove the context yourself: `docker context rm micropod`")
        }
        let setup = setup(docker)
        var notes: [String] = []
        var actions: [String] = []
        let record = readRecord(&notes)
        let context = try setup.contextState()
        let ours = context.0 == .ok || (context.0 == .mismatch && force)
        if ours, try currentContext(setup) == Self.contextName {
            var target = record?.previousContext ?? "default"
            var why = "restored"
            if target != "default", try !contextExists(target, setup) {
                why = "the previous context '\(target)' no longer exists"
                target = "default"
            } else if record?.previousContext == nil {
                why = "no previous context was recorded"
            }
            _ = try setup.dockerChecked(["context", "use", target])
            actions.append("current context: \(target) (\(why))")
        }
        actions.append(try setup.removeBuilderIfOurs())
        switch context {
        case (.absent, _):
            actions.append("no docker context '\(Self.contextName)'")
        case (.mismatch, let host) where !force:
            actions.append(
                "left docker context '\(Self.contextName)' alone: it is not this machine's (\(host ?? "?")); "
                    + "--force removes it")
        case (.ok, _), (.mismatch, _):
            _ = try setup.dockerChecked(["context", "rm", Self.contextName])
            actions.append("removed docker context '\(Self.contextName)'")
        }
        if context.0 != .mismatch || force {
            if unlink(recordURL.path) == 0 {
                actions.append("removed \(recordURL.path)")
            } else if errno != ENOENT {
                throw HVFFiles.posixError("unlink \(recordURL.path)")
            }
        }
        var manual: [String] = []
        if let target = linkTarget(systemSocket), leadsHere(target) {
            manual = [
                "\(systemSocket) still points at this machine (\(target)); remove it yourself (needs sudo):",
                "  sudo rm \(systemSocket)",
            ]
        }
        return Outcome(actions: actions, notes: notes, manual: manual)
    }

    func currentContext(_ setup: HVFBuilderSetup) throws -> String {
        let result = try setup.dockerChecked(["context", "show"])
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "default" : name
    }

    func contextExists(_ name: String, _ setup: HVFBuilderSetup) throws -> Bool {
        let arguments = ["context", "inspect", name]
        let result = try setup.dockerUnchecked(arguments)
        if result.status == 0 { return true }
        if HVFBuilderSetup.saysMissing(result) { return false }
        _ = try setup.dockerChecked(arguments)
        return false
    }

    // MARK: /var/run/docker.sock

    /// The command that would point `/var/run/docker.sock` here, for the
    /// user to run; nothing is run.
    public func systemSocketAdvice() -> [String] {
        let now = describeSystemSocket()
        if let target = linkTarget(systemSocket), leadsHere(target) {
            return ["\(systemSocket) already points at this machine (\(target))"]
        }
        return [
            "To serve clients that ignore contexts, run this yourself (needs sudo; it may not survive a restart, "
                + "so check it after one):",
            "  sudo ln -sfn \(layout.dockerSocket.path) \(systemSocket)",
            "\(systemSocket) now: \(now)",
        ]
    }

    /// `-> <target> (<owner>)`, `absent`, or what is there instead of a link.
    func describeSystemSocket() -> String {
        if let target = linkTarget(systemSocket) {
            return "-> \(target)" + (socketOwner(target).map { " (\($0))" } ?? "")
        }
        var info = stat()
        guard lstat(systemSocket, &info) == 0 else { return "absent" }
        return info.st_mode & S_IFMT == S_IFSOCK ? "a socket, not a link" : "a file, not a link"
    }

    /// Which runtime a socket path belongs to, when it is a known one.
    func socketOwner(_ path: String) -> String? {
        if leadsHere(path) { return "this machine" }
        if path.contains("/.docker/run/") { return "Docker Desktop" }
        if path.contains("/.orbstack/") { return "OrbStack" }
        if path.contains("/.colima/") { return "Colima" }
        if path.contains("/.rd/") { return "Rancher Desktop" }
        if path.contains("/.micropod/") { return "micropod" }
        return nil
    }

    /// A socket path that is this machine's socket or the canonical link
    /// to it.
    func leadsHere(_ path: String) -> Bool {
        HVFBuilderSetup.sameEndpoint("unix://" + path, layout.dockerEndpoint)
    }

    func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    // MARK: Status

    public struct Status: Codable, Sendable, Equatable {
        public struct CLI: Codable, Sendable, Equatable {
            /// nil: no docker CLI was found.
            public var path: String?
            public var version: String?
            /// The API version this CLI sends (`DOCKER_API_VERSION` lowers it).
            public var apiVersion: String?
            /// Below the engine's minimum, `minimumClientAPI`.
            public var tooOld: Bool
        }

        public struct Context: Codable, Sendable, Equatable {
            /// nil when it could not be read (no docker CLI, or it failed).
            public var state: HVFBuilderSetup.Piece?
            public var host: String?
            public var error: String?
        }

        public struct Plugin: Codable, Sendable, Equatable {
            /// nil: missing (or it does not run).
            public var version: String?
            public var error: String?
        }

        public struct CredentialHelper: Codable, Sendable, Equatable {
            /// `credsStore`, or the registry a `credHelpers` entry names.
            public var key: String
            public var name: String
            /// `docker-credential-<name>` is an executable on `PATH`.
            public var found: Bool
        }

        public struct OtherRuntime: Codable, Sendable, Equatable {
            public var name: String
            public var endpoint: String?
        }

        public struct Link: Codable, Sendable, Equatable {
            public var path: String
            /// nil: no symlink there.
            public var target: String?
            /// `describeSystemSocket`, for the system socket.
            public var summary: String
        }

        /// `unix://<root>/run/docker.sock`.
        public var endpoint: String
        public var dockerCLI: CLI
        public var context: Context
        public var currentContext: String?
        /// `micropod` is the current context and points here.
        public var selected: Bool
        /// From the record: what `uninstall` selects again.
        public var previousContext: String?
        public var recorded: Bool
        /// `DOCKER_HOST`, `DOCKER_CONTEXT`, `DOCKER_API_VERSION` and
        /// `BUILDX_BUILDER` as the caller's environment sets them.
        public var environmentOverride: [String: String]
        public var compose: Plugin
        public var buildx: Plugin
        /// The `builder:` line.
        public var builder: String
        /// `micropod-buildkit`; nil when buildx was not asked.
        public var remoteBuilder: HVFBuilderSetup.Piece?
        public var dockerBuild: HVFMachineCapabilities.DockerBuild
        /// `credsStore` and `credHelpers` from `config.json`.
        public var credentialHelpers: [CredentialHelper]
        public var otherRuntimes: [OtherRuntime]
        /// `~/.micropod/docker.sock` (or `MICROPOD_DOCKER_SOCK`).
        public var canonicalLink: Link
        /// `/var/run/docker.sock`.
        public var systemSocket: Link
        public var machinePhase: String
        public var machineInstalled: Bool
        public var notes: [String]
    }

    /// Everything `micropod docker status` shows. Never throws, never
    /// changes anything, never boots the machine.
    public func status(machine: Machine) -> Status {
        var notes: [String] = []
        let record = readRecord(&notes)
        let canonical = HVFMachineLayout.canonicalDockerSocket(environment: environment).path
        var status = Status(
            endpoint: layout.dockerEndpoint,
            dockerCLI: .init(path: docker?.path, version: nil, apiVersion: nil, tooOld: false),
            context: .init(state: nil, host: nil, error: nil), currentContext: nil, selected: false,
            previousContext: record?.previousContext, recorded: record != nil,
            environmentOverride: Self.overrideKeys.reduce(into: [:]) { found, key in
                if let value = environment[key], !value.isEmpty { found[key] = value }
            },
            compose: .init(version: nil, error: nil), buildx: .init(version: nil, error: nil), builder: "",
            remoteBuilder: nil, dockerBuild: machine.dockerBuild, credentialHelpers: credentialHelpers(),
            otherRuntimes: [],
            canonicalLink: .init(
                path: canonical, target: linkTarget(canonical),
                summary: linkTarget(canonical).map { "-> \($0)" } ?? "absent"),
            systemSocket: .init(path: systemSocket, target: linkTarget(systemSocket), summary: describeSystemSocket()),
            machinePhase: machine.installed ? machine.phase.rawValue : "not installed",
            machineInstalled: machine.installed, notes: [])
        guard let docker else {
            status.builder = Self.builderSummary(machine)
            status.notes =
                notes + [
                    "the docker CLI was not found on PATH (set MICROPOD_DOCKER_CLI to its path); without it: "
                        + "export DOCKER_HOST=\(layout.dockerEndpoint)"
                ] + machineNotes(machine)
            return status
        }
        let setup = setup(docker)
        let client = probeClient(setup)
        status.dockerCLI = client
        do {
            let (piece, host) = try setup.contextState()
            status.context = .init(state: piece, host: host, error: nil)
        } catch {
            status.context.error = error.localizedDescription
        }
        status.currentContext = try? currentContext(setup)
        status.selected = status.currentContext == Self.contextName && status.context.state == .ok
        status.otherRuntimes = otherRuntimes(setup)
        status.compose = probeCompose(setup)
        status.buildx = probeBuildx(setup)
        if status.buildx.version != nil {
            status.remoteBuilder = (try? setup.builderState())?.0
        }
        if status.remoteBuilder == .ok {
            status.builder =
                "\(HVFBuilderSetup.builderName) (remote) -> \(layout.buildkitEndpoint)"
                + (machine.dockerBuild == .ready ? "; the engine also builds on its Docker socket" : "")
        } else {
            status.builder = Self.builderSummary(machine)
        }
        if status.context.state == .mismatch {
            notes.append(
                "docker context \(Self.contextName) points at \(status.context.host ?? "another endpoint"), not this "
                    + "machine: `micropod docker install --force` repoints it")
        }
        status.notes =
            notes + commonNotes(client: client, compose: status.compose, buildx: status.buildx, machine: machine)
        return status
    }

    static let overrideKeys = ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_API_VERSION", "BUILDX_BUILDER"]

    // MARK: The store, read without the CLI

    /// Docker context `micropod` as the docker CLI's own files have it now.
    public struct StoredContext: Codable, Sendable, Equatable {
        /// The context's docker host; nil when there is no such context.
        public var host: String?
        /// It points at this machine.
        public var pointsHere: Bool
        /// The context a plain `docker` in this environment uses.
        public var current: String

        public var exists: Bool { host != nil }
        /// A plain `docker` reaches this machine through the context.
        public var selected: Bool { pointsHere && current == HVFDockerWiring.contextName }

        public init(host: String?, pointsHere: Bool, current: String) {
            self.host = host
            self.pointsHere = pointsHere
            self.current = current
        }
    }

    /// The context and the selection read from the docker CLI's files,
    /// without running it (`micropod status` starts no process):
    /// `contexts/meta/<sha256 of the name>/meta.json` and `currentContext`
    /// in `config.json`, with the precedence the CLI gives the shell's
    /// `DOCKER_CONTEXT` and `DOCKER_HOST`. The record only says what
    /// `install` did; the user may have switched or removed the context
    /// since. Nothing is written.
    public func storedContext() -> StoredContext {
        let digest = SHA256.hash(data: Data(Self.contextName.utf8)).map { String(format: "%02x", $0) }.joined()
        let meta = configDirectory.appendingPathComponent("contexts/meta/\(digest)/meta.json")
        var host: String?
        if let data = try? Data(contentsOf: meta),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            let endpoint = (json["Endpoints"] as? [String: Any])?["docker"] as? [String: Any]
            host = endpoint?["Host"] as? String ?? ""
        }
        let current: String
        if let name = environment["DOCKER_CONTEXT"], !name.isEmpty {
            current = name
        } else if let override = environment["DOCKER_HOST"], !override.isEmpty {
            current = "default"
        } else if let data = try? Data(contentsOf: configDirectory.appendingPathComponent("config.json")),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let name = json["currentContext"] as? String, !name.isEmpty
        {
            current = name
        } else {
            current = "default"
        }
        return StoredContext(
            host: host, pointsHere: HVFBuilderSetup.sameEndpoint(host, layout.dockerEndpoint), current: current)
    }

    // MARK: Probes

    /// `docker --host <this machine> version`: the client half answers
    /// whether or not the machine runs, and no other daemon is contacted.
    func probeClient(_ setup: HVFBuilderSetup) -> Status.CLI {
        var cli = Status.CLI(path: setup.docker.path, version: nil, apiVersion: nil, tooOld: false)
        guard
            let result = try? setup.dockerUnchecked([
                "--host", layout.dockerEndpoint, "version", "--format", "{{json .Client}}",
            ]),
            let line = result.stdout.split(separator: "\n").first,
            let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        else { return cli }
        cli.version = json["Version"] as? String
        cli.apiVersion = (json["ApiVersion"] as? String) ?? (json["APIVersion"] as? String)
        if let api = cli.apiVersion {
            cli.tooOld = Self.apiVersion(api, isBelow: Self.minimumClientAPI)
        }
        return cli
    }

    /// "1.43" < "1.44"; an unparsable version is not reported as old.
    static func apiVersion(_ version: String, isBelow minimum: String) -> Bool {
        func parts(_ raw: String) -> [Int]? {
            let numbers = raw.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) }
            guard numbers.count >= 2, numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.compactMap { $0 }
        }
        guard let lhs = parts(version), let rhs = parts(minimum) else { return false }
        return lhs.lexicographicallyPrecedes(rhs)
    }

    func probeCompose(_ setup: HVFBuilderSetup) -> Status.Plugin {
        plugin(setup, ["compose", "version", "--short"]) { $0 }
    }

    /// `github.com/docker/buildx v0.29.0 <commit>` → `v0.29.0`.
    func probeBuildx(_ setup: HVFBuilderSetup) -> Status.Plugin {
        plugin(setup, ["buildx", "version"]) { output in
            let words = output.split(separator: " ")
            return words.count >= 2 ? String(words[1]) : output
        }
    }

    private func plugin(_ setup: HVFBuilderSetup, _ arguments: [String], version: (String) -> String)
        -> Status.Plugin
    {
        do {
            let result = try setup.dockerUnchecked(arguments)
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, !output.isEmpty else {
                let detail =
                    (result.stderr.isEmpty ? result.stdout : result.stderr)
                    .split(separator: "\n").first.map(String.init) ?? "exit status \(result.status)"
                return .init(version: nil, error: detail)
            }
            return .init(version: version(output.split(separator: "\n").first.map(String.init) ?? output), error: nil)
        } catch {
            return .init(version: nil, error: error.localizedDescription)
        }
    }

    /// Contexts Docker Desktop, OrbStack, Colima and Rancher Desktop made.
    func otherRuntimes(_ setup: HVFBuilderSetup) -> [Status.OtherRuntime] {
        guard let result = try? setup.dockerUnchecked(["context", "ls", "--format", "{{json .}}"]),
            result.status == 0
        else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                let name = json["Name"] as? String,
                Self.otherRuntimeContexts.contains(name) || name.hasPrefix("colima-")
            else { return nil }
            return Status.OtherRuntime(name: name, endpoint: json["DockerEndpoint"] as? String)
        }
    }

    /// `credsStore` and `credHelpers` from `config.json`, each with whether
    /// its helper is on `PATH`.
    func credentialHelpers() -> [Status.CredentialHelper] {
        let file = configDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: file),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        var helpers: [Status.CredentialHelper] = []
        if let store = json["credsStore"] as? String, !store.isEmpty {
            helpers.append(.init(key: "credsStore", name: store, found: onPath("docker-credential-\(store)")))
        }
        if let perRegistry = json["credHelpers"] as? [String: Any] {
            for registry in perRegistry.keys.sorted() {
                guard let name = perRegistry[registry] as? String, !name.isEmpty else { continue }
                helpers.append(.init(key: registry, name: name, found: onPath("docker-credential-\(name)")))
            }
        }
        return helpers
    }

    func onPath(_ executable: String) -> Bool {
        (environment["PATH"] ?? "").split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: String(directory)).appendingPathComponent(executable).path)
        }
    }

    // MARK: Notes

    /// The problems `install` and `status` both report.
    func commonNotes(client: Status.CLI, compose: Status.Plugin, buildx: Status.Plugin, machine: Machine) -> [String] {
        var notes: [String] = []
        if let host = environment["DOCKER_HOST"], !host.isEmpty,
            !HVFBuilderSetup.sameEndpoint(host, layout.dockerEndpoint)
        {
            notes.append(
                "DOCKER_HOST=\(host) is set in this shell: docker ignores the selected context while it is set "
                    + "(unset DOCKER_HOST)")
        }
        if let name = environment["DOCKER_CONTEXT"], !name.isEmpty, name != Self.contextName {
            notes.append(
                "DOCKER_CONTEXT=\(name) is set in this shell: docker ignores the selected context while it is set "
                    + "(unset DOCKER_CONTEXT)")
        }
        if let builder = environment["BUILDX_BUILDER"], !builder.isEmpty {
            notes.append("BUILDX_BUILDER=\(builder) is set in this shell: docker build uses that builder")
        }
        if client.tooOld, let api = client.apiVersion {
            if let pinned = environment["DOCKER_API_VERSION"], !pinned.isEmpty {
                notes.append(
                    "DOCKER_API_VERSION=\(pinned) is older than the engine's minimum \(Self.minimumClientAPI) "
                        + "(unset DOCKER_API_VERSION)")
            } else {
                notes.append(
                    "docker CLI API \(api) is older than the engine's minimum \(Self.minimumClientAPI): "
                        + "install a newer docker CLI")
            }
        }
        if compose.version == nil {
            notes.append("the docker compose plugin was not found\(pluginHint("docker-compose"))")
        }
        if buildx.version == nil {
            notes.append(
                "the docker buildx plugin was not found: docker build needs buildx (this engine has no classic "
                    + "/build)\(pluginHint("docker-buildx"))")
        }
        for helper in credentialHelpers() where !helper.found {
            let source = helper.key == "credsStore" ? "credsStore \"\(helper.name)\"" : "credHelpers[\"\(helper.key)\"]"
            let scope = helper.key == "credsStore" ? "pulls and builds" : "pulls from \(helper.key)"
            notes.append(
                "\(source) in \(configDirectory.appendingPathComponent("config.json").path) names "
                    + "docker-credential-\(helper.name), which is not on PATH: \(scope) will fail until it is "
                    + "installed or the key is removed")
        }
        notes += machineNotes(machine)
        return notes
    }

    /// Where a plugin is, when it is in a directory the CLI does not search.
    func pluginHint(_ plugin: String) -> String {
        let config = configDirectory.appendingPathComponent("config.json").path
        if let directory = pluginSearch.first(where: {
            FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(plugin).path)
        }) {
            return "; it is in \(directory): add that directory to \"cliPluginsExtraDirs\" in \(config)"
        }
        return
            " (install it, e.g. `brew install \(plugin)`, then add its directory to \"cliPluginsExtraDirs\" in \(config))"
    }

    func machineNotes(_ machine: Machine) -> [String] {
        guard machine.installed else {
            return [
                "the machine is not installed (missing \(machine.missing.joined(separator: ", "))): "
                    + "`micropod machine install`"
            ]
        }
        switch machine.phase {
        case .running, .starting: return []
        case .stopped, .stopping: return ["the machine is stopped: start it with `micropod machine start`"]
        case .failed: return ["the machine failed: start it again with `micropod machine start`"]
        }
    }
}
