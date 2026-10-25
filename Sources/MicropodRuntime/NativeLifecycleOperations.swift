import Foundation
import MicropodCore
import Synchronization

/// Owns native starts/deletes independently of the HTTP caller's lifetime.
/// Queued cancellation prevents dispatch; after dispatch cancellation cannot
/// release ownership while Apple's non-cancellable XPC operation continues.
actor NativeLifecycleOperations {
    static let shared = NativeLifecycleOperations()
    private enum Phase: Equatable { case queued, dispatched, uncertain }
    private struct Entry {
        let claim: ContainerLifecycleClaims.Claim
        let caller: UUID
        let cancellation: LifecycleCancellation
        let knownExit: @Sendable () async -> Bool
        var phase: Phase = .queued
        var cancelled = false
        var cancelWork: (@Sendable () -> Void)?
    }
    private let claims: ContainerLifecycleClaims
    private var entries: [String: Entry] = [:]

    init(claims: ContainerLifecycleClaims = .shared) { self.claims = claims }

    nonisolated func perform(
        _ id: String, kind: ContainerLifecycleClaims.Kind,
        knownExit: @escaping @Sendable () async -> Bool = { false },
        operation: @escaping @Sendable (ContainerLifecycleClaims.Claim) async throws -> Void
    ) async throws {
        let caller = UUID()
        let cancellation = LifecycleCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let claim = try await begin(
                id, kind: kind, caller: caller, cancellation: cancellation, knownExit: knownExit)
            let work = Task.detached {
                do {
                    try await operation(claim)
                    await self.complete(claim, error: nil)
                } catch {
                    await self.complete(claim, error: error)
                    throw error
                }
            }
            await attach(claim, cancel: { work.cancel() })
            try await work.value
        } onCancel: {
            // Synchronous: dispatch sees cancellation even before the actor
            // receives cancelQueued or the detached worker is attached.
            cancellation.cancel()
            Task { await self.cancelQueued(caller) }
        }
    }

    /// Called inside StartGate immediately before bootstrap, or immediately
    /// before delete. The transition and a queued cancellation are atomic.
    func dispatch(_ claim: ContainerLifecycleClaims.Claim) throws {
        guard var entry = entries[claim.id], entry.claim == claim else { throw CancellationError() }
        if entry.phase == .queued && (entry.cancelled || entry.cancellation.isCancelled) {
            throw CancellationError()
        }
        entry.phase = .dispatched
        entries[claim.id] = entry
    }

    private func begin(
        _ id: String, kind: ContainerLifecycleClaims.Kind, caller: UUID, cancellation: LifecycleCancellation,
        knownExit: @escaping @Sendable () async -> Bool
    ) async throws -> ContainerLifecycleClaims.Claim {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let claim = await claims.claimIfIdle(id, kind: kind) else {
            throw MicropodError.message("failedPrecondition: container \(id) has an unfinished lifecycle operation")
        }
        guard !cancellation.isCancelled else {
            await claims.finish(claim)
            throw CancellationError()
        }
        entries[id] = Entry(claim: claim, caller: caller, cancellation: cancellation, knownExit: knownExit)
        return claim
    }

    private func attach(_ claim: ContainerLifecycleClaims.Claim, cancel: @escaping @Sendable () -> Void) {
        guard var entry = entries[claim.id], entry.claim == claim else { return }
        entry.cancelWork = cancel
        entries[claim.id] = entry
        if entry.phase == .queued && (entry.cancelled || entry.cancellation.isCancelled) { cancel() }
    }

    private func cancelQueued(_ caller: UUID) {
        guard var entry = entries.values.first(where: { $0.caller == caller }), entry.phase == .queued else { return }
        entry.cancelled = true
        entries[entry.claim.id] = entry
        entry.cancelWork?()
    }

    /// The current start's exit waiter is reset under its claim before
    /// dispatch. A real recorded exit therefore reconciles that operation;
    /// a raw stopped snapshot or a nil exit never authorizes release.
    func reconcileKnownExit(_ id: String) async {
        guard let entry = entries[id], entry.claim.kind == .starting, entry.phase == .uncertain else { return }
        guard await entry.knownExit(), entries[id]?.claim == entry.claim else { return }
        entries[id] = nil
        await claims.finish(entry.claim)
    }

    /// Admission publishes a starting claim before its worker clears the
    /// previous run's registry entry. Never attribute that old exit to the
    /// new queued start. Callers fence this read with the claims revision.
    func acceptsExitCode(_ id: String) async -> Bool {
        if let entry = entries[id] { return entry.phase != .queued }
        return await claims.kind(of: id) != .starting
    }

    private func complete(_ claim: ContainerLifecycleClaims.Claim, error: (any Error)?) async {
        guard var entry = entries[claim.id], entry.claim == claim else { return }
        if entry.claim.kind == .starting, entry.phase == .dispatched, let error,
            ContainerLifecycleClaims.outcomeUncertain(error)
        {
            // A local XPC deadline/transport loss is not an authoritative
            // operation completion. Fail closed; do not let a reaper race it.
            entry.phase = .uncertain
            entry.cancelWork = nil
            entries[claim.id] = entry
            return
        }
        entries[claim.id] = nil
        await claims.finish(claim)
    }
}

private final class LifecycleCancellation: Sendable {
    private let value = Mutex(false)
    var isCancelled: Bool { value.withLock { $0 } }
    func cancel() { value.withLock { $0 = true } }
}
