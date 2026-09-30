import XCTest

@testable import MicropodRuntime

/// The `WaitContainer` loop against a scripted runtime state: tracked
/// containers wake on the registry's exit signal, untracked ones fall back
/// to a state poll. No live runtime needed.
final class ContainerExitWaitTests: XCTestCase {

    /// A tracked container's exit returns the wait as soon as it is recorded,
    /// long before the next state poll, and the runtime is barely asked.
    func testTrackedExitWakesTheWait() async throws {
        let registry = ExitCodeRegistry()
        let exitAt = ExitInstant()
        await registry.track(id: "job") {
            try await Task.sleep(for: .milliseconds(200))
            await exitAt.mark()
            return 5
        }
        let states = ScriptedStates(["running"])

        let outcome = try await ContainerExitWait.wait(
            id: "job", timeout: .seconds(10), exitCodes: registry
        ) { _, _ in await states.next() }
        let returned = ContinuousClock.now

        XCTAssertEqual(outcome, .init(exited: true, known: true, exitCode: 5, state: "running"))
        let recorded = await exitAt.instant
        let exited = try XCTUnwrap(recorded)
        XCTAssertLessThan(returned - exited, .milliseconds(50), "the recorded exit must wake the wait")
        let calls = await states.calls
        XCTAssertLessThanOrEqual(calls, 2, "no state polling while parked on the registry")
    }

    /// An exit recorded before the request returns on the first pass.
    func testExitRecordedBeforeWaitReturnsAtOnce() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "job") { 3 }
        _ = await registry.await(id: "job", timeout: .seconds(2))
        let states = ScriptedStates(["stopped"])

        let started = ContinuousClock.now
        let outcome = try await ContainerExitWait.wait(
            id: "job", timeout: .seconds(10), exitCodes: registry
        ) { _, exitKnown in
            XCTAssertTrue(exitKnown)
            return await states.next()
        }
        XCTAssertEqual(outcome, .init(exited: true, known: true, exitCode: 3, state: "stopped"))
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(50))
    }

    func testTimeoutIsHonoured() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "job") {
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        let states = ScriptedStates(["running"])

        let started = ContinuousClock.now
        let outcome = try await ContainerExitWait.wait(
            id: "job", timeout: .milliseconds(300), exitCodes: registry
        ) { _, _ in await states.next() }
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(outcome, .init(exited: false, known: false, exitCode: nil, state: "running"))
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(290))
        XCTAssertLessThan(elapsed, .seconds(1))
        await registry.forget(id: "job")
    }

    /// A container the registry never tracked (CLI-created, or started
    /// before this process) is polled at the untracked cadence until it stops.
    func testUntrackedContainerFallsBackToStatePoll() async throws {
        let registry = ExitCodeRegistry()
        let states = ScriptedStates(["running", "running", "stopped"])

        let started = ContinuousClock.now
        let outcome = try await ContainerExitWait.wait(
            id: "cli-made", timeout: .seconds(10), exitCodes: registry, untrackedPoll: .milliseconds(200)
        ) { _, _ in await states.next() }
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(outcome, .init(exited: true, known: false, exitCode: nil, state: "stopped"))
        let calls = await states.calls
        XCTAssertEqual(calls, 3)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(390), "two polls at the untracked cadence")
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// Without a registry signal the default poll keeps the pre-registry
    /// 150 ms cadence: the CLI backend, CLI-created containers and ones
    /// started before a restart must not see their exit a second late.
    func testUntrackedDefaultPollKeepsExitLatencyLow() async throws {
        let registry = ExitCodeRegistry()
        for exitCodes in [nil, registry] {
            let states = ScriptedStates(["running", "stopped"])
            let started = ContinuousClock.now
            let outcome = try await ContainerExitWait.wait(
                id: "cli-made", timeout: .seconds(10), exitCodes: exitCodes
            ) { _, _ in await states.next() }
            let elapsed = ContinuousClock.now - started

            XCTAssertEqual(outcome, .init(exited: true, known: false, exitCode: nil, state: "stopped"))
            XCTAssertLessThan(elapsed, .milliseconds(400), "one untracked poll, not a 1 s safety net")
        }
    }

    /// The CLI backend has no registry at all: same untracked poll.
    func testNoRegistryPollsState() async throws {
        let states = ScriptedStates(["running", "stopped"])
        let outcome = try await ContainerExitWait.wait(
            id: "cli", timeout: .seconds(10), exitCodes: nil, untrackedPoll: .milliseconds(100)
        ) { _, _ in await states.next() }
        XCTAssertEqual(outcome, .init(exited: true, known: false, exitCode: nil, state: "stopped"))
    }

    /// An entry without a code (waiter aged out) never gets a real one, so
    /// the wait polls state at the untracked cadence instead of spinning on it.
    func testUnknownCodeEntryDoesNotSpin() async throws {
        let registry = ExitCodeRegistry(ceiling: .milliseconds(10))
        await registry.track(id: "aged") {
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        _ = await registry.await(id: "aged", timeout: .seconds(2))
        let states = ScriptedStates(["running"])

        let outcome = try await ContainerExitWait.wait(
            id: "aged", timeout: .milliseconds(350), exitCodes: registry, untrackedPoll: .milliseconds(100)
        ) { _, _ in await states.next() }

        XCTAssertFalse(outcome.exited)
        let calls = await states.calls
        XCTAssertLessThanOrEqual(calls, 6, "state read at the poll cadence, not in a loop (\(calls))")
    }

    /// A sandbox-engine container parks on the engine's exit signal: the
    /// wait returns when the engine sees the exit, not on the next poll.
    func testEngineSignalWakesTheWait() async throws {
        let states = ScriptedStates(["running", "stopped"])
        let started = ContinuousClock.now
        let outcome = try await ContainerExitWait.wait(
            id: "sbx", timeout: .seconds(10), exitCodes: ExitCodeRegistry(), untrackedPoll: .seconds(5),
            park: { _, _ in
                try? await Task.sleep(for: .milliseconds(50))
                return true
            },
            state: { _, _ in await states.next() })
        XCTAssertEqual(outcome, .init(exited: true, known: false, exitCode: nil, state: "stopped"))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "woken by the engine, not a 5 s poll")
    }

    /// An engine that does not own the container declines to park: the wait
    /// falls back to the untracked poll.
    func testDeclinedParkFallsBackToPoll() async throws {
        let states = ScriptedStates(["running", "stopped"])
        let outcome = try await ContainerExitWait.wait(
            id: "apple", timeout: .seconds(10), exitCodes: nil, untrackedPoll: .milliseconds(50),
            park: { _, _ in false }, state: { _, _ in await states.next() })
        XCTAssertEqual(outcome, .init(exited: true, known: false, exitCode: nil, state: "stopped"))
    }

    /// A runtime that stops answering mid-wait fails the wait.
    func testStateErrorPropagates() async throws {
        struct Down: Error {}
        do {
            _ = try await ContainerExitWait.wait(
                id: "x", timeout: .seconds(1), exitCodes: nil
            ) { _, _ in throw Down() }
            XCTFail("expected the state error")
        } catch is Down {}
    }
}

/// Answers the scripted states in order, repeating the last one.
private actor ScriptedStates {
    private let script: [String]
    private(set) var calls = 0

    init(_ script: [String]) { self.script = script }

    func next() -> String {
        defer { calls += 1 }
        return script[min(calls, script.count - 1)]
    }
}

private actor ExitInstant {
    private(set) var instant: ContinuousClock.Instant?
    func mark() { instant = .now }
}
