import Foundation
import Sparkle
import XCTest

@testable import MicropodApp

@MainActor
final class UpdateRestartGuardTests: XCTestCase {
    func testGuardedDownloadsRemainAvailableWithSparklesSchedulerDisabled() throws {
        for explicitPermission in [false, true] {
            let identifier = "test.micropod.download-permission." + UUID().uuidString
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier + ".app")
            defer {
                UserDefaults.standard.removePersistentDomain(forName: identifier)
                try? FileManager.default.removeItem(at: root)
            }
            let contents = root.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var metadata: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleName": "Update Settings Test",
                "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
                "SUEnableAutomaticChecks": true,
            ]
            if explicitPermission { metadata["SUAllowsAutomaticUpdates"] = true }
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: root))
            let updater = SPUUpdater(
                hostBundle: bundle, applicationBundle: bundle,
                userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
            // Do not start the updater: this exercises Sparkle's actual settings
            // without any network check, download or installer interaction.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = true
            XCTAssertFalse(updater.automaticallyChecksForUpdates)
            XCTAssertEqual(updater.allowsAutomaticUpdates, explicitPermission)
            XCTAssertEqual(updater.automaticallyDownloadsUpdates, explicitPermission)
        }
    }

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

    func testUnqualifiedProductionDriversAreDeniedAtTheActualDelegateBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-driver-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UpdateController(feedConfigured: false, store: .init(root: root))
        let updater = controller.controller.updater
        XCTAssertThrowsError(try controller.updater(updater, mayPerform: .updates))
        XCTAssertThrowsError(try controller.updater(updater, mayPerform: .updatesInBackground))
        XCTAssertNoThrow(try controller.updater(updater, mayPerform: .updateInformation))
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

    func testUpdaterPolicyAdmitsFloorsAtOrAboveItsOwnThatTheAppMeets() {
        let policy = UpdaterPolicy(minimumUpdateVersion: "0.13.6", workloadProtocol: 1)
        func admits(_ floor: String?, app: String?) -> Bool {
            policy.admits(itemMinimumUpdateVersion: floor, itemWorkloadProtocol: "1", appVersion: app)
        }
        XCTAssertTrue(admits("0.13.6", app: "0.13.6"))
        XCTAssertTrue(admits("0.13.6", app: "0.13.9"))
        // A later policy's higher floor must not strand an app that meets it.
        XCTAssertTrue(admits("0.14.0", app: "0.14.2"))
        // Components compare numerically, not as strings.
        XCTAssertTrue(admits("0.13.10", app: "0.13.10"))
        XCTAssertTrue(admits("1.0.0", app: "1.0.0"))
        // A floor below ours would also admit known-broken updaters.
        XCTAssertFalse(admits("0.13.5", app: "0.13.9"))
        XCTAssertFalse(admits("0.13.3", app: "0.13.9"))
        XCTAssertFalse(admits("0.9.99", app: "0.13.9"))
        // The running app must itself meet the item's floor.
        XCTAssertFalse(admits("0.14.0", app: "0.13.9"))
    }

    func testUpdaterPolicyRejectsMalformedVersions() {
        let policy = UpdaterPolicy(minimumUpdateVersion: "0.13.6", workloadProtocol: 1)
        // Leading zeros are refused: released apps compare the floor as a string.
        for floor in [
            nil, "", "0.13", "0.13.6.1", "v0.13.6", "0.13.x", " 0.13.6", "0.13.6-beta", "0..13", "١.١٣.٦",
            "0.013.6", "00.13.6", "0.13.06",
        ] {
            XCTAssertFalse(
                policy.admits(itemMinimumUpdateVersion: floor, itemWorkloadProtocol: "1", appVersion: "0.13.9"),
                "floor \(floor ?? "nil")")
        }
        for app in [nil, "", "?", "dev", "0.13", "0.013.9"] {
            XCTAssertFalse(
                policy.admits(itemMinimumUpdateVersion: "0.13.6", itemWorkloadProtocol: "1", appVersion: app),
                "app \(app ?? "nil")")
        }
        let malformed = UpdaterPolicy(minimumUpdateVersion: "latest", workloadProtocol: 1)
        XCTAssertFalse(
            malformed.admits(itemMinimumUpdateVersion: "0.13.6", itemWorkloadProtocol: "1", appVersion: "0.13.9"))
    }

    func testUpdaterPolicyRequiresTheRetainedWorkloadProtocol() {
        let policy = UpdaterPolicy(minimumUpdateVersion: "0.13.6", workloadProtocol: 1)
        XCTAssertTrue(
            policy.admits(itemMinimumUpdateVersion: "0.13.6", itemWorkloadProtocol: "1", appVersion: "0.13.9"))
        // Items published before the attribute existed carry no protocol.
        for workload in [nil, "", "2", "0", "01", " 1", "one"] {
            XCTAssertFalse(
                policy.admits(itemMinimumUpdateVersion: "0.13.6", itemWorkloadProtocol: workload, appVersion: "0.13.9"),
                "protocol \(workload ?? "nil")")
        }
        let next = UpdaterPolicy(minimumUpdateVersion: "0.13.6", workloadProtocol: 2)
        XCTAssertTrue(next.admits(itemMinimumUpdateVersion: "0.13.6", itemWorkloadProtocol: "2", appVersion: "0.13.9"))
        XCTAssertFalse(next.admits(itemMinimumUpdateVersion: "0.13.6", itemWorkloadProtocol: "1", appVersion: "0.13.9"))
    }

    func testPackagedUpdaterPolicyFallsBackOnlyForAbsentKeys() {
        XCTAssertEqual(UpdaterPolicy.packaged(nil), .fallback)
        XCTAssertEqual(UpdaterPolicy.packaged([:]), .fallback)
        XCTAssertEqual(
            UpdaterPolicy.packaged([
                UpdaterPolicy.minimumUpdateVersionKey: "0.14.0", UpdaterPolicy.workloadProtocolKey: 2,
            ]),
            UpdaterPolicy(minimumUpdateVersion: "0.14.0", workloadProtocol: 2))
        for info: [String: Any] in [
            [UpdaterPolicy.minimumUpdateVersionKey: "0.14"],
            [UpdaterPolicy.minimumUpdateVersionKey: 14],
            [UpdaterPolicy.workloadProtocolKey: "1"],
            [UpdaterPolicy.workloadProtocolKey: 0],
        ] {
            XCTAssertNil(UpdaterPolicy.packaged(info), "\(info)")
        }
    }

    /// The compiled fallback is the same policy the release scripts stamp.
    func testCompiledUpdaterPolicyMatchesTheReleasePolicyFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("release/updater-policy.json")
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(policy["schema"] as? Int, 1)
        XCTAssertEqual(policy["minimumUpdateVersion"] as? String, UpdaterPolicy.fallback.minimumUpdateVersion)
        XCTAssertEqual(policy["workloadProtocol"] as? Int, UpdaterPolicy.fallback.workloadProtocol)
        XCTAssertEqual(policy["workloadProtocol"] as? Int, UpdaterPolicy.implementedWorkloadProtocol)
    }

    func testCanonicalVersionsKeepZeroComponentsAndRefuseLeadingZeros() {
        XCTAssertNotNil(ReleaseVersion("0.0.0"))
        XCTAssertNotNil(ReleaseVersion("1.10.0"))
        for text in ["0.013.6", "01.0.0", "0.0.00"] { XCTAssertNil(ReleaseVersion(text), text) }
        XCTAssertNil(UpdaterPolicy.packaged([UpdaterPolicy.minimumUpdateVersionKey: "0.013.6"]))
    }

    /// Service adoption and replacement verification need the key itself;
    /// the compiled fallback is not a declaration.
    func testOnlyAnExplicitDeclarationOfTheImplementedProtocolCounts() {
        let key = UpdaterPolicy.workloadProtocolKey
        XCTAssertTrue(
            UpdaterPolicy.declaresImplementedWorkloadProtocol([key: UpdaterPolicy.implementedWorkloadProtocol]))
        XCTAssertFalse(UpdaterPolicy.declaresImplementedWorkloadProtocol(nil))
        XCTAssertFalse(UpdaterPolicy.declaresImplementedWorkloadProtocol([:]))
        XCTAssertFalse(
            UpdaterPolicy.declaresImplementedWorkloadProtocol([key: UpdaterPolicy.implementedWorkloadProtocol + 1]))
        XCTAssertFalse(UpdaterPolicy.declaresImplementedWorkloadProtocol([key: "1"]))
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
