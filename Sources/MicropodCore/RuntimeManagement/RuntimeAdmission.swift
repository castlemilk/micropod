import Darwin
import Foundation

/// One interprocess gate for Micropod's Apple runtime consumers. Unknown
/// operation outcomes remain durable and prevent disruptive maintenance.
public struct RuntimeAdmission: Sendable {
    public static let shared = RuntimeAdmission(
        root:
            ProcessInfo.processInfo.environment["MICROPOD_ISOLATED_RUNTIME"] == "1"
            ? IsolatedRuntimePolicy.admissionRoot : ManagedRuntimeLocation.root.appendingPathComponent("admission"))
    @TaskLocal public static var maintenanceOwner: UUID?
    public let root: URL
    public init(root: URL) { self.root = root }

    public struct Fence: Codable, Equatable, Sendable {
        public let operation: UUID
        public let generation: UInt64
        public var actionStarted: Bool
    }
    private var fenceURL: URL { root.appendingPathComponent("fence.json") }
    private var stateOwnerUID: uid_t { root == IsolatedRuntimePolicy.admissionRoot ? 0 : getuid() }
    public var isClosed: Bool { FileManager.default.fileExists(atPath: fenceURL.path) }
    /// Whether any receipt, settled or not, is waiting in `pending/`.
    public var hasPendingOperations: Bool {
        let entries = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("pending").path)
        return !(entries ?? []).isEmpty
    }

    public func nextGeneration() throws -> UInt64 {
        let url = root.appendingPathComponent("generation.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return 1 }
        let value = try JSONDecoder().decode(UInt64.self, from: RuntimeDurableFile.read(url, maximumBytes: 64))
        guard value < UInt64.max else { throw blocked() }
        return value + 1
    }

    /// Admits one runtime operation and writes its durable receipt.
    /// `container` names the container it acts on, when there is one: a
    /// stale receipt for a container the runtime no longer lists can then
    /// be proved dead (see ``StaleOperationEvidence``).
    public func claim(_ route: String, container: String? = nil) throws -> RuntimeAdmissionClaim? {
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
            let record = PendingRuntimeOperation(
                operation: operation, route: String(route.prefix(80)), pid: getpid(),
                owner: PendingRuntimeOperation.currentOwner, createdAt: Date(),
                container: container.map { String($0.prefix(128)) })
            try RuntimeDurableFile.write(record, to: pending)
            return RuntimeAdmissionClaim(fd: fd, pending: pending, record: record)
        } catch {
            close(fd)
            throw error
        }
    }

    /// Closes admission for one maintenance operation.
    ///
    /// Holding the gate exclusively proves no admission claim is live in
    /// any process, so every receipt left in `pending/` belongs to an
    /// operation whose caller has returned or whose process has exited.
    /// Those that can be proved dead are retired first
    /// (``reconcilePendingLocked(evidence:now:)``); any other receipt still
    /// blocks maintenance. `evidence` is a container listing taken just
    /// before this call, when the caller has one.
    public func begin(operation: UUID, recovering: Bool = false, evidence: StaleOperationEvidence? = nil) throws
        -> RuntimeMaintenanceFence
    {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("pending"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = try openLock(exclusive: true)
        do {
            let blocking = try reconcilePendingLocked(evidence: evidence)
            guard blocking.isEmpty else {
                throw MicropodError.message(
                    "Runtime has pending or uncertain operations; maintenance is blocked ("
                        + PendingOperationReconciliation.describe(blocking) + ")")
            }
            let fence: Fence
            if FileManager.default.fileExists(atPath: fenceURL.path) {
                fence = try readFence()
                guard recovering, fence.operation == operation else { throw blocked() }
            } else {
                guard !recovering else { throw blocked() }
                let generationURL = root.appendingPathComponent("generation.json")
                let generation = try issuedGeneration(for: operation) ?? nextGeneration()
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
        let data = try RuntimeDurableFile.read(fenceURL, maximumBytes: 4096, ownerUID: stateOwnerUID)
        return try JSONDecoder().decode(Fence.self, from: data)
    }

    private struct Issued: Codable {
        let operation: UUID
        let generation: UInt64
    }
    private var issuedURL: URL { root.appendingPathComponent("issued.json") }

    /// Issues the local generation for one maintenance operation and persists
    /// it at once. Until now the generation advanced only when a fence was
    /// taken, so every operation that ended before its fence (a refused or
    /// abandoned drain) handed the same generation to the next one, and a rig
    /// coordinator that had recorded that generation refused it. The
    /// operation's ``begin(operation:recovering:)`` fences at this same
    /// generation.
    public func issueGeneration(operation: UUID) throws -> UInt64 {
        let generation = try max(nextGeneration(), (readIssued()?.generation ?? 0) + 1)
        // The issue record first: after a crash before the counter moves,
        // the next issue still starts past it.
        try RuntimeDurableFile.write(Issued(operation: operation, generation: generation), to: issuedURL)
        try RuntimeDurableFile.write(generation, to: root.appendingPathComponent("generation.json"))
        return generation
    }
    /// The generation issued to `operation`, when it is the latest issued.
    /// A counter already past it means something newer moved on: refused.
    private func issuedGeneration(for operation: UUID) throws -> UInt64? {
        guard let issued = try readIssued(), issued.operation == operation else { return nil }
        guard try nextGeneration() <= issued.generation + 1 else { throw blocked() }
        return issued.generation
    }
    private func readIssued() throws -> Issued? {
        guard FileManager.default.fileExists(atPath: issuedURL.path) else { return nil }
        return try JSONDecoder().decode(
            Issued.self, from: RuntimeDurableFile.read(issuedURL, maximumBytes: 4096, ownerUID: stateOwnerUID))
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
    private let record: PendingRuntimeOperation
    fileprivate init(fd: Int32, pending: URL, record: PendingRuntimeOperation) {
        self.fd = fd
        self.pending = pending
        self.record = record
    }
    /// The operation finished: its receipt is settled.
    public func completed() throws { try RuntimeDurableFile.remove(pending) }

    /// The operation definitively failed — the runtime answered with an
    /// error, or the call never reached it — so nothing of it is left in
    /// flight and the receipt is settled like a completion.
    public func failed() throws { try RuntimeDurableFile.remove(pending) }

    /// The caller stopped waiting without an authoritative answer (a local
    /// deadline, transport loss, cancellation after dispatch). The receipt
    /// stays and keeps blocking maintenance until reconciliation proves the
    /// operation dead; it now also says when the caller gave up.
    public func uncertain() throws {
        var record = record
        record.outcome = .uncertain
        record.endedAt = Date()
        try RuntimeDurableFile.write(record, to: pending)
    }

    /// Settles a failed operation: definitive failures (``failed()``) when
    /// it never reached the runtime or the runtime answered, uncertain
    /// (``uncertain()``) for deadline, unavailable and cancelled outcomes
    /// of a call that did reach it.
    public func settle(after error: any Error, reachedRuntime: Bool = true) throws {
        if reachedRuntime, ContainerLifecycleClaims.outcomeUncertain(error) {
            try uncertain()
        } else {
            try failed()
        }
    }
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
