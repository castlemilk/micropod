import Darwin
import Foundation

/// One interprocess gate for Micropod's Apple runtime consumers. Unknown
/// operation outcomes remain durable and prevent disruptive maintenance.
public struct RuntimeAdmission: Sendable {
    public static let shared = RuntimeAdmission(root: ManagedRuntimeLocation.root.appendingPathComponent("admission"))
    @TaskLocal public static var maintenanceOwner: UUID?
    public let root: URL
    public init(root: URL) { self.root = root }

    public struct Fence: Codable, Equatable, Sendable {
        public let operation: UUID
        public let generation: UInt64
        public var actionStarted: Bool
    }
    private struct Pending: Codable {
        let operation: UUID
        let route: String
        let pid: Int32
    }
    private var fenceURL: URL { root.appendingPathComponent("fence.json") }
    public var isClosed: Bool { FileManager.default.fileExists(atPath: fenceURL.path) }

    public func nextGeneration() throws -> UInt64 {
        let url = root.appendingPathComponent("generation.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return 1 }
        let value = try JSONDecoder().decode(UInt64.self, from: RuntimeDurableFile.read(url, maximumBytes: 64))
        guard value < UInt64.max else { throw blocked() }
        return value + 1
    }

    public func claim(_ route: String) throws -> RuntimeAdmissionClaim? {
        let fm = FileManager.default
        guard
            fm.fileExists(atPath: root.appendingPathComponent("enrolled").path)
                || fm.fileExists(atPath: fenceURL.path)
        else { return nil }
        // Maintenance commands still use the ordinary services, but only the
        // task holding the exact persisted operation may cross the closed gate.
        if let owner = Self.maintenanceOwner {
            let fence = try readFence()
            guard fence.operation == owner else { throw blocked() }
            return nil
        }
        let fd = try openLock(exclusive: false)
        do {
            guard !fm.fileExists(atPath: fenceURL.path) else { throw blocked() }
            let operation = UUID()
            let pending = root.appendingPathComponent("pending/" + operation.uuidString + ".json")
            try RuntimeDurableFile.write(
                Pending(operation: operation, route: String(route.prefix(80)), pid: getpid()), to: pending)
            return RuntimeAdmissionClaim(fd: fd, pending: pending)
        } catch {
            close(fd)
            throw error
        }
    }

    public func begin(operation: UUID, recovering: Bool = false) throws -> RuntimeMaintenanceFence {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("pending"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = try openLock(exclusive: true)
        do {
            let pending = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("pending"), includingPropertiesForKeys: nil)
            guard pending.isEmpty else {
                throw MicropodError.message("Runtime has pending or uncertain operations; maintenance is blocked")
            }
            let fence: Fence
            if FileManager.default.fileExists(atPath: fenceURL.path) {
                fence = try readFence()
                guard recovering, fence.operation == operation else { throw blocked() }
            } else {
                guard !recovering else { throw blocked() }
                let generationURL = root.appendingPathComponent("generation.json")
                let generation = try nextGeneration()
                try RuntimeDurableFile.write(generation, to: generationURL)
                fence = Fence(operation: operation, generation: generation, actionStarted: false)
                try RuntimeDurableFile.write(fence, to: fenceURL)
                try RuntimeDurableFile.write(true, to: root.appendingPathComponent("enrolled"))
            }
            return RuntimeMaintenanceFence(fd: fd, root: root, fence: fence)
        } catch {
            close(fd)
            throw error
        }
    }

    public func readFence() throws -> Fence {
        let data = try RuntimeDurableFile.read(fenceURL, maximumBytes: 4096)
        return try JSONDecoder().decode(Fence.self, from: data)
    }

    private func openLock(exclusive: Bool) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent("gate.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw blocked() }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd)
            throw blocked()
        }
        return fd
    }
    private func blocked() -> Error { MicropodError.message("Runtime maintenance has closed workload admission") }
}

/// Releasing an fd after a crash cannot erase the durable pending receipt.
public final class RuntimeAdmissionClaim: @unchecked Sendable {
    private let fd: Int32
    private let pending: URL
    fileprivate init(fd: Int32, pending: URL) {
        self.fd = fd
        self.pending = pending
    }
    public func completed() throws { try RuntimeDurableFile.remove(pending) }
    deinit { close(fd) }
}

public final class RuntimeMaintenanceFence: @unchecked Sendable {
    private var fd: Int32
    private let root: URL
    public private(set) var fence: RuntimeAdmission.Fence
    fileprivate init(fd: Int32, root: URL, fence: RuntimeAdmission.Fence) {
        self.fd = fd
        self.root = root
        self.fence = fence
    }
    public func beginAction() throws {
        guard try RuntimeAdmission(root: root).readFence() == fence, !fence.actionStarted else {
            throw MicropodError.message("Runtime maintenance ownership changed")
        }
        fence.actionStarted = true
        try RuntimeDurableFile.write(fence, to: root.appendingPathComponent("fence.json"))
    }
    /// Call only after independently verifying the expected installed runtime
    /// or restored prior runtime and settling the external rig fence.
    public func releaseAfterVerification() throws {
        guard try RuntimeAdmission(root: root).readFence() == fence else {
            throw MicropodError.message("Runtime maintenance generation changed")
        }
        try RuntimeDurableFile.remove(root.appendingPathComponent("fence.json"))
        close(fd)
        fd = -1
    }
    deinit { if fd >= 0 { close(fd) } }
}
