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
