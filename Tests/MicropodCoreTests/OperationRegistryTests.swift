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
}
