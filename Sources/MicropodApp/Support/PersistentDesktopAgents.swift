import Darwin
import Foundation
import MicropodCore

/// launchd owns these fixed, signed payloads. A desktop (Sparkle) release
/// neither replaces their executable paths nor restarts them. A disruptive rig
/// upgrade (RigUpgradeEngine) replaces records, payloads and launch agents
/// while it holds the upgrade fence; this file leaves them alone meanwhile.
enum PersistentDesktopAgents {
    /// The record format is shared with the rig upgrade, which replaces it.
    typealias Record = RetainedServiceRecord
    static var enabled: Bool {
        UpdaterPolicy.bundleDeclaresImplementedWorkloadProtocol
            && (try? IsolatedRuntimeIdentity.readRootOwned())?.ownerUID == getuid()
            && ProcessInfo.processInfo.environment["MICROPOD_AGENT_RUN_DIR"] == nil
    }
    static var root: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.micropod/services") }
    static func identifier(_ spec: AgentSpec) -> String { RetainedServiceLaunchAgent.identifier(spec.id) }
    static func recordURL(_ spec: AgentSpec) -> URL {
        RetainedServiceLaunchAgent.recordURL(spec.id, servicesRoot: root)
    }

    static func ensure(_ spec: AgentSpec, owners: [Int32]?, healthy: Bool) throws -> Int32? {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(
            root.appendingPathComponent("installation.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw MicropodError.message("Cannot lock service setup") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw MicropodError.message("Service setup is already in progress")
        }
        defer { flock(lock, LOCK_UN) }
        // A disruptive rig upgrade is replacing these payloads and launch
        // agents right now; setup resumes on a later tick once it finishes.
        guard !RigUpgradeFence.isReplacingServices() else {
            throw MicropodError.message(
                "A rig upgrade is replacing Micropod's services; setup resumes when it finishes")
        }
        guard let owners else { throw MicropodError.message("Cannot establish the \(spec.displayName) owner") }
        if FileManager.default.fileExists(atPath: recordURL(spec).path) {
            let record = try RetainedServiceLaunchAgent.readRecord(recordURL(spec))
            guard record.schema == 1, record.identifier == identifier(spec),
                try UpdateServiceWitness.digest(URL(fileURLWithPath: record.executable)) == record.sha256
            else { throw MicropodError.message("The retained service payload changed") }
            if owners.isEmpty {
                try register(spec, record: record)
                return nil
            }
            guard healthy, owners.count == 1, let pid = owners.first,
                UpdateServiceWitness.processPath(pid) == record.executable
            else { throw MicropodError.message("Retained service is not healthy; its owner was left unchanged") }
            _ = try UpdateServiceWitness.capture(name: spec.id, pid: pid, identifier: record.identifier)
            return pid
        }
        // Existing independently installed Connect servers remain independent.
        // Never adopt a GUI child, another build or an unverified socket owner.
        if healthy, owners.count == 1, let pid = owners.first,
            let path = UpdateServiceWitness.processPath(pid),
            spec.id == "api-server", path == NSHomeDirectory() + "/.micropod/connect/bin/MicropodAPI"
        {
            _ = try UpdateServiceWitness.capture(name: spec.id, pid: pid, identifier: identifier(spec))
            return pid
        }
        guard owners.isEmpty else {
            throw MicropodError.message("An existing service owns this endpoint; it was left running")
        }
        guard !DesktopActivity.shared.isClosed else {
            throw MicropodError.message("The update retains existing services; setup will resume after reconciliation")
        }
        try RuntimeCodeIdentity.verifyExecutable(Bundle.main.bundleURL, identifier: "com.skunkworq.micropod")
        let source = Bundle.main.bundleURL
        guard let executable = Bundle.main.executableURL,
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            version.range(of: "^\\d+\\.\\d+\\.\\d+$", options: .regularExpression) != nil
        else { throw MicropodError.message("The app build identity is unavailable") }
        let key = version + "-" + (try UpdateServiceWitness.digest(executable))
        let payload = root.appendingPathComponent("payloads/" + key + "/Micropod.app")
        if !FileManager.default.fileExists(atPath: payload.path) {
            try FileManager.default.createDirectory(
                at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = payload.deletingLastPathComponent().appendingPathComponent(
                "staged-" + UUID().uuidString + ".app")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: source, to: staged)
            try RuntimeCodeIdentity.verifyExecutable(staged, identifier: "com.skunkworq.micropod")
            try FileManager.default.moveItem(at: staged, to: payload)
        }
        try RuntimeCodeIdentity.verifyExecutable(payload, identifier: "com.skunkworq.micropod")
        let binary = payload.appendingPathComponent("Contents/MacOS/" + spec.binaryName)
        try RuntimeCodeIdentity.verifyExecutable(binary, identifier: identifier(spec))
        let parent = ProcessInfo.processInfo.environment
        let legacy = ContainerExecutableLocator.resolve(environment: [
            "MICROPOD_RUNTIME_CONTEXT": "existing", "PATH": parent["PATH"] ?? "",
        ])
        var environment = serviceEnvironment(
            spec: spec, parent: parent,
            legacyAvailable: ContainerExecutableLocator.isExecutableFile(legacy.path))
        for (key, value) in environment where value.hasPrefix(source.path + "/") {
            environment[key] = payload.path + String(value.dropFirst(source.path.count))
        }
        let record = Record(
            schema: 1,
            sourceVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            executable: binary.path, identifier: identifier(spec), sha256: try UpdateServiceWitness.digest(binary),
            arguments: spec.arguments, environment: environment)
        // Intent precedes registration. A crash on either side can only retry
        // this exact signed payload, never create an unrecorded replacement.
        try RuntimeDurableFile.write(record, to: recordURL(spec))
        try register(spec, record: record)
        return nil
    }

    static func serviceEnvironment(spec: AgentSpec, parent: [String: String], legacyAvailable: Bool) -> [String: String]
    {
        let keys = [
            "MICROPOD_CONTAINER_CLI_PATH", "MICROPOD_RUNTIME_CONTEXT", "MICROPOD_RUNTIME", "MICROPOD_ENGINES",
            "MICROPOD_DEFAULT_RUNTIME", "MICROPOD_API_PORT", "MICROPOD_SHIM_SOCKET", "MICROPOD_SHAREDFS_SOCKET",
            "MICROPOD_GUEST_TOOL", "DOCKER_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_CONFIG",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
        ]
        var environment = Dictionary(uniqueKeysWithValues: keys.compactMap { key in parent[key].map { (key, $0) } })
        environment.merge(spec.environment, uniquingKeysWith: { _, explicit in explicit })
        if environment["MICROPOD_RUNTIME_CONTEXT"] == nil {
            environment["MICROPOD_RUNTIME_CONTEXT"] = legacyAvailable ? "existing" : "managed"
        }
        environment[ParentDeathWatch.parentPIDEnv] = ""
        return environment
    }

    private static func register(_ spec: AgentSpec, record: Record) throws {
        try RuntimeCodeIdentity.verifyExecutable(URL(fileURLWithPath: record.executable), identifier: record.identifier)
        let agentDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        let plist = RetainedServiceLaunchAgent.plistURL(spec.id, launchAgents: agentDirectory)
        try RetainedServiceLaunchAgent.plistData(spec.id, record: record, servicesRoot: root).write(
            to: plist, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(getuid())", plist.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MicropodError.message("Could not register the persistent service; no existing process was stopped")
        }
    }

    static func witness(specs: [AgentSpec]) async throws -> [UpdateServiceWitness] {
        guard enabled else {
            throw MicropodError.message("Workload-preserving updates require the dedicated Apple runtime")
        }
        let identity = try IsolatedRuntimeIdentity.readRootOwned()
        let configuration = try IsolatedRuntimeAPIConfiguration.read(identity: identity)
        let helpers = try UpdateServiceWitness.processIDs(executableName: "MicropodRuntimeHost").filter {
            try RuntimeProcessBirth.read($0)?.uid == 0 && UpdateServiceWitness.parentPID($0) == 1
        }
        guard helpers.count == 1, let helper = helpers.first,
            let helperPath = UpdateServiceWitness.processPath(helper),
            !helperPath.hasPrefix(Bundle.main.bundlePath + "/")
        else {
            throw MicropodError.message("The approved setup helper must remain outside the replaceable desktop app")
        }
        let privatePath = IsolatedRuntimePolicy.root.appendingPathComponent(
            "tools/" + configuration.toolDirectoryName + "/MicropodAPI"
        ).path
        let privatePIDs = UpdateServiceWitness.processIDs(executable: privatePath)
        guard privatePIDs.count == 1, let pid = privatePIDs.first,
            try RuntimeProcessBirth.read(pid)?.uid == identity.serviceUID
        else {
            throw MicropodError.message("The dedicated API has no unique verified owner")
        }
        var witnesses = [
            try
                (try? UpdateServiceWitness.capture(
                    name: "runtime-setup-helper", pid: helper, identifier: IsolatedRuntimePolicy.helperIdentifier))
                ?? UpdateServiceWitness.capture(
                    name: "runtime-setup-helper", pid: helper,
                    identifier: IsolatedRuntimePolicy.legacyHelperIdentifier),
            try UpdateServiceWitness.capture(
                name: "dedicated-api", pid: pid,
                identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier),
        ]
        let enginePath = IsolatedRuntimePolicy.root.appendingPathComponent(
            "apple/versions/" + configuration.selection.directoryName + "/bin/container-apiserver"
        ).path
        let engines = UpdateServiceWitness.processIDs(executable: enginePath)
        guard engines.count == 1, let engine = engines.first,
            try RuntimeProcessBirth.read(engine)?.uid == identity.serviceUID
        else {
            throw MicropodError.message("The dedicated Apple engine has no unique owner")
        }
        witnesses.append(
            try UpdateServiceWitness.capture(
                name: "dedicated-apple-engine", pid: engine,
                identifier: "com.apple.container.apiserver", team: AppleRuntimeRelease.supported.teamIdentifier))
        for spec in specs {
            let owners: [Int32]?
            let endpoint: UpdateServiceWitness.Endpoint?
            switch spec.probe {
            case .http(let port, _):
                endpoint = .tcp(port)
                owners = endpoint?.owners()
            case .unixSocket(let path):
                endpoint = .unix(path)
                owners = endpoint?.owners()
            case .custom:
                endpoint = nil
                owners = nil
            }
            if let owners, owners.isEmpty,
                UserDefaults.standard.object(forKey: spec.enabledDefaultsKey) as? Bool == false,
                !FileManager.default.fileExists(atPath: recordURL(spec).path)
            {
                continue
            }
            guard let owners, owners.count == 1, let owner = owners.first else {
                throw MicropodError.message("The \(spec.displayName) owner is unknown")
            }
            let witness = try UpdateServiceWitness.capture(
                name: spec.id, pid: owner, identifier: identifier(spec), endpoint: endpoint)
            let label =
                witness.executable == NSHomeDirectory() + "/.micropod/connect/bin/MicropodAPI"
                ? "dev.micropod.api" : "com.skunkworq.micropod.service." + spec.id
            let status = try await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl")).run(
                .init(arguments: ["print", "gui/\(getuid())/" + label]), timeout: .seconds(2))
            let pids = status.split(separator: "\n").compactMap { line -> Int32? in
                let field = line.trimmingCharacters(in: .whitespaces)
                guard field.hasPrefix("pid = ") else { return nil }
                return Int32(field.dropFirst(6))
            }
            guard pids == [owner], witness.birth.uid == getuid() else {
                throw MicropodError.message(
                    "The \(spec.displayName) is not independently owned by its registered service")
            }
            guard !witness.executable.hasPrefix(Bundle.main.bundlePath + "/") else {
                throw MicropodError.message("The \(spec.displayName) still depends on the replaceable app")
            }
            witnesses.append(witness)
        }
        for witness in witnesses { try witness.verify() }
        return witnesses
    }
}
