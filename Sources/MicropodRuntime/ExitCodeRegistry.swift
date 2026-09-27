import Foundation

/// Records the exit code of every container the native backend starts.
///
/// Apple's `ContainerSnapshot` carries no exit code — the only source is the
/// `containerWait` XPC route, and the runtime helper that answers it only
/// exists while the container does. So `run`/`start` register a waiter
/// (`track`) *before* `startProcess`: the helper's `ExitWaiter` accepts
/// pre-registered waiters and replays a cached status, which closes the
/// window for containers that exit within milliseconds of starting.
///
/// Each waiter is a detached task whose result is stored as an ``Entry``.
/// `WaitContainer`/`GetContainer` read entries instead of blocking on XPC in
/// the request path; ``await(id:timeout:)`` parks callers on a per-id list
/// that `record` resumes, so an exit reaches them without a poll interval. Entries and their tasks are dropped on `forget` (delete)
/// and after `ceiling` (default 2 h), which records an *unknown* exit code —
/// see ``Entry/exitCode``.
public actor ExitCodeRegistry {
    public struct Entry: Sendable, Equatable {
        /// The process exit code, or nil when it will never be known: the
        /// waiter aged out at the ceiling or failed (transport error). A nil
        /// code says nothing about whether the container has exited — consult
        /// the runtime state before treating the container as finished.
        public let exitCode: Int32?
        /// When the entry was recorded (exit observed, or given up).
        public let exitedAt: Date

        public init(exitCode: Int32?, exitedAt: Date) {
            self.exitCode = exitCode
            self.exitedAt = exitedAt
        }
    }

    private let ceiling: Duration
    private var entries: [String: Entry] = [:]
    private var waiters: [String: Task<Void, Never>] = [:]
    /// Per-id generation so a superseded waiter (re-`track` after a restart,
    /// or a `forget` racing its own completion) can never record a stale
    /// result over the current run's.
    private var generations: [String: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    /// Callers parked in ``await(id:timeout:)``, per id and keyed by a token
    /// so a timeout or cancellation resumes exactly its own continuation.
    private var parked: [String: [UInt64: Parked]] = [:]
    private var nextToken: UInt64 = 0

    private struct Parked {
        let continuation: CheckedContinuation<Entry?, Never>
        let timer: Task<Void, Never>
    }

    /// How long a waiter may run before it is dropped and the exit code is
    /// recorded as unknown.
    public init(ceiling: Duration = .seconds(7200)) {
        self.ceiling = ceiling
    }

    /// Registers a waiter task for `id`; `wait` is invoked immediately and its
    /// result stored. Tracking an id again (a restart) cancels the previous
    /// waiter and clears its entry so the old exit code is never reported for
    /// the new run.
    public func track(id: String, wait: @escaping @Sendable () async throws -> Int32) {
        waiters[id]?.cancel()
        entries[id] = nil
        nextGeneration += 1
        let generation = nextGeneration
        generations[id] = generation
        let ceiling = self.ceiling
        waiters[id] = Task {
            let exitCode = await Self.race(wait, ceiling: ceiling)
            guard !Task.isCancelled else { return }
            self.record(id: id, generation: generation, exitCode: exitCode)
        }
    }

    /// The recorded entry, if the waiter has finished (or given up).
    public func entry(for id: String) -> Entry? {
        entries[id]
    }

    /// Whether a waiter runs or has recorded for `id` — i.e. whether
    /// ``await(id:timeout:)`` will be woken by this container's exit. False
    /// for containers this process never started (CLI-created, or started
    /// before a restart) and after `forget`.
    public func isTracked(id: String) -> Bool {
        waiters[id] != nil || entries[id] != nil
    }

    /// Suspends until an entry exists for `id` or `timeout` elapses; returns
    /// the entry or nil. An existing entry returns at once; otherwise the
    /// caller parks until `record` resumes it — there is no poll. A caller
    /// may park before `track` (the request raced the start): the actor
    /// orders it against `record`, so the exit still wakes it. `forget` and
    /// task cancellation resume with nil.
    public func `await`(id: String, timeout: Duration) async -> Entry? {
        if let entry = entries[id] { return entry }
        guard timeout > .zero, !Task.isCancelled else { return nil }
        nextToken += 1
        let token = nextToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation(isolation: self) { continuation in
                // Runs on the actor before any other job: nothing can record
                // or cancel between the entry check above and this park.
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.resume(id: id, token: token, with: nil)
                }
                parked[id, default: [:]][token] = Parked(continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { await self.resume(id: id, token: token, with: nil) }
        }
    }

    /// Cancels the waiter task for `id` and drops its entry.
    public func forget(id: String) {
        waiters.removeValue(forKey: id)?.cancel()
        entries[id] = nil
        generations[id] = nil
        resumeAll(id: id, with: nil)
    }

    // MARK: - Internals

    private func record(id: String, generation: UInt64, exitCode: Int32?) {
        guard generations[id] == generation else { return }
        let entry = Entry(exitCode: exitCode, exitedAt: Date())
        entries[id] = entry
        waiters[id] = nil
        resumeAll(id: id, with: entry)
    }

    /// Resumes one parked caller; a no-op once it was resumed (the timeout,
    /// a cancellation and `record` can all race for the same token).
    private func resume(id: String, token: UInt64, with entry: Entry?) {
        guard let waiter = parked[id]?.removeValue(forKey: token) else { return }
        if parked[id]?.isEmpty == true { parked[id] = nil }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: entry)
    }

    private func resumeAll(id: String, with entry: Entry?) {
        guard let waiting = parked.removeValue(forKey: id) else { return }
        for waiter in waiting.values {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: entry)
        }
    }

    /// The waiter against the ceiling: whichever finishes first wins and the
    /// other is cancelled. A thrown waiter (cancelled, transport failure)
    /// yields nil — an unknown exit code.
    private static func race(
        _ wait: @escaping @Sendable () async throws -> Int32, ceiling: Duration
    ) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask { try? await wait() }
            group.addTask {
                try? await Task.sleep(for: ceiling)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
