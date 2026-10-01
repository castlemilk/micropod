import Foundation
import MicropodCore

/// How long a read through ``SharedReads`` may wait, and what it may be
/// answered with.
public struct ReadPolicy: Sendable, Equatable {
    /// How long the caller waits before failing with `deadlineExceeded`.
    /// The request it shares keeps waiting (up to the route's own timeout)
    /// for the callers that join it later.
    public var budget: Duration
    /// Accept an answer fetched at most this long ago — and after this
    /// client's last write that could change it. Nil: the answer comes from
    /// a request still in flight, or a new one.
    public var maxAge: Duration?
    /// When the budget runs out, answer with one up to this old instead of
    /// failing (still never one from before this client's last write).
    public var staleIfBusy: Duration?

    public init(budget: Duration, maxAge: Duration? = nil, staleIfBusy: Duration? = nil) {
        self.budget = budget
        self.maxAge = maxAge
        self.staleIfBusy = staleIfBusy
    }

    /// One-off reads: fresh, failing after 10 s as they always have.
    public static let live = ReadPolicy(budget: .seconds(10))
    /// A write's own pre-checks (a create's container list, a clone's
    /// golden): fresh, but patient. The write itself waits minutes on the
    /// same apiserver, so failing its read after 10 s only turns a slow
    /// create into a failed one.
    public static let patient = ReadPolicy(budget: .seconds(45))
    /// Poll loops (exit waits, log follows, list and stats polls): an answer
    /// up to 250 ms old will do — the fastest loops poll every 150-250 ms,
    /// so they see changes as soon as before while every poller in the
    /// window shares one request — and one up to 30 s old beats an error
    /// while the apiserver is busy: the loop asks again.
    public static let polling = ReadPolicy(
        budget: .seconds(10), maxAge: .milliseconds(250), staleIfBusy: .seconds(30))
}

/// The in-flight requests and recent answers of one apiserver read route.
///
/// container-apiserver serves reads from the same actors and locks its
/// writes hold: a volume create formats its ext4 image under the volumes
/// lock (seconds for a 300 GiB volume, a minute or more queued behind other
/// creates on a loaded host), and a container delete runs `launchctl
/// bootout` and removes the bundle on the containers actor. While CI
/// churns, a read can wait tens of seconds; when every caller sends its own
/// request and sends it again after its timeout, the late replies are
/// dropped and the queue only grows. So, per key (route + arguments):
///
/// - **Single flight.** A caller asking while a request is in flight waits
///   for it instead of sending another.
/// - **Callers give up, requests don't.** Each caller waits for its
///   ``ReadPolicy/budget``; the request waits up to the route's timeout, and
///   callers arriving meanwhile join it.
/// - **Read your writes.** ``invalidate()`` / ``invalidate(_:)`` (every
///   write through the client calls one) bump a generation: a request sent
///   before the bump is neither joined nor remembered after it.
/// - **Recent answers** serve callers whose policy allows (`maxAge`), and
///   `staleIfBusy` ones when their budget runs out.
/// - **Bounded.** At most `maxInFlight` requests at once; the rest queue
///   (the wait counts against their callers' budgets), and a queued request
///   whose callers all gave up is dropped unsent.
actor SharedReads<Value: Sendable> {
    let route: String
    private let maxInFlight: Int
    private let remember: @Sendable (Value) -> Bool
    private let clock = ContinuousClock()

    private struct Generation: Equatable {
        var all: UInt64
        var key: UInt64
    }

    private struct Flight {
        let key: String
        let generation: Generation
        let startedAt: ContinuousClock.Instant
        var sent = false
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
    }

    private struct Answer {
        let value: Value
        let at: ContinuousClock.Instant
        let generation: Generation
    }

    private var flights: [UInt64: Flight] = [:]
    /// The flight a caller of `key` may join: same generation, not finished.
    private var joinable: [String: UInt64] = [:]
    private var answers: [String: Answer] = [:]
    private var timers: [UInt64: Task<Void, Never>] = [:]
    private var epoch: UInt64 = 0
    private var keyEpochs: [String: UInt64] = [:]
    private var nextID: UInt64 = 0
    private var running = 0
    private var queued: [CheckedContinuation<Void, Never>] = []

    /// `remember` says whether an answer may serve later callers (a
    /// volume inspect remembers found volumes, never "not found").
    init(route: String, maxInFlight: Int = 4, remember: @escaping @Sendable (Value) -> Bool = { _ in true }) {
        self.route = route
        self.maxInFlight = max(1, maxInFlight)
        self.remember = remember
    }

    /// Answers `key` per `policy`: a remembered answer, the request in
    /// flight, or a new one — `fetch(timeout)` sends it, with the route's
    /// own `requestTimeout`.
    func read(
        _ key: String, policy: ReadPolicy, requestTimeout: Duration,
        fetch: @escaping @Sendable (Duration) async throws -> Value
    ) async throws -> Value {
        if let maxAge = policy.maxAge, let value = answer(key, maxAge: maxAge) {
            APIServerMetrics.read(route, .remembered)
            return value
        }
        let flightID: UInt64
        if let id = joinable[key], flights[id] != nil {
            flightID = id
            APIServerMetrics.read(route, .joined)
        } else {
            flightID = start(key, requestTimeout: requestTimeout, fetch: fetch)
            APIServerMetrics.read(route, .sent)
        }
        return try await wait(on: flightID, policy: policy)
    }

    /// The remembered answer for `key`, if it is at most `maxAge` old and
    /// no write has invalidated it since.
    func answer(_ key: String, maxAge: Duration) -> Value? {
        guard let answer = answers[key], answer.generation == generation(of: key),
            clock.now - answer.at <= maxAge
        else { return nil }
        return answer.value
    }

    /// Remembers `value` for `key` as of now (a write's own reply, e.g. the
    /// configuration `volumeCreate` returns).
    func remember(_ key: String, _ value: Value) {
        guard remember(value) else { return }
        answers[key] = Answer(value: value, at: clock.now, generation: generation(of: key))
    }

    /// A write that may change any key: requests already sent are not
    /// joined, nor their answers remembered, from now on.
    func invalidate() {
        epoch &+= 1
        joinable.removeAll()
        answers.removeAll()
    }

    /// A write that may change `key` only.
    func invalidate(_ key: String) {
        keyEpochs[key, default: 0] &+= 1
        joinable[key] = nil
        answers[key] = nil
    }

    /// Callers waiting on `key`'s joinable request.
    func waiterCount(_ key: String) -> Int {
        joinable[key].flatMap { flights[$0]?.waiters.count } ?? 0
    }

    // MARK: - Flights

    private func generation(of key: String) -> Generation {
        Generation(all: epoch, key: keyEpochs[key, default: 0])
    }

    private func makeID() -> UInt64 {
        nextID &+= 1
        return nextID
    }

    private func start(
        _ key: String, requestTimeout: Duration, fetch: @escaping @Sendable (Duration) async throws -> Value
    ) -> UInt64 {
        let id = makeID()
        flights[id] = Flight(key: key, generation: generation(of: key), startedAt: clock.now)
        joinable[key] = id
        Task { await self.run(id, requestTimeout: requestTimeout, fetch: fetch) }
        return id
    }

    private func run(
        _ id: UInt64, requestTimeout: Duration, fetch: @escaping @Sendable (Duration) async throws -> Value
    ) async {
        await acquireSlot()
        guard let flight = flights[id], !flight.waiters.isEmpty else {
            // Every caller gave up while it queued: nobody is left to answer.
            releaseSlot()
            if let key = flights.removeValue(forKey: id)?.key, joinable[key] == id { joinable[key] = nil }
            APIServerMetrics.read(route, .dropped)
            return
        }
        flights[id]?.sent = true
        let result: Result<Value, any Error>
        do {
            result = .success(try await fetch(requestTimeout))
        } catch {
            result = .failure(error)
        }
        releaseSlot()
        finish(id, result)
    }

    private func finish(_ id: UInt64, _ result: Result<Value, any Error>) {
        guard let flight = flights.removeValue(forKey: id) else { return }
        if joinable[flight.key] == id { joinable[flight.key] = nil }
        if case .success(let value) = result, flight.generation == generation(of: flight.key), remember(value) {
            answers[flight.key] = Answer(value: value, at: clock.now, generation: flight.generation)
            if answers.count > 512 { forgetOldAnswers() }
        }
        for (waiterID, continuation) in flight.waiters {
            timers.removeValue(forKey: waiterID)?.cancel()
            continuation.resume(with: result)
        }
    }

    private func forgetOldAnswers() {
        let now = clock.now
        answers = answers.filter { now - $0.value.at < .seconds(120) }
    }

    // MARK: - Waiters

    private func wait(on flightID: UInt64, policy: ReadPolicy) async throws -> Value {
        try Task.checkCancellation()
        let waiterID = makeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                flights[flightID]?.waiters[waiterID] = continuation
                timers[waiterID] = Task {
                    try? await Task.sleep(for: policy.budget)
                    guard !Task.isCancelled else { return }
                    self.expire(flightID, waiterID, policy: policy)
                }
            }
        } onCancel: {
            Task { await self.resume(flightID, waiterID, with: .failure(CancellationError())) }
        }
    }

    private func resume(_ flightID: UInt64, _ waiterID: UInt64, with result: Result<Value, any Error>) {
        guard let continuation = flights[flightID]?.waiters.removeValue(forKey: waiterID) else { return }
        timers.removeValue(forKey: waiterID)?.cancel()
        continuation.resume(with: result)
    }

    /// The caller's budget ran out: a recent enough answer if its policy
    /// takes one, else `deadlineExceeded` with the same wording as an XPC
    /// timeout (callers and the agent classify on it). The flight goes on.
    private func expire(_ flightID: UInt64, _ waiterID: UInt64, policy: ReadPolicy) {
        guard let flight = flights[flightID], flight.waiters[waiterID] != nil else { return }
        if let staleIfBusy = policy.staleIfBusy, let value = answer(flight.key, maxAge: staleIfBusy) {
            APIServerMetrics.read(route, .stale)
            resume(flightID, waiterID, with: .success(value))
            return
        }
        APIServerMetrics.read(route, .budgetExceeded)
        let waited = (clock.now - flight.startedAt).secondsText
        let state =
            flight.sent
            ? "the request has waited \(waited)"
            : "the request is queued behind \(running) others"
        let error = MicropodError.message(
            "deadlineExceeded: XPC timeout for \(APIServerClient.serviceName)/\(route) "
                + "(no answer within \(policy.budget.secondsText); \(state), "
                + "\(flight.waiters.count) caller(s) waiting)")
        resume(flightID, waiterID, with: .failure(error))
    }

    // MARK: - Slots

    private func acquireSlot() async {
        if running < maxInFlight {
            running += 1
            return
        }
        await withCheckedContinuation { queued.append($0) }
    }

    /// Hands the slot to the next queued request, if any.
    private func releaseSlot() {
        if queued.isEmpty {
            running -= 1
        } else {
            queued.removeFirst().resume()
        }
    }
}

/// Apiserver traffic in the Prometheus exposition of every process that
/// serves one (MicropodAPI and the Docker shim `/metrics`):
/// `micropod_apiserver_requests_total{route,method="xpc",status}` and its
/// latency counter per XPC route, plus `method="read"` rows counting how
/// shared reads were answered (`status` = the outcome).
public enum APIServerMetrics {
    public static let shared = APIMetrics(prefix: "micropod_apiserver")

    enum ReadOutcome: String {
        /// A new request went out.
        case sent
        /// Shared a request already in flight.
        case joined
        /// Answered from a recent answer.
        case remembered
        /// Budget ran out; answered with an older answer.
        case stale
        /// Budget ran out; failed with deadlineExceeded.
        case budgetExceeded = "budget_exceeded"
        /// Queued request dropped unsent: every caller had given up.
        case dropped
    }

    static func read(_ route: String, _ outcome: ReadOutcome) {
        shared.record(
            route: route, method: "read", label: outcome.rawValue, isError: outcome == .budgetExceeded, duration: 0)
    }

    /// One XPC request: `status` is 200, 504 (timed out), 503 (transport)
    /// or 500 (the apiserver answered an error).
    static func xpc(_ route: String, status: Int, duration: Duration) {
        shared.record(route: route, method: "xpc", status: status, duration: duration.seconds)
    }

    public static func render() -> String {
        shared.render()
    }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// "12.3s", for log lines and errors.
    var secondsText: String {
        String(format: "%.1fs", seconds)
    }
}
