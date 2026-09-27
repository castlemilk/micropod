import XCTest

@testable import MicropodRuntime

/// The exit-code registry records what `containerWait` returns for every
/// container the native backend starts, so `WaitContainer`/`GetContainer`
/// can answer with a real exit code without a blocking XPC wait in the
/// request path. No live runtime needed — waiters are plain closures.
final class ExitCodeRegistryTests: XCTestCase {

    func testTrackStoresFastWaiterResult() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "fast") { 3 }

        let entry = await registry.await(id: "fast", timeout: .seconds(2))
        XCTAssertEqual(entry?.exitCode, 3)
        let stored = await registry.entry(for: "fast")
        XCTAssertEqual(stored, entry, "entry(for:) must return the same recorded entry")
        XCTAssertLessThan(
            abs((stored?.exitedAt ?? .distantPast).timeIntervalSinceNow), 5,
            "exitedAt is the observation time")
    }

    func testAwaitReturnsNilBeforeCompletionThenTheEntry() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "slow") {
            try await Task.sleep(for: .milliseconds(400))
            return 7
        }

        let early = await registry.await(id: "slow", timeout: .milliseconds(50))
        XCTAssertNil(early, "no entry before the waiter completes")
        let peek = await registry.entry(for: "slow")
        XCTAssertNil(peek)

        let late = await registry.await(id: "slow", timeout: .seconds(3))
        XCTAssertEqual(late?.exitCode, 7)
    }

    func testForgetCancelsHangingWaiter() async throws {
        let registry = ExitCodeRegistry()
        let observed = CancellationProbe()
        await registry.track(id: "hang") {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                await observed.markCancelled()
                throw error
            }
            return 0
        }

        await registry.forget(id: "hang")
        // Give the cancelled task a moment to unwind — it must not record.
        try await Task.sleep(for: .milliseconds(150))
        let cancelled = await observed.wasCancelled
        XCTAssertTrue(cancelled, "forget must cancel the waiter task")
        let entry = await registry.entry(for: "hang")
        XCTAssertNil(entry, "a forgotten id has no entry, even after its waiter unwinds")
        let awaited = await registry.await(id: "hang", timeout: .milliseconds(100))
        XCTAssertNil(awaited)
    }

    func testCeilingRecordsUnknownExitCode() async throws {
        let registry = ExitCodeRegistry(ceiling: .milliseconds(100))
        await registry.track(id: "ceiling") {
            try await Task.sleep(for: .seconds(60))
            return 0
        }

        let entry = await registry.await(id: "ceiling", timeout: .seconds(2))
        XCTAssertNotNil(entry, "the ceiling must record an entry so awaiters stop waiting")
        XCTAssertNil(entry?.exitCode, "an aged-out waiter records an unknown exit code")
    }

    func testThrowingWaiterRecordsUnknownExitCode() async throws {
        struct WaitFailed: Error {}
        let registry = ExitCodeRegistry()
        await registry.track(id: "boom") { throw WaitFailed() }

        let entry = await registry.await(id: "boom", timeout: .seconds(2))
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.exitCode)
    }

    func testRetrackReplacesStaleEntryAndWaiter() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "again") { 1 }
        let first = await registry.await(id: "again", timeout: .seconds(2))
        XCTAssertEqual(first?.exitCode, 1)

        // A restart tracks the same id anew: the old exit code must not be
        // reported for the new run.
        await registry.track(id: "again") {
            try await Task.sleep(for: .milliseconds(300))
            return 2
        }
        let stale = await registry.entry(for: "again")
        XCTAssertNil(stale, "re-tracking clears the previous run's entry")
        let second = await registry.await(id: "again", timeout: .seconds(3))
        XCTAssertEqual(second?.exitCode, 2)
    }

    // MARK: - Event-driven await (O4)

    /// A parked `await` is resumed by `record` itself, not by a poll: across
    /// several exits, none reaches the awaiter more than a few ms late (a
    /// 50 ms poll lands anywhere in 0–50 ms).
    func testParkedAwaitIsResumedByRecord() async throws {
        for rep in 0..<7 {
            let registry = ExitCodeRegistry()
            let exitAt = InstantProbe()
            await registry.track(id: "job") {
                try await Task.sleep(for: .milliseconds(60))
                await exitAt.mark()
                return Int32(rep)
            }
            let entry = await registry.await(id: "job", timeout: .seconds(5))
            let woke = ContinuousClock.now
            XCTAssertEqual(entry?.exitCode, Int32(rep))
            let recorded = await exitAt.instant
            let exited = try XCTUnwrap(recorded)
            XCTAssertLessThan(woke - exited, .milliseconds(20), "rep \(rep): the exit must wake the awaiter")
        }
    }

    /// A caller that arrives after the exit was recorded returns at once.
    func testAwaitAfterRecordReturnsAtOnce() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "done") { 9 }
        _ = await registry.await(id: "done", timeout: .seconds(2))

        let started = ContinuousClock.now
        let entry = await registry.await(id: "done", timeout: .seconds(5))
        XCTAssertEqual(entry?.exitCode, 9)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(20))
    }

    /// A request can park before the start registers its waiter; the later
    /// `track` + `record` still wakes it.
    func testAwaitParkedBeforeTrackIsWokenByRecord() async throws {
        let registry = ExitCodeRegistry()
        let parked = Task { await registry.await(id: "late", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        let tracked = await registry.isTracked(id: "late")
        XCTAssertFalse(tracked)
        await registry.track(id: "late") { 6 }

        let started = ContinuousClock.now
        let entry = await parked.value
        XCTAssertEqual(entry?.exitCode, 6)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))
    }

    func testAwaitHonoursTimeout() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "hang") {
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        let started = ContinuousClock.now
        let entry = await registry.await(id: "hang", timeout: .milliseconds(150))
        let elapsed = ContinuousClock.now - started
        XCTAssertNil(entry)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(140))
        XCTAssertLessThan(elapsed, .seconds(1))
        await registry.forget(id: "hang")
    }

    /// `forget` (delete) and cancellation release parked callers with nil
    /// instead of leaving them to their timeout.
    func testForgetAndCancellationResumeParkedAwaiters() async throws {
        let registry = ExitCodeRegistry()
        await registry.track(id: "gone") {
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        let forgotten = Task { await registry.await(id: "gone", timeout: .seconds(10)) }
        let cancelled = Task { await registry.await(id: "gone", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))

        let started = ContinuousClock.now
        cancelled.cancel()
        let afterCancel = await cancelled.value
        XCTAssertNil(afterCancel)
        await registry.forget(id: "gone")
        let afterForget = await forgotten.value
        XCTAssertNil(afterForget)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    func testIsTrackedFollowsTrackRecordAndForget() async throws {
        let registry = ExitCodeRegistry()
        var tracked = await registry.isTracked(id: "t")
        XCTAssertFalse(tracked)
        await registry.track(id: "t") { 0 }
        tracked = await registry.isTracked(id: "t")
        XCTAssertTrue(tracked, "a running waiter is tracked")
        _ = await registry.await(id: "t", timeout: .seconds(2))
        tracked = await registry.isTracked(id: "t")
        XCTAssertTrue(tracked, "a recorded entry stays tracked")
        await registry.forget(id: "t")
        tracked = await registry.isTracked(id: "t")
        XCTAssertFalse(tracked)
    }

    func testForgetOfUnknownIdIsANoOp() async throws {
        let registry = ExitCodeRegistry()
        await registry.forget(id: "never-tracked")
        let entry = await registry.entry(for: "never-tracked")
        XCTAssertNil(entry)
    }
}

private actor CancellationProbe {
    private(set) var wasCancelled = false
    func markCancelled() { wasCancelled = true }
}

private actor InstantProbe {
    private(set) var instant: ContinuousClock.Instant?
    func mark() { instant = .now }
}
