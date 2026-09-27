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

    /// One start of `id` through `gate`: records `b:<id>` / `s:<id>` as the
    /// runtime calls begin and then runs the given step. With `probe`, also
    /// records `e:<id>` once startProcess has returned, and counts the start
    /// as in flight from bootstrap's entry to startProcess's return.
    private static func start(
        _ id: String,
        gate: StartGate,
        order: Order,
        probe: InFlight? = nil,
        listed: @escaping @Sendable () -> Bool = { true },
        bootstrap: @escaping @Sendable () async throws -> Void = {},
        startProcess: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        try await NativeContainerService.startLookingIntoNotFound(
            id: id, createdHere: true, backoff: noWait, gate: gate,
            bootstrap: {
                probe?.enter()
                await order.append("b:\(id)")
                try await bootstrap()
            },
            startProcess: {
                await order.append("s:\(id)")
                try await startProcess()
                if let probe {
                    await order.append("e:\(id)")
                    probe.leave()
                }
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
    /// bootstrap is followed by its own startProcess, which returns before the
    /// next start's bootstrap begins — b s e b s e …, never b b b b s s s s,
    /// and never a bootstrap alongside another start's startProcess.
    func testConcurrentStartsAlternateBootstrapAndStartProcess() async throws {
        let gate = StartGate()
        let order = Order()
        let probe = InFlight()
        let ids = ["c0", "c1", "c2", "c3"]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    try await StartGateTests.start(
                        id, gate: gate, order: order, probe: probe,
                        bootstrap: { try await Task.sleep(for: .milliseconds(40)) },
                        startProcess: { try await Task.sleep(for: .milliseconds(20)) })
                }
            }
            try await group.waitForAll()
        }

        let events = await order.events
        XCTAssertEqual(probe.maximum, 1, "one start at a time, bootstrap through startProcess: \(events)")
        XCTAssertEqual(
            events.map { $0.prefix(1) }, Array(repeating: ["b", "s", "e"], count: 4).flatMap { $0 }, "\(events)")
        for triple in stride(from: 0, to: events.count - 2, by: 3) {
            let id = events[triple].dropFirst(2)
            XCTAssertEqual(
                events[triple + 1].dropFirst(2), id, "a bootstrap is followed by its own startProcess: \(events)")
            XCTAssertEqual(events[triple + 2].dropFirst(2), id, "that startProcess returns next: \(events)")
        }
        XCTAssertEqual(Set(events.map { String($0.dropFirst(2)) }), Set(ids))
        XCTAssertFalse(gate.isHeld)
    }

    /// Waiters run in the order they queued, and the gate handed to a waiter
    /// stays held: a start arriving while the woken waiter runs queues behind
    /// the others instead of running alongside it.
    func testWaitersRunInArrivalOrderAndANewcomerQueuesBehindThem() async throws {
        let gate = StartGate()
        let order = Order()
        let probe = InFlight()
        let holderMayFinish = Latch()
        let firstWaiterMayFinish = Latch()

        let holder = Task {
            try await StartGateTests.start(
                "a", gate: gate, order: order, probe: probe, bootstrap: { await holderMayFinish.wait() })
        }
        try await waitUntil("a holds the gate") { await order.events == ["b:a"] }
        var waiters: [Task<Void, any Error>] = []
        for (index, id) in ["c1", "c2", "c3"].enumerated() {
            waiters.append(
                Task {
                    try await StartGateTests.start(
                        id, gate: gate, order: order, probe: probe,
                        bootstrap: { if id == "c1" { await firstWaiterMayFinish.wait() } })
                })
            try await waitUntil("\(id) waits") { gate.queued == index + 1 }
        }

        await holderMayFinish.open()
        try await holder.value
        try await waitUntil("the gate passed to a waiter") { await order.events.count >= 4 }
        let handedTo = await order.events[3]
        XCTAssertEqual(handedTo, "b:c1", "the longest waiter is served first")
        let queuedBefore = gate.queued
        let newcomer = Task {
            try await StartGateTests.start("n", gate: gate, order: order, probe: probe)
        }
        try await waitUntil("n arrived") {
            let ranAlongside = await order.events.contains("b:n")
            return gate.queued == queuedBefore + 1 || ranAlongside
        }
        XCTAssertEqual(gate.queued, 3, "n queues behind c2 and c3 while c1 holds the handed-over gate")
        XCTAssertTrue(gate.isHeld)

        await firstWaiterMayFinish.open()
        for waiter in waiters { try await waiter.value }
        try await newcomer.value
        let events = await order.events
        XCTAssertEqual(
            events,
            ["a", "c1", "c2", "c3", "n"].flatMap { ["b:\($0)", "s:\($0)", "e:\($0)"] })
        XCTAssertEqual(probe.maximum, 1, "\(events)")
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

/// Counts the starts between bootstrap's entry and startProcess's return,
/// and the most there ever were at once.
private final class InFlight: Sendable {
    private let counts = Mutex((current: 0, maximum: 0))

    func enter() {
        counts.withLock { counts in
            counts.current += 1
            counts.maximum = max(counts.maximum, counts.current)
        }
    }

    func leave() { counts.withLock { $0.current -= 1 } }

    var maximum: Int { counts.withLock { $0.maximum } }
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
