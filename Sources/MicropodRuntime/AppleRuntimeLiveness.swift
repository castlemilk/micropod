import Foundation
import MicropodCore
import Synchronization

/// Whether Apple's container runtime (its `container-apiserver`) is up, kept
/// off the request path: the ``ContainerRuntimeGate`` behind the API's
/// `container` client, so a server whose default runtime is another engine
/// spawns no `container` child to learn, request after request, that Apple's
/// runtime is down.
///
/// One XPC `ping` decides, with no child process: an answer is `up`; a
/// transport failure (the mach service is not registered, which is what
/// `container system status` reports as `unregistered`, and what every other
/// `container` command fails on) is `down`; anything else (a timeout) is
/// `unknown`, which never refuses a command. A ping to an unregistered
/// service fails in about 50 µs.
///
/// Bound: a `down` that refuses a command was observed at most `maxAge`
/// (2 s) before, plus one probe. The state is probed once at `start()`,
/// probed again in the background once it is `refreshAfter` (1 s) old so
/// steady traffic never waits, and expires at `maxAge`: a caller that finds
/// it expired waits for the probe (`state()`) or, when it cannot wait
/// (`knownState()`), treats it as unknown and spawns as before. `system
/// start` and `system stop` through a gated client forget it at once
/// (``runtimeMayHaveChanged()``). Probes are single-flight.
public final class AppleRuntimeLiveness: ContainerRuntimeGate {
    public enum State: Sendable, Equatable {
        case up
        case down
        case unknown
    }

    private struct Observation {
        var state: State
        var health: APIServerHealth?
        /// When the probe that produced it started.
        var at: ContinuousClock.Instant
    }

    private struct Inner {
        var observed: Observation?
        var probe: (generation: Int, task: Task<State, Never>)?
        /// Bumped by `runtimeMayHaveChanged`: a probe started earlier
        /// records nothing.
        var generation = 0
    }

    private let inner = Mutex(Inner())
    private let probe: @Sendable () async -> (State, APIServerHealth?)
    public let maxAge: Duration
    public let refreshAfter: Duration

    public init(
        maxAge: Duration = .seconds(2), refreshAfter: Duration? = nil,
        probe: @escaping @Sendable () async -> (State, APIServerHealth?) = { await AppleRuntimeLiveness.ping() }
    ) {
        self.maxAge = maxAge
        self.refreshAfter = refreshAfter ?? maxAge / 2
        self.probe = probe
    }

    /// One XPC `ping` over a fresh connection (an invalidated connection
    /// never recovers, so none is kept between probes).
    public static func ping(
        service: String = APIServerClient.serviceName, timeout: Duration = .seconds(2)
    ) async -> (State, APIServerHealth?) {
        do {
            return (.up, try await APIServerClient(service: service).ping(timeout: timeout))
        } catch {
            return (ConnectCodeMapping.code(for: error) == "unavailable" ? .down : .unknown, nil)
        }
    }

    /// Probes once now, in the background.
    public func start() { _ = startProbe() }

    /// The state, waiting for a probe only when nothing fresh is known.
    public func state() async -> State {
        if let fresh = fresh() { return fresh }
        return await startProbe().value
    }

    /// The state without waiting: `unknown` when nothing fresh is known
    /// (a probe then starts in the background).
    public func knownState() -> State {
        if let fresh = fresh() { return fresh }
        _ = startProbe()
        return .unknown
    }

    /// The apiserver's identity from the last probe that reached it.
    public var health: APIServerHealth? { inner.withLock { $0.observed?.health } }

    // MARK: ContainerRuntimeGate

    public func runtimeIsDown() async -> Bool { await state() == .down }

    public func runtimeIsKnownDown() -> Bool { knownState() == .down }

    /// Up as of now: the backend's own ping just reached the apiserver. A
    /// `down` observed a moment before (the runtime started outside this
    /// process) must not refuse the commands of the backend that ping just
    /// chose, such as the init image read behind a create.
    public func runtimeAnswered() {
        inner.withLock { inner in
            inner.generation += 1
            inner.observed = Observation(state: .up, health: inner.observed?.health, at: .now)
            inner.probe = nil
        }
    }

    public func runtimeMayHaveChanged() {
        inner.withLock { inner in
            inner.generation += 1
            inner.observed = nil
            inner.probe = nil
        }
        _ = startProbe()
    }

    // MARK: Probing

    /// The kept state while it is younger than `maxAge`, starting the
    /// background refresh once it is `refreshAfter` old.
    private func fresh() -> State? {
        let now = ContinuousClock.now
        guard let observed = inner.withLock({ $0.observed }), now - observed.at < maxAge else { return nil }
        if now - observed.at >= refreshAfter { _ = startProbe() }
        return observed.state
    }

    private func startProbe() -> Task<State, Never> {
        inner.withLock { inner in
            if let running = inner.probe, running.generation == inner.generation { return running.task }
            let generation = inner.generation
            let probe = self.probe
            let task = Task { [weak self] in
                let started = ContinuousClock.now
                let (state, health) = await probe()
                self?.record(state, health: health, at: started, generation: generation)
                return state
            }
            inner.probe = (generation, task)
            return task
        }
    }

    private func record(_ state: State, health: APIServerHealth?, at started: ContinuousClock.Instant, generation: Int)
    {
        inner.withLock { inner in
            guard inner.generation == generation else { return }
            inner.observed = Observation(state: state, health: health ?? inner.observed?.health, at: started)
            inner.probe = nil
        }
    }
}
