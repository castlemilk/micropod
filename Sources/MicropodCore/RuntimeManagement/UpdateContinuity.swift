import CPtyShim
import CryptoKit
import Darwin
import Foundation

/// The desktop may be replaced; the private API and its workload owners may
/// not. Version 1 intentionally does not upgrade the engine, API or journals.
public struct UpdateServiceWitness: Codable, Equatable, Sendable {
    public enum Endpoint: Codable, Equatable, Sendable {
        case tcp(UInt16)
        case unix(String)
        public func owners() -> [Int32]? {
            switch self {
            case .tcp(let port): EndpointOwners.tcpListeners(port: port)
            case .unix(let path): EndpointOwners.unixListeners(path: path)
            }
        }
    }
    public let name: String
    public let executable: String
    public let identifier: String
    public let team: String
    public let sha256: String
    public let birth: RuntimeProcessBirth
    public let endpoint: Endpoint?

    public static func capture(
        name: String, pid: Int32, identifier: String,
        team: String = IsolatedRuntimePolicy.teamIdentifier, endpoint: Endpoint? = nil
    ) throws -> Self {
        guard let birth = try RuntimeProcessBirth.read(pid), let path = processPath(pid), parentPID(pid) == 1 else {
            throw MicropodError.message("The \(name) owner is unavailable")
        }
        let url = URL(fileURLWithPath: path)
        try RuntimeCodeIdentity.verifyExecutable(url, identifier: identifier, team: team)
        let hash = try digest(url)
        guard RuntimeCodeIdentity.processMatchesExecutable(pid, url: url, identifier: identifier, team: team),
            try RuntimeProcessBirth.read(pid) == birth, processPath(pid) == path
        else {
            throw MicropodError.message("The \(name) owner changed during verification")
        }
        guard endpoint == nil || endpoint?.owners() == [pid] else {
            throw MicropodError.message("The \(name) endpoint changed during verification")
        }
        return .init(
            name: name, executable: path, identifier: identifier, team: team, sha256: hash, birth: birth,
            endpoint: endpoint)
    }

    public func verify() throws {
        guard try RuntimeProcessBirth.read(birth.pid) == birth,
            Self.parentPID(birth.pid) == 1,
            endpoint == nil || endpoint?.owners() == [birth.pid],
            Self.processPath(birth.pid) == executable,
            RuntimeCodeIdentity.processMatchesExecutable(
                birth.pid, url: URL(fileURLWithPath: executable), identifier: identifier, team: team),
            try Self.digest(URL(fileURLWithPath: executable)) == sha256
        else { throw MicropodError.message("The \(name) owner changed; update recovery is required") }
    }

    public static func processPath(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

    public static func parentPID(_ pid: Int32) -> Int32? {
        var parent: Int32 = 0
        guard micropod_process_parent(pid, &parent) == 0 else { return nil }
        return parent
    }

    public static func processIDs(executable: String) -> [Int32] {
        allProcessIDs().filter { processPath($0) == executable }
    }

    public static func processIDs(executableName: String) -> [Int32] {
        allProcessIDs().filter { processPath($0).map { URL(fileURLWithPath: $0).lastPathComponent } == executableName }
    }

    private static func allProcessIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard actual > 0, actual <= pids.count else { return [] }
        return Array(pids.prefix(Int(actual)))
    }

    public static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct UpdateContinuityReceipt: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case prepared, downloading, extracting, downloadRejected, installing, succeeded, aborted, recoveryRequired
    }
    public let schema: Int
    public let operation: UUID
    public let generation: UUID
    public let owner: RuntimeProcessBirth
    public let beginDeadlineUptimeNanoseconds: UInt64
    public let sourceVersion: String
    public let sourceExecutableSHA256: String
    public let sourceAppPath: String
    public let targetVersion: String
    public let targetSourceRevision: String
    public let artifactURL: String
    public let artifactSignature: String
    public let artifactBytes: UInt64
    public let runtimeInstance: UUID
    public let apiConfigurationSHA256: String
    public let services: [UpdateServiceWitness]
    public var phase: Phase
    public var detail: String?
    public var updatedAt: Date
    public var isTerminal: Bool { phase == .succeeded || phase == .aborted }

    public init(
        operation: UUID, owner: RuntimeProcessBirth, sourceVersion: String, sourceExecutableSHA256: String,
        sourceAppPath: String,
        targetVersion: String, targetSourceRevision: String,
        artifactURL: String, artifactSignature: String, artifactBytes: UInt64, runtimeInstance: UUID,
        apiConfigurationSHA256: String,
        services: [UpdateServiceWitness]
    ) {
        schema = 1
        self.operation = operation
        generation = UUID()
        self.owner = owner
        beginDeadlineUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        self.sourceVersion = sourceVersion
        self.sourceAppPath = sourceAppPath
        self.targetVersion = targetVersion
        self.targetSourceRevision = targetSourceRevision
        self.artifactURL = artifactURL
        self.artifactSignature = artifactSignature
        self.artifactBytes = artifactBytes
        self.sourceExecutableSHA256 = sourceExecutableSHA256
        self.runtimeInstance = runtimeInstance
        self.apiConfigurationSHA256 = apiConfigurationSHA256
        self.services = services
        phase = .prepared
        updatedAt = Date()
    }

    public func verifyServices() throws {
        let identity = try IsolatedRuntimeIdentity.readRootOwned()
        guard schema == 1, identity.instance == runtimeInstance,
            try UpdateServiceWitness.digest(IsolatedRuntimeAPIConfiguration.fileURL) == apiConfigurationSHA256,
            identity.ownerUID == owner.uid
        else { throw MicropodError.message("The managed runtime configuration changed during the update") }
        let configuration = try IsolatedRuntimeAPIConfiguration.read(identity: identity)
        try verifyRoles(identity: identity, configuration: configuration)
        for service in services { try service.verify() }
    }

    func verifyRoles(identity: IsolatedRuntimeIdentity, configuration: IsolatedRuntimeAPIConfiguration) throws {
        let roles: [String: (String, String, UInt32)] = [
            "runtime-setup-helper": (IsolatedRuntimePolicy.helperIdentifier, IsolatedRuntimePolicy.teamIdentifier, 0),
            "dedicated-api": (
                IsolatedRuntimeAPIConfiguration.executableIdentifier, IsolatedRuntimePolicy.teamIdentifier,
                identity.serviceUID
            ),
            "dedicated-apple-engine": (
                "com.apple.container.apiserver", AppleRuntimeRelease.supported.teamIdentifier, identity.serviceUID
            ),
            "api-server": ("com.skunkworq.micropod.api", IsolatedRuntimePolicy.teamIdentifier, owner.uid),
            "docker-shim": ("com.skunkworq.micropod.docker-shim", IsolatedRuntimePolicy.teamIdentifier, owner.uid),
            "shared-fs": ("com.skunkworq.micropod.sharedfs", IsolatedRuntimePolicy.teamIdentifier, owner.uid),
        ]
        let required: Set<String> = ["runtime-setup-helper", "dedicated-api", "dedicated-apple-engine"]
        guard sourceAppPath.hasSuffix(".app"), Set(services.map(\.name)).count == services.count,
            required.isSubset(of: Set(services.map(\.name))), services.count <= roles.count
        else { throw MicropodError.message("The update service witness is incomplete") }
        for service in services {
            let identified =
                service.name == "runtime-setup-helper"
                ? IsolatedRuntimePolicy.helperPeerIdentifiers.contains(service.identifier)
                : service.identifier == roles[service.name]?.0
            guard let role = roles[service.name], identified, service.team == role.1,
                service.birth.uid == role.2, service.birth.bootSession == owner.bootSession,
                !service.executable.hasPrefix(sourceAppPath + "/"),
                required.contains(service.name) == (service.endpoint == nil)
            else { throw MicropodError.message("The update service witness has an unsupported owner") }
            if service.name == "dedicated-api" {
                guard service.sha256 == configuration.executableSHA256,
                    service.executable
                        == IsolatedRuntimePolicy.root.appendingPathComponent(
                            "tools/" + configuration.toolDirectoryName + "/MicropodAPI"
                        ).path
                else {
                    throw MicropodError.message("The dedicated API payload changed")
                }
            } else if service.name == "dedicated-apple-engine" {
                guard
                    service.executable
                        == IsolatedRuntimePolicy.root.appendingPathComponent(
                            "apple/versions/" + configuration.selection.directoryName + "/bin/container-apiserver"
                        ).path
                else {
                    throw MicropodError.message("The dedicated Apple engine payload changed")
                }
            }
        }
    }
}

/// One fsynced transaction under a kernel lock. Expiry, process exit and reboot
/// never silently erase a transaction whose installer may have started.
public struct UpdateContinuityStore: Sendable {
    public static var standard: Self {
        .init(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".micropod/updates"))
    }
    public let root: URL
    public var receiptURL: URL { root.appendingPathComponent("transaction.json") }
    public init(root: URL) { self.root = root }
    public var requiresRecovery: Bool {
        do { return try read()?.isTerminal == false } catch { return true }
    }
    public func read() throws -> UpdateContinuityReceipt? {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        let value = try JSONDecoder().decode(
            UpdateContinuityReceipt.self,
            from: RuntimeDurableFile.read(receiptURL, maximumBytes: 65536))
        guard value.schema == 1 else { throw MicropodError.message("Unsupported update transaction schema") }
        return value
    }
    public func prepare(_ receipt: UpdateContinuityReceipt) throws {
        try locked {
            guard try read()?.isTerminal != false else {
                throw MicropodError.message("A retained update transaction needs reconciliation")
            }
            try RuntimeDurableFile.write(receipt, to: receiptURL)
            try RuntimeDurableFile.write(
                receipt, to: root.appendingPathComponent(receipt.operation.uuidString + ".json"))
        }
    }
    public func transition(
        operation: UUID, generation: UUID, from: UpdateContinuityReceipt.Phase,
        to: UpdateContinuityReceipt.Phase, detail: String? = nil
    ) throws -> UpdateContinuityReceipt {
        try locked {
            let allowed: [UpdateContinuityReceipt.Phase: Set<UpdateContinuityReceipt.Phase>] = [
                .prepared: [.downloading, .aborted],
                .downloading: [.extracting, .installing, .downloadRejected, .succeeded, .recoveryRequired],
                .extracting: [.installing, .downloadRejected, .succeeded, .recoveryRequired],
                .downloadRejected: [.aborted],
                .installing: [.succeeded, .recoveryRequired], .recoveryRequired: [.succeeded],
            ]
            guard allowed[from]?.contains(to) == true else {
                throw MicropodError.message("Invalid update state transition")
            }
            guard var value = try read(), value.operation == operation, value.generation == generation,
                value.phase == from
            else { throw MicropodError.message("Stale or duplicate update authorization") }
            value.phase = to
            value.detail = detail
            value.updatedAt = Date()
            try RuntimeDurableFile.write(value, to: receiptURL)
            try RuntimeDurableFile.write(value, to: root.appendingPathComponent(value.operation.uuidString + ".json"))
            return value
        }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(
            root.appendingPathComponent("transaction.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MicropodError.message("Cannot lock update state") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MicropodError.message("Another update request is active") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
