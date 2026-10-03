import Observation
import XCTest

@testable import MicropodCore

final class OperationRegistryTests: XCTestCase {
    func testOperationsMutationIsObservable() {
        let registry = OperationRegistry()
        let mutation = expectation(description: "operations mutation observed")

        withObservationTracking {
            _ = registry.operations
        } onChange: {
            mutation.fulfill()
        }

        _ = registry.begin("Pull nginx:1.27", kind: .pull)

        wait(for: [mutation], timeout: 1)
    }

    func testContainerLaunchKindIsSupported() {
        let registry = OperationRegistry()
        let id = registry.begin("Run agent", kind: .container)

        XCTAssertEqual(registry.operation(id)?.kind, .container)
    }

    func testBeginRegistersRunningOperation() {
        let registry = OperationRegistry()
        let id = registry.begin("Pull nginx:1.27", kind: .pull)
        let op = registry.operation(id)
        XCTAssertNotNil(op)
        XCTAssertEqual(op?.title, "Pull nginx:1.27")
        XCTAssertEqual(op?.kind, .pull)
        XCTAssertEqual(op?.status, .running)
        XCTAssertEqual(registry.runningCount, 1)
    }

    func testUpdateAppendsEvents() {
        let registry = OperationRegistry()
        let id = registry.begin("Build my/app", kind: .build)
        registry.update(id) { $0.events.append("step 1") }
        registry.update(id) { $0.events.append("step 2") }
        XCTAssertEqual(registry.operation(id)?.events, ["step 1", "step 2"])
    }

    func testFinishMarksSucceeded() {
        let registry = OperationRegistry()
        let id = registry.begin("Pull nginx", kind: .pull)
        registry.finish(id, status: .succeeded)
        XCTAssertEqual(registry.operation(id)?.status, .succeeded)
        XCTAssertEqual(registry.runningCount, 0)
    }

    func testFailedStatus() {
        let registry = OperationRegistry()
        let id = registry.begin("Compose up stack", kind: .compose)
        registry.finish(id, status: .failed("boom"))
        XCTAssertEqual(registry.operation(id)?.status, .failed("boom"))
    }

    func testCancelPropagatesToTask() {
        let registry = OperationRegistry()
        let id = registry.begin("Pull nginx", kind: .pull)
        let expectation = expectation(description: "cancelled")
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        registry.registerTask(id, task)
        registry.cancel(id)
        Task {
            _ = await task.result
            if task.isCancelled { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 2)
    }

    func testClearFinishedKeepsRunning() {
        let registry = OperationRegistry()
        let done = registry.begin("Pull a", kind: .pull)
        let running = registry.begin("Pull b", kind: .pull)
        registry.finish(done, status: .succeeded)
        registry.clearFinished()
        XCTAssertEqual(registry.operations.count, 1)
        XCTAssertEqual(registry.operations.first?.id, running)
    }

    func testFinishedHistoryRetainsNewestHundredEntriesAndEveryRunningOperation() {
        let registry = OperationRegistry()
        let ids = (0..<105).map { index in
            registry.begin("Operation \(index)", kind: .pull)
        }

        for id in ids.prefix(101) {
            registry.finish(id, status: .succeeded)
        }

        let finished = registry.operations.filter { $0.status != .running }
        let running = registry.operations.filter { $0.status == .running }

        XCTAssertEqual(finished.count, 100)
        XCTAssertEqual(finished.map(\.id), Array(ids[1..<101]))
        XCTAssertEqual(running.map(\.id), Array(ids.suffix(4)))
        XCTAssertNil(registry.operation(ids[0]))
    }

    func testFinishedHistoryUsesCompletionOrderWhenOperationsFinishOutOfOrder() {
        let registry = OperationRegistry()
        let ids = (0..<101).map { index in
            registry.begin("Operation \(index)", kind: .pull)
        }

        for id in ids.dropFirst() {
            registry.finish(id, status: .succeeded)
        }
        registry.finish(ids[0], status: .succeeded)

        XCTAssertNil(registry.operation(ids[1]))
        XCTAssertNotNil(registry.operation(ids[0]))
        XCTAssertEqual(
            registry.operations.map(\.id),
            Array(ids.dropFirst(2)) + [ids[0]]
        )
    }
    func testOneHundredThousandEventsRetainBoundedRecentOutput() {
        let registry = OperationRegistry()
        let id = registry.begin("Busy build", kind: .build)
        for index in 0..<100_000 { registry.appendEvent("step \(index)", to: id) }
        let operation = registry.operation(id)!
        XCTAssertEqual(operation.events.count, ActiveOperation.maximumEventCount)
        XCTAssertEqual(operation.events.first, "step \(100_000 - ActiveOperation.maximumEventCount)")
        XCTAssertEqual(operation.events.last, "step 99999")
        XCTAssertEqual(operation.discardedEventCount, 100_000 - ActiveOperation.maximumEventCount)
        XCTAssertEqual(operation.truncatedEventCount, 0)
        XCTAssertEqual(operation.retainedEventBytes, operation.events.reduce(0) { $0 + $1.utf8.count })
        XCTAssertLessThanOrEqual(operation.retainedEventBytes, ActiveOperation.maximumEventBytes)
        XCTAssertEqual(operation.status, .running)
    }

    func testByteBudgetEvictsLongEventsBeforeCountLimit() {
        let registry = OperationRegistry()
        let id = registry.begin("Verbose pull", kind: .pull)
        let event = String(repeating: "x", count: ActiveOperation.maximumSingleEventBytes)
        registry.appendEvents(repeatElement(event, count: 1000), to: id)
        let operation = registry.operation(id)!
        let expectedCount = ActiveOperation.maximumEventBytes / event.utf8.count
        XCTAssertEqual(operation.events.count, expectedCount)
        XCTAssertEqual(operation.retainedEventBytes, expectedCount * event.utf8.count)
        XCTAssertEqual(operation.discardedEventCount, 1000 - expectedCount)
    }

    func testPathologicalSingleEventIsUTF8SafeAndBounded() {
        let registry = OperationRegistry()
        let id = registry.begin("Noisy operation", kind: .compose)
        let event = String(repeating: "🚀", count: 1_000_000) + " completed"
        registry.appendEvent(event, to: id)
        let operation = registry.operation(id)!
        XCTAssertEqual(operation.events.count, 1)
        XCTAssertEqual(operation.discardedEventCount, 0)
        XCTAssertEqual(operation.truncatedEventCount, 1)
        XCTAssertLessThanOrEqual(operation.retainedEventBytes, ActiveOperation.maximumSingleEventBytes)
        XCTAssertTrue(operation.events[0].hasSuffix(" completed"))
        XCTAssertTrue(operation.events[0].hasPrefix("[Earlier output truncated] "))
        XCTAssertFalse(operation.events[0].contains("�"))
    }

    func testLegacyMutationAndBatchUpdatesBothApplyBounds() {
        let registry = OperationRegistry()
        let id = registry.begin("Legacy updater", kind: .container)
        registry.update(id) { $0.events = (0..<1000).map { "line \($0)" } }
        registry.update(id) { $0.events.append("newest") }
        let operation = registry.operation(id)!
        XCTAssertEqual(operation.events.count, ActiveOperation.maximumEventCount)
        XCTAssertEqual(operation.events.last, "newest")
        XCTAssertEqual(operation.discardedEventCount, 1001 - ActiveOperation.maximumEventCount)
        XCTAssertLessThanOrEqual(operation.retainedEventBytes, ActiveOperation.maximumEventBytes)
    }

    func testBatchPublishesOneObservableMutation() {
        let registry = OperationRegistry()
        let id = registry.begin("Batched build", kind: .build)
        let mutation = expectation(description: "event batch observed")
        withObservationTracking {
            _ = registry.operations
        } onChange: {
            mutation.fulfill()
        }
        registry.appendEvents(["first", "second", "last"], to: id)
        wait(for: [mutation], timeout: 1)
        XCTAssertEqual(registry.operation(id)?.events, ["first", "second", "last"])
    }

    func testFinishedHistoryByteBoundKeepsRunningOperations() {
        let registry = OperationRegistry()
        let running = registry.begin("Still working", kind: .build)
        let event = String(repeating: "x", count: ActiveOperation.maximumSingleEventBytes)
        registry.appendEvents(repeatElement(event, count: 100), to: running)
        for index in 0..<110 {
            let id = registry.begin("Finished \(index)", kind: .pull)
            registry.appendEvents(repeatElement(event, count: 100), to: id)
            registry.finish(id, status: .succeeded)
        }
        XCTAssertEqual(registry.operations.count, 101)
        XCTAssertNotNil(registry.operation(running))
        XCTAssertEqual(registry.runningCount, 1)
        XCTAssertLessThanOrEqual(
            registry.operations.reduce(0) { $0 + $1.retainedEventBytes },
            101 * ActiveOperation.maximumEventBytes)
    }

}
