import Foundation
import Sparkle
import XCTest

@testable import MicropodApp

@MainActor
final class UpdateRestartGuardTests: XCTestCase {
    func testProductionDefaultBlocksManualApplyWithoutObservingOrInstalling() async {
        let controller = UpdateController(feedConfigured: false)
        var observations = 0
        var installs = 0
        controller.restartIsSafe = {
            observations += 1
            return true
        }
        controller.stageUpdate(version: "test-version", handler: { installs += 1 })
        let applied = await controller.applyStagedUpdate()
        XCTAssertFalse(applied)
        XCTAssertEqual(controller.status, .readyToInstall)
        XCTAssertTrue(controller.readyToInstall)
        XCTAssertEqual(controller.statusReport["restartGuard"] as? String, "unavailable")
        XCTAssertEqual(controller.statusReport["restartBlockedReason"] as? String, UpdateRestartGuard.unavailableReason)
        XCTAssertEqual(observations, 0)
        XCTAssertEqual(installs, 0)
    }

    func testEveryInstallationCapableSparkleDriverIsDenied() throws {
        XCTAssertThrowsError(try UpdateController.requireInformationCheck(.updates))
        XCTAssertThrowsError(try UpdateController.requireInformationCheck(.updatesInBackground))
        XCTAssertNoThrow(try UpdateController.requireInformationCheck(.updateInformation))
        let controller = UpdateController(feedConfigured: false)
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("updater:mayPerformUpdateCheck:error:")))
    }

    func testAtomicMockHoldSpansObservationResponseFlushAndInstall() async throws {
        let fixture = Fixture()
        let flush = Pause()
        let guarder = fixture.guarder(flush: flush)
        var installs = 0
        let accepted = await guarder.requestInstallation(
            noObservedWork: {
                XCTAssertFalse(fixture.canAdmitJob)
                return true
            },
            install: {
                XCTAssertFalse(fixture.canAdmitJob)
                XCTAssertEqual(fixture.lease.begins, 1)
                installs += 1
            })
        XCTAssertTrue(accepted)
        try await waitUntil { flush.waiting }
        XCTAssertFalse(fixture.canAdmitJob)
        XCTAssertEqual(installs, 0)
        flush.resume()
        try await waitUntil { installs == 1 }
        XCTAssertEqual(guarder.state, .installationStarted)
        XCTAssertEqual(fixture.lease.aborts, 0)
        XCTAssertFalse(fixture.canAdmitJob)
    }

    func testConcurrentApplyRequestsOnlyAcquireOnce() async throws {
        let fixture = Fixture()
        fixture.delayAcquire = true
        let guarder = fixture.guarder()
        let first = Task { await guarder.requestInstallation(noObservedWork: { false }, install: { XCTFail() }) }
        try await waitUntil { fixture.acquireReply != nil }
        let duplicate = await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() })
        XCTAssertFalse(duplicate)
        XCTAssertEqual(fixture.acquires, 1)
        fixture.deliverAcquire()
        let accepted = await first.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.lease.aborts, 1)
    }

    func testBusyOrUnknownAPIObservationAbortsBeforeAction() async {
        let fixture = Fixture()
        let guarder = fixture.guarder()
        let accepted = await guarder.requestInstallation(noObservedWork: { false }, install: { XCTFail() })
        XCTAssertFalse(accepted)
        XCTAssertEqual(guarder.state, .blocked)
        XCTAssertEqual(fixture.lease.begins, 0)
        XCTAssertEqual(fixture.lease.aborts, 1)
        XCTAssertTrue(fixture.canAdmitJob)
    }

    func testAcquireFailureNeverStartsInstall() async {
        let fixture = Fixture()
        fixture.failAcquire = true
        let guarder = fixture.guarder()
        let accepted = await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() })
        XCTAssertFalse(accepted)
        XCTAssertEqual(guarder.state, .blocked)
        XCTAssertEqual(fixture.lease.begins, 0)
        XCTAssertEqual(fixture.cancelled.count, 1)
    }

    func testCancelledAcquireFencesLateGrantWithoutClearingNewGeneration() async throws {
        let fixture = Fixture()
        fixture.delayAcquire = true
        let guarder = fixture.guarder()
        let first = Task { await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() }) }
        try await waitUntil { fixture.acquireReply != nil }
        first.cancel()
        let accepted = await first.value
        XCTAssertFalse(accepted)
        let oldLease = fixture.lease
        fixture.lease = Lease()
        fixture.delayAcquire = false
        let second = await guarder.requestInstallation(noObservedWork: { true }, install: {})
        XCTAssertTrue(second)
        fixture.deliverAcquire(lease: oldLease)
        try await waitUntil { oldLease.aborts == 1 }
        XCTAssertEqual(oldLease.begins, 0)
        XCTAssertTrue(fixture.lease.closed)
        XCTAssertEqual(fixture.lease.aborts, 0)
    }

    func testTimeoutReturnsWhenAcquireIgnoresCancellationAndAllowsDefiniteRecovery() async throws {
        let fixture = Fixture()
        fixture.delayAcquire = true
        let timeout = Pause()
        let guarder = fixture.guarder(timeout: timeout)
        let first = Task { await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() }) }
        try await waitUntil { fixture.acquireReply != nil && timeout.waiting }
        timeout.resume()
        let accepted = await first.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(guarder.state, .blocked)
        fixture.deliverAcquire()
        try await waitUntil { fixture.lease.aborts == 1 }
        fixture.delayAcquire = false
        fixture.lease = Lease()
        let recovered = await guarder.requestInstallation(noObservedWork: { false }, install: { XCTFail() })
        XCTAssertFalse(recovered)
        XCTAssertEqual(fixture.acquires, 2)
        XCTAssertTrue(fixture.canAdmitJob)
    }

    func testInterruptedBeforeBeginAbortsAndCannotFireDelayedHandler() async throws {
        let fixture = Fixture()
        let flush = Pause()
        let guarder = fixture.guarder(flush: flush)
        let accepted = await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() })
        XCTAssertTrue(accepted)
        try await waitUntil { flush.waiting }
        guarder.interrupted(reason: "Sparkle cancelled")
        flush.resume()
        await Task.yield()
        XCTAssertEqual(guarder.state, .blocked)
        XCTAssertEqual(fixture.lease.begins, 0)
        XCTAssertEqual(fixture.lease.aborts, 1)
    }

    func testGrantExpiryDuringResponseFlushDeniesBeginWithoutInstalling() async throws {
        let fixture = Fixture()
        let flush = Pause()
        let guarder = fixture.guarder(flush: flush)
        let accepted = await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() })
        XCTAssertTrue(accepted)
        try await waitUntil { flush.waiting }
        fixture.lease.beginAllowed = false
        flush.resume()
        try await waitUntil { guarder.state == .blocked }
        XCTAssertEqual(fixture.lease.aborts, 1)
        XCTAssertTrue(fixture.canAdmitJob)
    }

    func testTimeoutDuringResponseFlushCannotInvokeDelayedInstaller() async throws {
        let fixture = Fixture()
        let flush = Pause()
        let timeout = Pause()
        let guarder = fixture.guarder(flush: flush, timeout: timeout)
        let accepted = await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() })
        XCTAssertTrue(accepted)
        try await waitUntil { flush.waiting && timeout.waiting }
        timeout.resume()
        try await waitUntil { guarder.state == .blocked }
        flush.resume()
        await Task.yield()
        XCTAssertEqual(fixture.lease.begins, 0)
        XCTAssertEqual(fixture.lease.aborts, 1)
    }

    func testControllerShowsUnknownBeginAsRecoveryFailure() async throws {
        let fixture = Fixture()
        fixture.lease.beginUnknown = true
        let guarder = fixture.guarder()
        let controller = UpdateController(feedConfigured: false, restartGuard: guarder)
        controller.restartIsSafe = { true }
        controller.stageUpdate(version: "test-version", handler: { XCTFail("Unsafe install handler") })
        _ = await controller.applyStagedUpdate()
        try await waitUntil { guarder.state == .recoveryRequired }
        XCTAssertEqual(controller.status, .error)
        XCTAssertEqual(controller.statusReport["restartGuard"] as? String, "recoveryRequired")
        XCTAssertNotNil(controller.restartBlockedReason)
        XCTAssertEqual(fixture.lease.aborts, 0)
    }

    func testUnknownBeginOutcomeRetainsFenceUntilVerifiedRollback() async throws {
        let fixture = Fixture()
        fixture.lease.beginUnknown = true
        let guarder = fixture.guarder()
        let accepted = await guarder.requestInstallation(noObservedWork: { true }, install: { XCTFail() })
        XCTAssertTrue(accepted)
        try await waitUntil { guarder.state == .recoveryRequired }
        XCTAssertEqual(fixture.lease.aborts, 0)
        XCTAssertFalse(fixture.canAdmitJob)
        let unknown = await guarder.reconcileRecovery()
        XCTAssertFalse(unknown)
        XCTAssertFalse(fixture.canAdmitJob)
        fixture.lease.restored = true
        let recovered = await guarder.reconcileRecovery()
        XCTAssertTrue(recovered)
        XCTAssertEqual(guarder.state, .idle)
        XCTAssertTrue(fixture.canAdmitJob)
    }

    func testInterruptedAfterBeginDoesNotReleaseOrRepeatApply() async throws {
        let fixture = Fixture()
        let guarder = fixture.guarder()
        var installs = 0
        let accepted = await guarder.requestInstallation(noObservedWork: { true }, install: { installs += 1 })
        XCTAssertTrue(accepted)
        try await waitUntil { installs == 1 }
        guarder.interrupted(reason: "installer response lost")
        let duplicate = await guarder.requestInstallation(noObservedWork: { true }, install: { installs += 1 })
        XCTAssertFalse(duplicate)
        XCTAssertEqual(guarder.state, .recoveryRequired)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(fixture.lease.aborts, 0)
        XCTAssertFalse(fixture.canAdmitJob)
    }
}

@MainActor
private final class Fixture: UpdateAdmissionCoordinating {
    let isAvailable = true
    var lease = Lease()
    var acquires = 0
    var cancelled: [UUID] = []
    var delayAcquire = false
    var failAcquire = false
    var acquireReply: CheckedContinuation<any UpdateAdmissionHolding, any Error>?
    var canAdmitJob: Bool { !lease.closed }

    func acquire(operation: UUID) async throws -> any UpdateAdmissionHolding {
        acquires += 1
        if failAcquire { throw URLError(.cannotConnectToHost) }
        lease.closed = true
        if delayAcquire { return try await withCheckedThrowingContinuation { acquireReply = $0 } }
        return lease
    }

    func deliverAcquire(lease supplied: Lease? = nil) {
        let reply = acquireReply
        acquireReply = nil
        reply?.resume(returning: supplied ?? lease)
    }

    func cancelAcquisition(operation: UUID) { cancelled.append(operation) }

    func guarder(flush: Pause? = nil, timeout: Pause? = nil) -> UpdateRestartGuard {
        UpdateRestartGuard(
            coordinator: self,
            waitForTimeout: {
                if let timeout { await timeout.wait() } else { try await Task.sleep(for: .seconds(10)) }
            },
            waitForResponseFlush: { if let flush { await flush.wait() } })
    }
}

@MainActor
private final class Lease: UpdateAdmissionHolding {
    var closed = false
    var begins = 0
    var aborts = 0
    var beginAllowed = true
    var beginUnknown = false
    var restored = false
    func beginInstallation() throws -> Bool {
        begins += 1
        if beginUnknown { throw URLError(.networkConnectionLost) }
        return beginAllowed
    }
    func abortIfInstallationHasNotBegun() {
        aborts += 1
        closed = false
    }
    func oldRuntimeIsVerifiedRestored() async throws -> Bool {
        if restored { closed = false }
        return restored
    }
}

@MainActor
private final class Pause {
    private var reply: CheckedContinuation<Void, Never>?
    var waiting: Bool { reply != nil }
    func wait() async { await withCheckedContinuation { reply = $0 } }
    func resume() {
        let pending = reply
        reply = nil
        pending?.resume()
    }
}
