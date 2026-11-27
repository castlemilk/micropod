import CryptoKit
import Darwin
import Foundation
import MicropodCore

/// What `HVFMachineAutostartAgent` needs of the machine itself: whether a
/// supervisor runs, what a stop would interrupt, and stop/start. The live
/// one is `HVFClientAutostartMachine`; tests replace it.
public protocol HVFAutostartMachine: Sendable {
    func supervisorAlive() -> Bool
    /// What a stop would interrupt now; nil when nothing would be.
    func busy() async -> String?
    func stop() async throws
    func start() async throws
}

/// The machine `HVFMachineClient` drives.
public struct HVFClientAutostartMachine: HVFAutostartMachine {
    public let client: HVFMachineClient
    public init(client: HVFMachineClient) { self.client = client }

    public func supervisorAlive() -> Bool { client.status().supervisorAlive }
    public func busy() async -> String? { await client.activeWorkloadSummary() }
    public func stop() async throws { try await client.stop() }
    public func start() async throws { try await client.ensureRunning() }
}

/// `micropod machine autostart`: a per-user LaunchAgent that runs
/// `micropod machine serve` in the foreground for one machine root. launchd
/// starts it at login (`RunAtLoad`) and, at logout or shutdown, sends it
/// SIGTERM and waits `ExitTimeOut` before SIGKILL: the supervisor powers
/// the guest off in that time. It is relaunched only after a crash
/// (`KeepAlive {Crashed: true}`): a supervisor that gave up (exit 1) or a
/// `machine stop` (exit 0) stays down until the next login or an explicit
/// start, which `HVFMachineClient` routes through `launchctl kickstart`
/// while the job is loaded.
///
/// The standard root's job is `com.skunkworq.micropod.machine`; any other
/// root's carries 8 hex digits of its path's SHA-256, so a throwaway root
/// can never name the real job. `<root>/autostart.json` records what was
/// set up. `MICROPOD_LAUNCHCTL` names the launchctl to run and
/// `MICROPOD_LAUNCH_AGENTS_DIR` the directory the plist goes to (tests and
/// throwaway machines point both at stand-ins); a root other than the
/// standard one loads into the real launchd only with
/// `MICROPOD_AUTOSTART_ANY_ROOT=1`.
public struct HVFMachineAutostartAgent: Sendable {
    public static let standardLabel = "com.skunkworq.micropod.machine"
    public static let recordFileName = "autostart.json"
    /// launchd waits this long past the supervisor's own SIGTERM → SIGKILL
    /// budget (`HVFMachineConfig.stopGrace`) before it kills the supervisor.
    public static let exitTimeOutMargin = 10
    /// The `PATH` the job gets when the caller has none.
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public let layout: HVFMachineLayout
    public let label: String
    public let launchAgentsDirectory: URL
    let launch: any RigLaunchControlling
    let machine: any HVFAutostartMachine
    public let environment: [String: String]
    /// True when `launch` is the real launchctl (no `MICROPOD_LAUNCHCTL`).
    let realLaunchd: Bool

    public init(
        layout: HVFMachineLayout, environment: [String: String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        launch: (any RigLaunchControlling)? = nil, launchAgentsDirectory: URL? = nil,
        machine: (any HVFAutostartMachine)? = nil
    ) {
        self.layout = layout
        self.environment = environment
        label = Self.label(for: layout, home: home)
        self.launchAgentsDirectory =
            launchAgentsDirectory ?? Self.launchAgentsDirectory(environment: environment, home: home)
        self.launch = launch ?? Self.launchControl(environment: environment)
        realLaunchd = launch == nil && Self.launchctlOverride(environment) == nil
        self.machine =
            machine ?? HVFClientAutostartMachine(client: HVFMachineClient(layout: layout, environment: environment))
    }

    // MARK: Names and places

    /// D8: the standard label for `~/.micropod/hvf`, else one per root.
    public static func label(
        for layout: HVFMachineLayout, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if layout.isStandardRoot(home: home) { return standardLabel }
        let path = layout.root.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8))
        return standardLabel + "." + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func launchctlOverride(_ environment: [String: String]) -> String? {
        guard let path = environment["MICROPOD_LAUNCHCTL"], !path.isEmpty else { return nil }
        return NSString(string: path).expandingTildeInPath
    }

    /// The user's launchd domain through `MICROPOD_LAUNCHCTL`, else
    /// `/bin/launchctl`.
    public static func launchControl(environment: [String: String]) -> any RigLaunchControlling {
        RigLaunchctl(executable: launchctlOverride(environment) ?? RigLaunchctl.defaultExecutable)
    }

    /// `MICROPOD_LAUNCH_AGENTS_DIR`, else `~/Library/LaunchAgents`.
    public static func launchAgentsDirectory(environment: [String: String], home: URL) -> URL {
        if let configured = environment["MICROPOD_LAUNCH_AGENTS_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/LaunchAgents")
    }

    public var plistURL: URL { launchAgentsDirectory.appendingPathComponent(label + ".plist") }
    public var recordURL: URL { Self.recordURL(layout) }
    static func recordURL(_ layout: HVFMachineLayout) -> URL { layout.root.appendingPathComponent(recordFileName) }

    /// The program the job runs: `--program`, else `MICROPOD_CLI`, else
    /// `~/.local/bin/micropod` when this executable is inside an app bundle
    /// (its link survives app updates; the bundle's own path changes), else
    /// this executable's real path.
    public static func resolveProgram(
        explicit: String?, environment: [String: String], current: URL = CLIInstall.currentExecutable(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        func url(_ path: String) -> URL { URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        if let explicit, !explicit.isEmpty { return url(explicit) }
        if let configured = environment["MICROPOD_CLI"], !configured.isEmpty { return url(configured) }
        if current.path.contains(".app/Contents/") { return home.appendingPathComponent(".local/bin/micropod") }
        return current.resolvingSymlinksInPath()
    }

    // MARK: The plist

    /// launchd's `ExitTimeOut`: the supervisor's stop budget plus a margin.
    public static func exitTimeOut(_ config: HVFMachineConfig) -> Int {
        Int(config.stopGrace.components.seconds) + exitTimeOutMargin
    }

    /// The job definition (D7). `Umask` 022 is what a login shell gives
    /// the supervisor `machine start` launches, so files it and the VMM
    /// create (the Docker socket, the guest-config share) keep the modes they
    /// have there. No `SoftResourceLimits`: micropod-vmm raises its own
    /// open-file limit to the hard limit at start.
    public static func plist(
        label: String, layout: HVFMachineLayout, program: URL, config: HVFMachineConfig,
        environment: [String: String]
    ) -> [String: Any] {
        var variables = [
            "MICROPOD_HVF_ROOT": layout.root.path,
            "PATH": environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath,
        ]
        for key in ["MICROPOD_DOCKER_SOCK", "MICROPOD_LINK_DOCKER_SOCK"] {
            if let value = environment[key], !value.isEmpty { variables[key] = value }
        }
        return [
            "Label": label,
            "ProgramArguments": [program.path, "machine", "serve", "--link-socket"],
            "RunAtLoad": true,
            "KeepAlive": ["Crashed": true],
            "ExitTimeOut": exitTimeOut(config),
            "ProcessType": "Interactive",
            "Umask": 0o022,
            "StandardOutPath": layout.supervisorLog.path,
            "StandardErrorPath": layout.supervisorLog.path,
            "EnvironmentVariables": variables,
        ]
    }

    static func plistData(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Writes this root's plist for `program` into `directory` (default the
    /// LaunchAgents directory) without loading it; returns its path.
    @discardableResult
    public func render(program: URL, to directory: URL? = nil) throws -> URL {
        let config = try loadConfig()
        let url = (directory ?? launchAgentsDirectory).appendingPathComponent(label + ".plist")
        try HVFFiles.writeAtomically(
            try Self.plistData(
                Self.plist(label: label, layout: layout, program: program, config: config, environment: environment)),
            to: url)
        return url
    }

    private func loadConfig() throws -> HVFMachineConfig {
        if let problem = layout.configurationProblem() {
            throw MicropodError.message("failedPrecondition: \(problem)")
        }
        return try HVFMachineConfig.load(from: layout.config)
    }

    // MARK: The record

    /// `<root>/autostart.json`.
    public struct Record: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var label: String
        public var plist: String
        public var program: String
        public var exitTimeOut: Int
        public var updatedAt: Date

        public init(enabled: Bool, label: String, plist: String, program: String, exitTimeOut: Int, updatedAt: Date) {
            self.enabled = enabled
            self.label = label
            self.plist = plist
            self.program = program
            self.exitTimeOut = exitTimeOut
            self.updatedAt = updatedAt
        }
    }

    /// nil when there is none or it does not parse.
    public static func loadRecord(layout: HVFMachineLayout) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(layout)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    func save(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try HVFFiles.writeAtomically(try encoder.encode(record), to: recordURL, mode: 0o600)
    }

    // MARK: Status

    public struct Status: Codable, Sendable, Equatable {
        /// autostart.json says on.
        public var enabled: Bool
        public var label: String
        public var plist: String
        public var plistPresent: Bool
        /// launchd has the job loaded.
        public var loaded: Bool
        public var program: String?
        public var exitTimeOut: Int?
        /// Why the job cannot start the machine as recorded.
        public var problem: String?
        public var summary: String
    }

    /// Never changes anything. Asks launchd whether the job is loaded only
    /// when there is a record or a plist for this root: a root that never
    /// had autostart runs no launchctl.
    public func status() async -> Status {
        let record = Self.loadRecord(layout: layout)
        let plistPresent = FileManager.default.fileExists(atPath: plistURL.path)
        let loaded = record != nil || plistPresent ? await launch.isLoaded(label) : false
        guard let record, record.enabled else {
            var summary =
                "off (the machine starts on demand from micropod and the API; nothing stops it cleanly at logout)"
            if loaded {
                summary += "; launchd still has \(label) loaded (`micropod machine autostart off` unloads it)"
            } else if plistPresent {
                summary += "; \(plistURL.path) remains"
            }
            return Status(
                enabled: false, label: label, plist: plistURL.path, plistPresent: plistPresent, loaded: loaded,
                program: nil, exitTimeOut: nil, problem: nil, summary: summary)
        }
        var problem: String?
        if !FileManager.default.isExecutableFile(atPath: record.program) {
            problem =
                "the program \(record.program) is missing or not executable (`micropod machine autostart on` "
                + "names the current one)"
        } else if !plistPresent {
            problem =
                "\(plistURL.path) is gone: launchd will not start the machine at the next login "
                + "(`micropod machine autostart on` writes it again)"
        }
        let state = loaded ? "loaded" : "not loaded; launchd loads it at the next login"
        var summary =
            "on (launchd \(label), \(state), program \(record.program), exit timeout \(record.exitTimeOut) s)"
        if let problem { summary += "; \(problem)" }
        return Status(
            enabled: true, label: label, plist: plistURL.path, plistPresent: plistPresent, loaded: loaded,
            program: record.program, exitTimeOut: record.exitTimeOut, problem: problem, summary: summary)
    }

    // MARK: On

    /// Turns autostart on for `program`. With `load`, launchd loads the job
    /// now, which starts the machine (`RunAtLoad`): a machine already
    /// running outside launchd is stopped first so launchd owns it, which is
    /// deferred (nothing changed) while it runs containers, unless `force`.
    /// Without `load`, only the plist and the record are written and launchd
    /// loads the job at the next login. Returns what it did, one line each.
    public func enable(load: Bool, program: URL, force: Bool) async throws -> [String] {
        let missing = layout.missingAssets()
        guard missing.isEmpty else {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine is not installed under \(layout.root.path) (missing "
                    + "\(missing.joined(separator: ", "))): run `micropod machine install` first")
        }
        guard FileManager.default.isExecutableFile(atPath: program.path) else {
            throw MicropodError.message(
                "failedPrecondition: \(program.path) is not an executable micropod CLI (pass --program <path>)")
        }
        if load, realLaunchd, !layout.isStandardRoot(),
            !["1", "true", "yes", "on"].contains(environment["MICROPOD_AUTOSTART_ANY_ROOT"]?.lowercased() ?? "")
        {
            throw MicropodError.message(
                "failedPrecondition: \(layout.root.path) is not the standard machine root: loading its LaunchAgent "
                    + "into your launchd domain needs MICROPOD_AUTOSTART_ANY_ROOT=1 (or --no-load, or "
                    + "MICROPOD_LAUNCHCTL naming a stand-in launchctl)")
        }
        let config = try loadConfig()
        let exitTimeOut = Self.exitTimeOut(config)
        let data = try Self.plistData(
            Self.plist(label: label, layout: layout, program: program, config: config, environment: environment))
        let record = Record(
            enabled: true, label: label, plist: plistURL.path, program: program.path, exitTimeOut: exitTimeOut,
            updatedAt: Date())
        let where_ = "\(label), \(plistURL.path)"
        guard load else {
            try HVFFiles.writeAtomically(data, to: plistURL)
            try save(record)
            return ["autostart: on at next login (\(where_))"]
        }
        let loaded = await launch.isLoaded(label)
        if loaded, (try? Data(contentsOf: plistURL)) == data {
            try save(record)
            return ["autostart: on (\(where_); already loaded)"]
        }
        let running = machine.supervisorAlive()
        if running, !force, let busy = await machine.busy() {
            let why =
                loaded
                ? "reloading the job restarts the machine under launchd"
                : "the machine runs outside launchd and must restart under it"
            throw MicropodError.message(
                "failedPrecondition: deferred: \(busy); \(why); nothing was changed (--force to restart it now, "
                    + "or --no-load to take effect at the next login)")
        }
        try HVFFiles.writeAtomically(data, to: plistURL)
        try save(record)
        var lines: [String] = []
        if loaded {
            try await launch.bootout(label)
            lines.append("unloaded the previous definition of \(label)")
        } else if running {
            try await machine.stop()
            lines.append("stopped the machine running outside launchd")
        }
        try await launch.bootstrap(plistURL, label: label)
        lines.append("autostart: on (\(where_); loaded: launchd starts the machine now and at every login)")
        return lines
    }

    // MARK: Off

    /// Turns autostart off: unloads the job (which stops the machine
    /// launchd runs), removes the plist and the record, and starts a machine
    /// that was running again outside launchd. Deferred (nothing changed)
    /// while the machine runs containers, unless `force`.
    public func disable(force: Bool) async throws -> [String] {
        let loaded = await launch.isLoaded(label)
        let running = loaded && machine.supervisorAlive()
        if running, !force, let busy = await machine.busy() {
            throw MicropodError.message(
                "failedPrecondition: deferred: \(busy); unloading \(label) stops the machine launchd runs; nothing "
                    + "was changed (--force to stop it and start it again outside launchd)")
        }
        var lines: [String] = []
        if loaded {
            try await launch.bootout(label)
            lines.append("unloaded \(label)")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: plistURL.path) {
            try fm.removeItem(at: plistURL)
            lines.append("removed \(plistURL.path)")
        }
        if fm.fileExists(atPath: recordURL.path) { try fm.removeItem(at: recordURL) }
        lines.append(
            "autostart: off (the machine starts on demand from micropod and the API; nothing stops it cleanly at "
                + "logout)")
        if running {
            try await machine.start()
            lines.append("machine: running again outside launchd")
        }
        return lines
    }
}
