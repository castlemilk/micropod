import Foundation

/// Per-container-id async mutex around a native create. `createNative`
/// runs its whole body — list check, orphan sweep, stale-dir reclaim,
/// clone placement, `containerCreate` and the failure cleanup — inside
/// ``withExclusive(_:_:)``, so creates of the same id in this process never
/// overlap: a create is the *sole placer* under `<cloneRoot>/<id>` for its
/// whole duration, which is what lets it reclaim a stale clone dir there
/// (`VolumeClone.reclaimStaleCloneDir`) without unlinking a concurrent
/// replay's clones. A replay of the same id waits for the winner: if the
/// winner succeeded, the replay's list check answers `already_exists` and
/// it never places or reclaims; if it failed, the replay proceeds as a
/// genuine sole create over a dir the loser already cleaned.
///
/// Same discipline as `VolumeLocks`: waiters are served in FIFO order and
/// the id is released whether the body returns or throws. Process-wide,
/// like `VolumeLocks`, so a backend hot-swap cannot reset it.
public actor ContainerLifecycleClaims {
    public static let shared = ContainerLifecycleClaims()

    public enum Kind: Sendable, Equatable { case creating, starting, deleting, cleanup }
    public struct Claim: Sendable, Equatable {
        public let id: String
        fileprivate let token: UUID
        public let kind: Kind
    }
    private var held: [String: Claim] = [:]
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Claim, Error>
    }
    private var waiters: [String: [Waiter]] = [:]
    private var lifecycleRevision: UInt64 = 0
    private var createEpoch: UInt64 = 0

    public init() {}

    /// Runs `body` as the only create of `id` in this process. The body
    /// must not call `withExclusive` for the same id: the mutex is not
    /// reentrant.
    public nonisolated func withExclusive<T>(_ id: String, _ body: () async throws -> T) async throws -> T {
        let claim = try await acquire(id)
        do {
            // Cancellation may race a handoff from the preceding holder.
            // The acquired generation is still released, but its body never runs.
            try Task.checkCancellation()
            let value = try await body()
            await finish(claim)
            return value
        } catch {
            await finish(claim)
            throw error
        }
    }

    public static func outcomeUncertain(_ error: any Error) -> Bool {
        error is CancellationError
            || ["deadline_exceeded", "unavailable", "cancelled"].contains(ConnectCodeMapping.code(for: error))
    }

    public func kind(of id: String) -> Kind? { held[id]?.kind }

    /// Fences a runtime snapshot against any lifecycle ownership transition.
    public func revision() -> UInt64 { lifecycleRevision }

    /// Capture before reading the live container list used by an orphan sweep.
    /// A create that begins or ends during that read invalidates the snapshot.
    public func creationEpoch() -> UInt64 { createEpoch }

    // Queue depth is inspected by deterministic cancellation/handoff tests.
    func queuedCount(for id: String) -> Int { waiters[id]?.count ?? 0 }

    public func claimIfIdle(_ id: String, kind: Kind) -> Claim? {
        guard held[id] == nil else { return nil }
        let claim = Claim(id: id, token: UUID(), kind: kind)
        held[id] = claim
        transitioned(kind)
        return claim
    }

    public func finish(_ claim: Claim) {
        guard held[claim.id] == claim else { return }
        release(claim)
    }

    /// Never wait for another ID while a create holds its own ID: two
    /// concurrent creates sweeping each other's directories must not deadlock.
    @discardableResult
    public nonisolated func withCleanupIfIdle(
        _ id: String, observedBefore: UInt64, _ body: () async -> Void
    ) async -> Bool {
        guard let claim = await claimCleanupIfIdle(id, observedBefore: observedBefore) else { return false }
        await body()
        await finish(claim)
        return true
    }

    private func claimCleanupIfIdle(_ id: String, observedBefore: UInt64) -> Claim? {
        // Epoch validation and per-ID acquisition are one actor operation.
        guard createEpoch == observedBefore else { return nil }
        return claimIfIdle(id, kind: .cleanup)
    }

    private func acquire(_ id: String) async throws -> Claim {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let claim = claimIfIdle(id, kind: .creating) {
                    continuation.resume(returning: claim)
                } else {
                    waiters[id, default: []].append(Waiter(token: token, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, token: token) }
        }
    }

    private func cancelWaiter(_ id: String, token: UUID) {
        guard var queue = waiters[id], let index = queue.firstIndex(where: { $0.token == token }) else { return }
        let waiter = queue.remove(at: index)
        waiters[id] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func transitioned(_ kind: Kind) {
        lifecycleRevision &+= 1
        if kind == .creating { createEpoch &+= 1 }
    }

    private func release(_ claim: Claim) {
        held[claim.id] = nil
        transitioned(claim.kind)
        if var queue = waiters[claim.id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[claim.id] = queue.isEmpty ? nil : queue
            // Ownership passes straight to the next waiter without an
            // actor suspension at which another caller could acquire it.
            let successor = Claim(id: claim.id, token: UUID(), kind: .creating)
            held[claim.id] = successor
            transitioned(.creating)
            next.continuation.resume(returning: successor)
        } else {
            waiters[claim.id] = nil
        }
    }
}
