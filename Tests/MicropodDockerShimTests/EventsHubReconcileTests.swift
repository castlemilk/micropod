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
        func delete(_ id: String, force: Bool) async throws {}
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
