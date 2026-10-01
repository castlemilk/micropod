import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim

/// Deterministic tests for the EventsHub reconcile state machine —
/// especially the fast-exit paths that wall-clock tests can only catch
/// flakily: a container that runs+exits between polls, or while an attach
/// veto blinds hasEverStarted, must still produce exactly one die event
/// (legacy API<1.30 clients hang on /events without it).
final class EventsHubReconcileTests: XCTestCase {
    /// Scripted ContainerServing: each list() returns the next script step
    /// (holding the last). Everything else is unimplemented.
    final actor ScriptedContainers: ContainerServing {
        private let scripts: [[Micropod_V1_Container]]
        private var calls = 0
        private(set) var deleted: [String] = []

        init(_ scripts: [[Micropod_V1_Container]]) {
            self.scripts = scripts
        }

        func list() async throws -> [Micropod_V1_Container] {
            let step = scripts[min(calls, scripts.count - 1)]
            calls += 1
            return step
        }

        func inspect(_ id: String) async throws -> Data {
            throw MicropodError.message("unused in reconcile tests")
        }

        func create(_ request: ContainerRunRequest) async throws -> String { throw MicropodError.message("unused") }
        func run(_ request: ContainerRunRequest) async throws -> String { throw MicropodError.message("unused") }
        func exec(_ request: ContainerExecRequest) async throws -> String { throw MicropodError.message("unused") }
        func start(_ id: String) async throws {}
        func stop(_ id: String, timeout: Int) async throws {}
        func restart(_ id: String) async throws {}
        func stopAll() async throws {}
        func kill(_ id: String, signal: String) async throws {}
        func delete(_ id: String, force: Bool) async throws { deleted.append(id) }
        func deleteAll(force: Bool) async throws {}
        func prune() async throws -> String { "" }
        func export(_ id: String, to outputPath: String) async throws {}
        func copy(from: String, to: String) async throws {}
    }

    /// ContainerServing whose list() reports the current state — like the
    /// runtime — and can hold one list() call: the snapshot is taken at call
    /// time, the reply delivered on release (a slow poll racing a start).
    final actor LiveContainers: ContainerServing {
        private var current: Micropod_V1_Container
        private var holdNext = false
        private var held: CheckedContinuation<Void, Never>?
        private(set) var deleted: [String] = []

        init(_ container: Micropod_V1_Container) { current = container }

        func set(_ container: Micropod_V1_Container) { current = container }
        func holdNextList() { holdNext = true }
        func releaseHeldList() {
            holdNext = false
            held?.resume()
            held = nil
        }

        func list() async throws -> [Micropod_V1_Container] {
            let snapshot = [current]
            if holdNext {
                holdNext = false
                await withCheckedContinuation { held = $0 }
            }
            return snapshot
        }

        func inspect(_ id: String) async throws -> Data { throw MicropodError.message("unused") }
        func create(_ request: ContainerRunRequest) async throws -> String { throw MicropodError.message("unused") }
        func run(_ request: ContainerRunRequest) async throws -> String { throw MicropodError.message("unused") }
        func exec(_ request: ContainerExecRequest) async throws -> String { throw MicropodError.message("unused") }
        func start(_ id: String) async throws {}
        func stop(_ id: String, timeout: Int) async throws {}
        func restart(_ id: String) async throws {}
        func stopAll() async throws {}
        func kill(_ id: String, signal: String) async throws {}
        func delete(_ id: String, force: Bool) async throws { deleted.append(id) }
        func deleteAll(force: Bool) async throws {}
        func prune() async throws -> String { "" }
        func export(_ id: String, to outputPath: String) async throws {}
        func copy(from: String, to: String) async throws {}
    }

    private func container(_ id: String, state: String) -> Micropod_V1_Container {
        var c = Micropod_V1_Container()
        c.id = id
        c.state = state
        c.image = "alpine:3.20"
        return c
    }

    private func body() -> DockerCreateRequest {
        DockerCreateRequest(Image: "alpine:3.20")
    }

    /// Collect decoded events for up to `seconds` (AsyncStream iteration
    /// ends when the collector task is cancelled at the deadline).
    private func collect(
        _ stream: AsyncStream<Data>, seconds: Double
    ) async -> [DockerEvent] {
        let task = Task { () -> [DockerEvent] in
            var events: [DockerEvent] = []
            for await data in stream {
                if let event = try? JSONDecoder().decode(DockerEvent.self, from: data) {
                    events.append(event)
                }
            }
            return events
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        return await task.value
    }

    /// Fast exit during an in-flight attach: first sighting is stopped with
    /// the veto up (deferred, exactly one create), then the attach clears
    /// and the next poll must emit exactly one die — never zero, never two.
    func testFastExitDuringAttachEmitsOneDie() async throws {
        let id = "fast-exit-1"
        let stopped = container(id, state: "stopped")
        // subscribe consumes [0], boot snapshot consumes [1], polls see [2+].
        let serving = ScriptedContainers([[], [], [stopped], [stopped], [stopped], [stopped]])
        let hub = EventsHub(containers: serving, interval: 0.05)
        let state = ShimState()
        await state.remember(id: id, name: id, request: body())
        await state.markStarted(id: id)
        await state.markAttachRunning(id: id)

        let (_, stream) = await hub.subscribe(filters: [:], state: state)
        let loop = Task { await hub.start(state: state) }
        defer { loop.cancel() }

        // Let polls run while vetoed (create emitted, die deferred).
        try? await Task.sleep(for: .seconds(0.4))
        // Attach clears: the very next polls must produce the die.
        await state.clearAttachRunning(id: id)
        try? await Task.sleep(for: .seconds(0.4))
        loop.cancel()

        let events = await collect(stream, seconds: 0.1)
        let actions = events.map(\.Action)
        XCTAssertEqual(
            actions.filter { $0 == "create" }.count, 1,
            "exactly one create, got \(actions)")
        XCTAssertEqual(
            actions.filter { $0 == "die" }.count, 1,
            "exactly one die, got \(actions)")
        if let die = events.first(where: { $0.Action == "die" }) {
            XCTAssertEqual(die.Actor.ID, id)
        } else {
            XCTFail("missing die event")
        }
    }

    /// The CI flake behind testAutoRemoveDeletesOnStop /
    /// testRestartPolicyAlwaysRestartsAfterExplicitStop: the runtime reports
    /// a created-never-started container as "stopped", and a detached start
    /// that runs and exits between two polls leaves it "stopped" — identical
    /// sightings, no transition, so the die (and with it the AutoRemove reap
    /// and restart policy) was lost forever. A settled start with no handled
    /// exit must produce exactly one die, however many polls follow.
    /// castlemilk/micropod#62: `docker run -d --rm` failed every time. The
    /// shim marks a container started *before* the runtime start, and the
    /// runtime reports "stopped" until the start lands — so a poll in that
    /// window saw "stopped" + "started", took it for an exit, and the
    /// AutoRemove reap deleted the container out from under its own start.
    /// A start in flight is not an exit: no die, no delete, until it settles.
    func testDetachedStartInFlightIsNotAnExit() async throws {
        let id = "rm62-probe"
        let serving = LiveContainers(container(id, state: "stopped"))
        let hub = EventsHub(containers: serving, interval: 0.05)
        let state = ShimState()
        var request = body()
        request.HostConfig = DockerHostConfig(AutoRemove: true)
        await state.remember(id: id, name: id, request: request)

        let (_, stream) = await hub.subscribe(filters: [:], state: state)
        let loop = Task { await hub.start(state: state) }
        defer { loop.cancel() }

        // /start began: marked started, runtime start not yet returned —
        // every poll in this window sees "stopped".
        await state.markStarted(id: id)
        await state.beginStart(id: id)
        try? await Task.sleep(for: .seconds(0.25))
        // The runtime start returns: the container is running from here on.
        await serving.set(container(id, state: "running"))
        await state.noteStartSettled(id: id)
        await state.endStart(id: id)
        try? await Task.sleep(for: .seconds(0.3))
        loop.cancel()

        let actions = await collect(stream, seconds: 0.1).map(\.Action)
        let deleted = await serving.deleted
        XCTAssertFalse(actions.contains("die"), "a start in flight is not an exit, got \(actions)")
        XCTAssertTrue(deleted.isEmpty, "AutoRemove must not reap a container mid-start, deleted \(deleted)")
    }

    /// The race CI caught: a list fetched while the start was in flight, but
    /// reconciled after it settled, still reads the pre-start "stopped". The
    /// settled start + "stopped" looked like a run that had already exited.
    /// A snapshot older than the latest start never proves an exit.
    func testSnapshotOlderThanTheStartIsNotAnExit() async throws {
        let id = "rm62-race"
        let serving = LiveContainers(container(id, state: "stopped"))
        let hub = EventsHub(containers: serving, interval: 0.05)
        let state = ShimState()
        var request = body()
        request.HostConfig = DockerHostConfig(AutoRemove: true)
        await state.remember(id: id, name: id, request: request)

        let (_, stream) = await hub.subscribe(filters: [:], state: state)
        let loop = Task { await hub.start(state: state) }
        defer { loop.cancel() }
        try? await Task.sleep(for: .seconds(0.15))

        await state.markStarted(id: id)
        await state.beginStart(id: id)
        // The next list() captures "stopped" now but doesn't return yet.
        await serving.holdNextList()
        try? await Task.sleep(for: .seconds(0.15))
        // Start settles while that stale snapshot is still in flight.
        await serving.set(container(id, state: "running"))
        await state.noteStartSettled(id: id)
        await state.endStart(id: id)
        await serving.releaseHeldList()
        try? await Task.sleep(for: .seconds(0.3))
        loop.cancel()

        let actions = await collect(stream, seconds: 0.1).map(\.Action)
        let deleted = await serving.deleted
        XCTAssertFalse(actions.contains("die"), "a stale snapshot is not an exit, got \(actions)")
        XCTAssertTrue(deleted.isEmpty, "AutoRemove must not reap on a stale snapshot, deleted \(deleted)")
    }

    func testRunAndExitBetweenPollsStillEmitsOneDie() async throws {
        let id = "between-polls-1"
        let stopped = container(id, state: "stopped")
        let serving = ScriptedContainers([[], [], [stopped]])
        let hub = EventsHub(containers: serving, interval: 0.05)
        let state = ShimState()
        await state.remember(id: id, name: id, request: body())

        let (_, stream) = await hub.subscribe(filters: [:], state: state)
        let loop = Task { await hub.start(state: state) }
        defer { loop.cancel() }

        // Polls absorb the never-started "stopped" container: no die yet.
        try? await Task.sleep(for: .seconds(0.3))
        // A detached /start the runtime accepted; the container ran and
        // exited before any poll caught it running.
        await state.markStarted(id: id)
        await state.noteStartSettled(id: id)
        try? await Task.sleep(for: .seconds(0.5))
        loop.cancel()

        let actions = await collect(stream, seconds: 0.1).map(\.Action)
        XCTAssertEqual(actions.filter { $0 == "die" }.count, 1, "exactly one die, got \(actions)")
    }

    /// Never-started container: absorbed silently, no die, no reap pressure.
    /// (hasEverStarted false, no attach veto → settle, no handleExit.)
    func testNeverStartedContainerEmitsNoDie() async throws {
        let id = "never-started-1"
        let stopped = container(id, state: "stopped")
        // subscribe consumes [0], boot snapshot [1], polls see [2+].
        let serving = ScriptedContainers([[], [], [stopped], [stopped]])
        let hub = EventsHub(containers: serving, interval: 0.05)
        let state = ShimState()
        // Remembered (shim-created) but never started, no attach.
        await state.remember(id: id, name: id, request: body())

        let (_, stream) = await hub.subscribe(filters: [:], state: state)
        let loop = Task { await hub.start(state: state) }
        defer { loop.cancel() }
        try? await Task.sleep(for: .seconds(0.5))
        loop.cancel()

        let events = await collect(stream, seconds: 0.1)
        let actions = events.map(\.Action)
        XCTAssertEqual(actions.filter { $0 == "create" }.count, 1)
        XCTAssertTrue(
            actions.filter { $0 == "die" }.isEmpty,
            "never-started container must not die, got \(actions)")
    }

    /// Legacy subscribe-before-start flow: reseed records fake-created, then
    /// the run is missed entirely between polls (no running step) — the die
    /// must still fire exactly once via hasStarted.
    func testReseedFakeCreatedTransitionsFire() async throws {
        let id = "reseed-1"
        let created = container(id, state: "stopped")  // Apple reports created as stopped
        let stopped = container(id, state: "stopped")
        // subscribe sees [0]=created, boot snapshot [1]=created, polls see
        // stopped from [2] on (running phase missed entirely).
        let serving = ScriptedContainers([[created], [created], [stopped], [stopped], [stopped]])
        let hub = EventsHub(containers: serving, interval: 0.05)
        let state = ShimState()
        await state.remember(id: id, name: id, request: body())

        // Subscribe FIRST (snapshot absorbs created silently), then start.
        let (_, stream) = await hub.subscribe(filters: [:], state: state)
        let loop = Task { await hub.start(state: state) }
        defer { loop.cancel() }
        await state.markStarted(id: id)
        try? await Task.sleep(for: .seconds(0.6))
        loop.cancel()

        let events = await collect(stream, seconds: 0.1)
        let actions = events.map(\.Action)
        XCTAssertEqual(actions.filter { $0 == "die" }.count, 1, "got \(actions)")
        // And no create: it was pre-existing at subscribe time.
        XCTAssertTrue(actions.filter { $0 == "create" }.isEmpty, "got \(actions)")
    }
}
