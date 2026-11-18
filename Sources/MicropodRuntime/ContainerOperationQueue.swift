import Synchronization

/// Container requests this process has handed to Apple's apiserver and not
/// yet seen answered, for `Ping`'s `container_operations`.
///
/// container-apiserver runs container operations one at a time behind one
/// strictly FIFO lock (``StartGate``), while its `ping` skips that lock, so
/// a runtime can answer Ping in milliseconds with minutes of work queued.
/// What this process can observe truthfully is its own share of that queue:
/// every container request it sent, from send until the apiserver's reply —
/// including requests whose caller already gave up on a deadline, which
/// the apiserver still runs in order ("abandoned"). Other clients of the
/// same apiserver are not counted.
///
/// Counted routes are the container routes whose length is the runtime's,
/// not the workload's or the payload's: `containerWait` (open until the
/// process exits) and the copy/export transfers are left out, as are
/// volume, network, image and plugin routes, which do not take the
/// containers lock.
public final class ContainerOperationQueue: Sendable {
    public static let shared = ContainerOperationQueue()

    public struct Snapshot: Equatable, Sendable {
        /// Sent, no reply yet.
        public var inFlight = 0
        /// Of `inFlight`, those whose caller already stopped waiting.
        public var abandoned = 0
        /// Starts waiting in this process for ``StartGate``, not yet sent.
        public var waiting = 0
        /// Age of the oldest operation counted in `depth`; zero when none.
        public var oldestAge: Duration = .zero
        public var depth: Int { inFlight + waiting }

        public init(inFlight: Int = 0, abandoned: Int = 0, waiting: Int = 0, oldestAge: Duration = .zero) {
            self.inFlight = inFlight
            self.abandoned = abandoned
            self.waiting = waiting
            self.oldestAge = oldestAge
        }
    }

    /// One counted request, from send until its reply.
    public struct Ticket: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    private struct Entry {
        let sentAt: ContinuousClock.Instant
        var abandoned = false
    }

    private struct State {
        var next: UInt64 = 0
        var entries: [UInt64: Entry] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    static let uncounted: Set<String> = [
        "containerWait", "containerCopyIn", "containerCopyOut", "containerExport", "containerEvent",
    ]

    /// Whether `route` is counted (see the type's documentation).
    public static func counts(_ route: String) -> Bool {
        route.hasPrefix("container") && !uncounted.contains(route)
    }

    /// Records a request about to be sent; nil for a route that is not counted.
    public func sent(_ route: String, at now: ContinuousClock.Instant = .now) -> Ticket? {
        guard Self.counts(route) else { return nil }
        return state.withLock { state in
            state.next &+= 1
            state.entries[state.next] = Entry(sentAt: now)
            return Ticket(id: state.next)
        }
    }

    /// The caller stopped waiting (deadline or cancellation); the request
    /// stays counted until the apiserver answers it.
    public func abandoned(_ ticket: Ticket?) {
        guard let ticket else { return }
        state.withLock { state in state.entries[ticket.id]?.abandoned = true }
    }

    /// The apiserver answered, or the connection failed.
    public func answered(_ ticket: Ticket?) {
        guard let ticket else { return }
        _ = state.withLock { state in state.entries.removeValue(forKey: ticket.id) }
    }

    /// This process's queue now, with the starts waiting for `gate`.
    public func snapshot(gate: StartGate = .shared, now: ContinuousClock.Instant = .now) -> Snapshot {
        var snapshot = state.withLock { state -> Snapshot in
            var snapshot = Snapshot()
            snapshot.inFlight = state.entries.count
            snapshot.abandoned = state.entries.values.filter(\.abandoned).count
            if let oldest = state.entries.values.map(\.sentAt).min() { snapshot.oldestAge = now - oldest }
            return snapshot
        }
        let waiting = gate.waiting()
        snapshot.waiting = waiting.count
        if let oldest = waiting.oldest { snapshot.oldestAge = max(snapshot.oldestAge, now - oldest) }
        return snapshot
    }
}
