import Foundation
import MicropodCore
import Synchronization
import XCTest

@testable import MicropodRuntime

/// O1: container-apiserver runs every container operation under one FIFO
/// lock and a start takes it twice (bootstrap, then startProcess), so N
/// concurrent starts queued as R R R R S S S S and all finished together.
/// Each start attempt now holds the process-wide `StartGate` across
/// bootstrap → exit-code track → startProcess, so the runtime sees
/// R S R S R S R S.
///
/// Driven through `startLookingIntoNotFound` as `startTracked` wires it,
/// against scripted bootstrap/startProcess calls that record their order.
final class StartGateTests: XCTestCase {

    private static let noWait: [Duration] = [.zero, .zero, .zero]
    private static let invalidState = MicropodError.message("invalidState: container is stopping")

    /// One start of `id` through `gate`: records `b:<id>` / `s:<id>` and then
    /// runs the given step.
    private static func start(
        _ id: String,
        gate: StartGate,
        order: Order,
        listed: @escaping @Sendable () -> Bool = { true },
        bootstrap: @escaping @Sendable () async throws -> Void = {},
        startProcess: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        try await NativeContainerService.startLookingIntoNotFound(
            id: id, createdHere: true, backoff: noWait, gate: gate,
            bootstrap: {
                await order.append("b:\(id)")
                try await bootstrap()
            },
            startProcess: {
                await order.append("s:\(id)")
                try await startProcess()
            },
            exists: { listed() },
            log: { _ in })
    }

    /// Polls `condition` until it holds; fails (instead of hanging) after
    /// `timeout`.
    private func waitUntil(
        _ what: String, timeout: Duration = .seconds(10), _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting until \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: ordering

    /// Four concurrent starts against a runtime whose bootstrap is slow: every
    /// bootstrap is followed by its own startProcess before the next start's
    /// bootstrap — b s b s b s b s, never b b b b s s s s.
    func testConcurrentStartsAlternateBootstrapAndStartProcess() async throws {
        let gate = StartGate()
        let order = Order()
        let ids = ["c0", "c1", "c2", "c3"]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    try await StartGateTests.start(
                        id, gate: gate, order: order,
                        bootstrap: { try await Task.sleep(for: .milliseconds(40)) },
                        startProcess: { try await Task.sleep(for: .milliseconds(5)) })
                }
            }
            try await group.waitForAll()
        }

        let events = await order.events
        XCTAssertEqual(events.map { $0.prefix(1) }, ["b", "s", "b", "s", "b", "s", "b", "s"], "\(events)")
        for pair in stride(from: 0, to: events.count - 1, by: 2) {
            XCTAssertEqual(
                events[pair].dropFirst(2), events[pair + 1].dropFirst(2),
                "a bootstrap is followed by its own startProcess: \(events)")
        }
        XCTAssertEqual(Set(events.map { String($0.dropFirst(2)) }), Set(ids))
        XCTAssertFalse(gate.isHeld)
    }

    // MARK: cancellation

    /// A start cancelled while it waits leaves the queue at once — while the
    /// holder still holds the gate — and the start behind it runs next.
    func testACancelledWaiterLeavesTheQueueWithoutBlockingOthers() async throws {
        let gate = StartGate()
        let order = Order()
        let holderMayFinish = Latch()

        let holder = Task {
            try await StartGateTests.start("a", gate: gate, order: order, bootstrap: { await holderMayFinish.wait() })
        }
        try await waitUntil("a holds the gate") { await order.events == ["b:a"] }
        let cancelled = Task { try await StartGateTests.start("b", gate: gate, order: order) }
        try await waitUntil("b waits") { gate.queued == 1 }
        let behind = Task { try await StartGateTests.start("c", gate: gate, order: order) }
        try await waitUntil("c waits") { gate.queued == 2 }

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("a start cancelled while it waits must not run")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(gate.queued, 1, "the cancelled start left the queue while a still held the gate")

        await holderMayFinish.open()
        try await holder.value
        try await behind.value
        let events = await order.events
        XCTAssertEqual(events, ["b:a", "s:a", "b:c", "s:c"])
        XCTAssertFalse(gate.isHeld)
    }

    /// A start whose task is already cancelled never calls the runtime and
    /// leaves the gate free.
    func testAnAlreadyCancelledStartCallsNothing() async throws {
        let gate = StartGate()
        let order = Order()

        let start = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await StartGateTests.start("a", gate: gate, order: order)
        }
        do {
            try await start.value
            XCTFail("a cancelled start must not run")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let events = await order.events
        XCTAssertEqual(events, [])
        XCTAssertFalse(gate.isHeld)
    }

    // MARK: release

    /// A start that fails — in bootstrap or in startProcess — releases the
    /// gate, and the start waiting behind it runs.
    func testAFailedStartReleasesTheGate() async throws {
        for failing in ["bootstrap", "startProcess"] {
            let gate = StartGate()
            let order = Order()
            let holderMayFinish = Latch()

            let failed = Task {
                try await StartGateTests.start(
                    "a", gate: gate, order: order,
                    bootstrap: {
                        await holderMayFinish.wait()
                        if failing == "bootstrap" { throw StartGateTests.invalidState }
                    },
                    startProcess: { if failing == "startProcess" { throw StartGateTests.invalidState } })
            }
            try await waitUntil("\(failing): a holds the gate") { await order.events == ["b:a"] }
            let behind = Task { try await StartGateTests.start("b", gate: gate, order: order) }
            try await waitUntil("\(failing): b waits") { gate.queued == 1 }

            await holderMayFinish.open()
            do {
                try await failed.value
                XCTFail("\(failing): expected the error")
            } catch {
                XCTAssertEqual(error.localizedDescription, Self.invalidState.localizedDescription, failing)
            }
            let expected = failing == "bootstrap" ? ["b:a", "b:b", "s:b"] : ["b:a", "s:a", "b:b", "s:b"]
            do {
                try await waitUntil("\(failing): b ran after a failed") { await order.events == expected }
            } catch {
                behind.cancel()
                throw error
            }
            try await behind.value
            XCTAssertFalse(gate.isHeld, failing)
        }
    }

    /// The gate is held per attempt: a start whose bootstrap answered
    /// notFound while the runtime still lists the container releases it for
    /// the lookup and the backoff, so the start waiting behind it goes first.
    func testANotFoundRetryReleasesTheGateBetweenAttempts() async throws {
        let gate = StartGate()
        let order = Order()
        let holderMayFinish = Latch()
        let firstBootstrap = Flag()

        let retried = Task {
            try await StartGateTests.start(
                "a", gate: gate, order: order,
                bootstrap: {
                    guard firstBootstrap.take() else { return }
                    await holderMayFinish.wait()
                    throw MicropodError.message("notFound: container with ID a not found")
                })
        }
        try await waitUntil("a holds the gate") { await order.events == ["b:a"] }
        let behind = Task { try await StartGateTests.start("b", gate: gate, order: order) }
        try await waitUntil("b waits") { gate.queued == 1 }

        await holderMayFinish.open()
        try await retried.value
        try await behind.value
        let events = await order.events
        XCTAssertEqual(events, ["b:a", "b:b", "s:b", "b:a", "s:a"])
        XCTAssertFalse(gate.isHeld)
    }
}

/// The order the scripted runtime was called in.
private actor Order {
    private(set) var events: [String] = []

    func append(_ event: String) { events.append(event) }
}

/// Opens once; `wait` returns when it is open.
private actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }
}

/// True for the first `take` only.
private final class Flag: Sendable {
    private let taken = Mutex(false)

    func take() -> Bool {
        taken.withLock { taken in
            defer { taken = true }
            return !taken
        }
    }
}
