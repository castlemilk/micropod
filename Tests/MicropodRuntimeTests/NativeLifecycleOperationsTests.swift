import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

final class NativeLifecycleOperationsTests: XCTestCase {
    func testQueuedNewStartCannotReportPreviousRunsExit() async throws {
        let claims = ContainerLifecycleClaims()
        let operations = NativeLifecycleOperations(claims: claims)
        let exits = ExitCodeRegistry()
        await exits.track(id: "reused") { 0 }
        _ = await exits.await(id: "reused", timeout: .seconds(2))
        let queued = LifecycleLatch(), release = LifecycleLatch()
        let start = Task {
            try await operations.perform("reused", kind: .starting) { claim in
                await queued.open()
                await release.wait()
                await exits.forget(id: "reused")
                try await operations.dispatch(claim)
            }
        }
        await queued.wait()
        let outcome = try await ContainerExitWait.wait(
            id: "reused", timeout: .zero, exitCodes: exits,
            observationRevision: { await claims.revision() },
            acceptExitCode: { await operations.acceptsExitCode($0) },
            state: { _, exitKnown in
                XCTAssertFalse(exitKnown, "old code must not suppress the pending-state fallback for an absent row")
                return exitKnown ? "unknown" : "starting"
            })
        XCTAssertFalse(outcome.exited)
        XCTAssertFalse(outcome.known)
        XCTAssertNil(outcome.exitCode)
        await release.open()
        try await start.value
    }

    func testQueuedCancellationNeverDispatchesAndReleasesClaim() async throws {
        let claims = ContainerLifecycleClaims()
        let operations = NativeLifecycleOperations(claims: claims)
        let gate = StartGate()
        let holding = LifecycleLatch(), releaseHolder = LifecycleLatch(), queued = LifecycleLatch()
        let calls = LifecycleCounter()
        let holder = Task {
            try await gate.withExclusive {
                await holding.open()
                await releaseHolder.wait()
            }
        }
        await holding.wait()
        let caller = Task {
            try await operations.perform("queued", kind: .starting) { claim in
                await queued.open()
                try await gate.withExclusive {
                    try await operations.dispatch(claim)
                    await calls.increment()
                }
            }
        }
        await queued.wait()
        caller.cancel()
        do {
            try await caller.value
            XCTFail("queued cancellation must fail")
        } catch is CancellationError {}
        let dispatched = await calls.value
        let kind = await claims.kind(of: "queued")
        XCTAssertEqual(dispatched, 0)
        XCTAssertNil(kind)
        await releaseHolder.open()
        try await holder.value
    }

    func testDispatchedWorkKeepsOwnershipAfterCallerCancellation() async throws {
        let claims = ContainerLifecycleClaims()
        let operations = NativeLifecycleOperations(claims: claims)
        let dispatched = LifecycleLatch(), finish = LifecycleLatch()
        let caller = Task {
            try await operations.perform("started", kind: .starting) { claim in
                try await operations.dispatch(claim)
                await dispatched.open()
                await finish.wait()
                XCTAssertFalse(Task.isCancelled, "caller cancellation must not cancel dispatched XPC ownership")
            }
        }
        await dispatched.wait()
        caller.cancel()
        do {
            try await operations.perform("started", kind: .deleting) { _ in XCTFail("delete dispatched early") }
            XCTFail("pending start must block deletion")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
        }
        let pending = await claims.kind(of: "started")
        XCTAssertEqual(pending, .starting)
        await finish.open()
        try await caller.value
        let settled = await claims.kind(of: "started")
        XCTAssertNil(settled)
        try await operations.perform("started", kind: .deleting) { claim in
            try await operations.dispatch(claim)
        }
    }

    func testDispatchedTransportLossDoesNotAuthorizeDelete() async throws {
        let claims = ContainerLifecycleClaims()
        let operations = NativeLifecycleOperations(claims: claims)
        do {
            try await operations.perform("unknown", kind: .starting) { claim in
                try await operations.dispatch(claim)
                throw MicropodError.transport("reply lost")
            }
            XCTFail("expected lost reply")
        } catch {}
        let kind = await claims.kind(of: "unknown")
        XCTAssertEqual(kind, .starting)
        do {
            try await operations.perform("unknown", kind: .deleting) { _ in XCTFail("unsafe deletion") }
            XCTFail("unsettled operation must remain protected")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
        }
    }

    func testDefinitiveStartFailureReleasesClaim() async throws {
        let claims = ContainerLifecycleClaims()
        let operations = NativeLifecycleOperations(claims: claims)
        do {
            try await operations.perform("refused", kind: .starting) { claim in
                try await operations.dispatch(claim)
                throw MicropodError.message("notFound: container absent")
            }
            XCTFail("expected refusal")
        } catch {}
        let kind = await claims.kind(of: "refused")
        XCTAssertNil(kind)
    }

    func testRetainedStartReconcilesOnlyFromItsActualExitWaiter() async throws {
        let claims = ContainerLifecycleClaims()
        let operations = NativeLifecycleOperations(claims: claims)
        let exits = ExitCodeRegistry()
        let actualExit = LifecycleLatch()
        do {
            try await operations.perform(
                "lost-reply", kind: .starting,
                knownExit: { await exits.entry(for: "lost-reply")?.exitCode != nil },
                operation: { claim in
                    try await operations.dispatch(claim)
                    await exits.track(id: "lost-reply") {
                        await actualExit.wait()
                        return 7
                    }
                    throw MicropodError.transport("startProcess reply lost")
                })
        } catch {}
        await operations.reconcileKnownExit("lost-reply")
        let beforeExit = await claims.kind(of: "lost-reply")
        XCTAssertEqual(beforeExit, .starting, "no exit yet; a stopped snapshot would not release ownership")
        await actualExit.open()
        let observed = await exits.await(id: "lost-reply", timeout: .seconds(2))
        XCTAssertEqual(observed?.exitCode, 7)
        await operations.reconcileKnownExit("lost-reply")
        let afterExit = await claims.kind(of: "lost-reply")
        XCTAssertNil(afterExit)
        try await operations.perform("lost-reply", kind: .deleting) { claim in
            try await operations.dispatch(claim)
        }
    }

    func testUnknownExitNeverReconcilesRetainedStart() async throws {
        let claims = ContainerLifecycleClaims()
        let operations = NativeLifecycleOperations(claims: claims)
        let exits = ExitCodeRegistry()
        do {
            try await operations.perform(
                "unknown-exit", kind: .starting,
                knownExit: { await exits.entry(for: "unknown-exit")?.exitCode != nil },
                operation: { claim in
                    try await operations.dispatch(claim)
                    await exits.track(id: "unknown-exit") { throw MicropodError.transport("wait reply lost") }
                    throw MicropodError.transport("start reply lost")
                })
        } catch {}
        _ = await exits.await(id: "unknown-exit", timeout: .seconds(2))
        await operations.reconcileKnownExit("unknown-exit")
        let retained = await claims.kind(of: "unknown-exit")
        XCTAssertEqual(retained, .starting)
    }
}

private actor LifecycleLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor LifecycleCounter {
    var value = 0
    func increment() { value += 1 }
}
