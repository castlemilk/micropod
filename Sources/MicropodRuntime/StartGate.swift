import Synchronization

/// Process-wide single flight for container starts: one `bootstrap` →
/// exit-code `track` → `startProcess` attempt at a time
/// (`NativeContainerService.startLookingIntoNotFound`).
///
/// container-apiserver runs every container operation under one strictly
/// FIFO lock (`ContainersService`), and a start takes it twice: once for
/// `bootstrap` (launchctl, helper, VM boot, guest setup) and again for
/// `startProcess`. N concurrent starts therefore queue as R R R R S S S S —
/// every bootstrap before any init process — and all N finish together at
/// about N × T. With this gate held across the pair the order is R S R S …:
/// the k-th start is ready after about k × T and the batch takes no longer
/// (Probe A 1d, N=4, client-side equivalent: started_at p50 2806 → 1572 ms,
/// the first start 0.55 s instead of 2–4 s).
///
/// Only a start attempt holds it. Create, wait, logs, exec into a running
/// container, stop, delete and pulls never take it, nor does a start's
/// not-found lookup or retry backoff. It orders this process's starts only;
/// other apiserver clients still interleave. The price: an earlier
/// container's exit handling, which also takes the apiserver lock, now
/// queues behind the next bootstrap rather than behind the last startProcess.
///
/// Waiters are served in FIFO order and the gate is released whether the
/// body returns or throws. A waiter whose task is cancelled leaves the queue
/// at once and throws `CancellationError` without holding up those behind
/// it; a task already cancelled when the gate reaches it passes the gate on
/// and throws the same, so its body never runs. A body that has begun runs
/// to its end: the apiserver's XPC replies are not cancellable.
public final class StartGate: Sendable {
    /// The gate every start in this process takes — process-wide, like
    /// `InFlightCreates`, so a backend hot-swap cannot reset it.
    public static let shared = StartGate()

    private struct Waiter {
        let ticket: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var held = false
        var nextTicket: UInt64 = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Runs `body` as the only start attempt in this process holding this
    /// gate. Throws `CancellationError`, without running `body`, when the
    /// task is cancelled before the gate is its own. Not reentrant.
    public func withExclusive<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    /// Starts waiting for the gate (tests).
    var queued: Int { state.withLock { $0.waiters.count } }

    /// Whether a start holds the gate (tests).
    var isHeld: Bool { state.withLock { $0.held } }

    private func acquire() async throws {
        let ticket = state.withLock { state in
            state.nextTicket &+= 1
            return state.nextTicket
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancellation sets the flag before it runs the handler below,
                // so reading the flag under the lock leaves no gap: either it
                // is seen here, or the handler finds this waiter queued.
                let settled: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if !state.held {
                        state.held = true
                        return .success(())
                    }
                    state.waiters.append(Waiter(ticket: ticket, continuation: continuation))
                    return nil
                }
                if let settled { continuation.resume(with: settled) }
            }
        } onCancel: {
            let left = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.ticket == ticket }) else { return nil }
                return state.waiters.remove(at: index)
            }
            left?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Hands the gate straight to the longest waiter (`held` stays set), or
    /// frees it when nobody waits.
    private func release() {
        let next = state.withLock { state -> Waiter? in
            guard !state.waiters.isEmpty else {
                state.held = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.continuation.resume()
    }
}
