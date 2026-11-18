import Foundation
import XCTest

@testable import MicropodRuntime

/// Ping's `container_operations`: this process's container requests from
/// send until the apiserver answers, plus starts waiting for the gate.
final class ContainerOperationQueueTests: XCTestCase {
    func testCountsContainerRoutesWhoseLengthIsTheRuntimes() {
        for route in [
            "containerCreate", "containerBootstrap", "containerStartProcess", "containerDelete", "containerList",
        ] {
            XCTAssertTrue(ContainerOperationQueue.counts(route), route)
        }
        for route in [
            "containerWait", "containerCopyIn", "containerCopyOut", "containerExport", "volumeCreate", "ping",
        ] {
            XCTAssertFalse(ContainerOperationQueue.counts(route), route)
        }
    }

    func testRequestsStayCountedPastTheirCallersDeadlineUntilAnswered() {
        let queue = ContainerOperationQueue()
        let gate = StartGate()
        let start = ContinuousClock.now
        XCTAssertNil(queue.sent("volumeCreate", at: start))
        let create = queue.sent("containerCreate", at: start)
        let delete = queue.sent("containerDelete", at: start.advanced(by: .seconds(5)))
        queue.abandoned(create)
        XCTAssertEqual(
            queue.snapshot(gate: gate, now: start.advanced(by: .seconds(65))),
            .init(inFlight: 2, abandoned: 1, waiting: 0, oldestAge: .seconds(65)))
        queue.answered(create)
        queue.abandoned(create)  // a deadline that fires after the reply changes nothing
        XCTAssertEqual(
            queue.snapshot(gate: gate, now: start.advanced(by: .seconds(65))),
            .init(inFlight: 1, abandoned: 0, waiting: 0, oldestAge: .seconds(60)))
        queue.answered(delete)
        XCTAssertEqual(queue.snapshot(gate: gate, now: start.advanced(by: .seconds(65))), .init())
    }

    func testStartsWaitingForTheGateAreCountedWithTheirAge() async throws {
        let queue = ContainerOperationQueue()
        let gate = StartGate()
        let release = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await gate.withExclusive {
                for await _ in release.stream { break }
            }
        }
        while !gate.isHeld { try await Task.sleep(for: .milliseconds(5)) }
        let waiter = Task { try await gate.withExclusive {} }
        while gate.queued == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let snapshot = queue.snapshot(gate: gate, now: .now.advanced(by: .seconds(3)))
        XCTAssertEqual(snapshot.waiting, 1)
        XCTAssertEqual(snapshot.depth, 1)
        XCTAssertGreaterThanOrEqual(snapshot.oldestAge, .seconds(3))
        release.continuation.yield()
        try await holder.value
        try await waiter.value
        XCTAssertEqual(queue.snapshot(gate: gate).waiting, 0)
    }
}
