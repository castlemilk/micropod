import Foundation
import XCTest

@testable import MicropodCore

final class RigUpgradeEngineTests: XCTestCase {
    func testUpgradeReplacesAppServicesAndConnectAPI() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        let journal = try await fixture.engine.run()
        try fixture.assertUpgraded(journal)
        XCTAssertEqual(journal.drain, .drained)
        XCTAssertEqual(fixture.drain.releases.get(), [journal.operation])
        XCTAssertEqual(
            fixture.health.smokes.get(), ["0.14.0", "0.14.1"], "smoke runs before as a baseline, then after")
        XCTAssertEqual(fixture.app.calls.get(), ["stop", "launch"])
        let calls = fixture.launch.calls.get()
        XCTAssertEqual(calls.filter { $0.hasPrefix("bootout") }.count, 3)
        XCTAssertEqual(calls.filter { $0.hasPrefix("bootstrap") }.count, 3)
        XCTAssertLessThan(
            try XCTUnwrap(calls.lastIndex { $0.hasPrefix("bootout") }),
            try XCTUnwrap(calls.firstIndex { $0.hasPrefix("bootstrap") }))
        // The previously installed Connect API is kept with the operation for rollback.
        let saved = fixture.layout.operationDirectory(journal.operation).appendingPathComponent("previous/MicropodAPI")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "MicropodAPI 0.14.0")
        XCTAssertNil(
            UpdateStateResolver.rig(
                journal: journal, staged: RigStagedRelease.newest(in: fixture.layout), installedVersion: "0.14.1"))
    }

    func testCrashAtEveryCheckpointResumesToCompletion() async throws {
        let dry = try RigFixture()
        try await dry.engine.prepare(dry.staged, options: dry.options)
        try dry.assertUpgraded(try await dry.engine.run())
        var checkpoints: [String] = []
        for name in dry.crash.seen.get() where name != "prepared" && !checkpoints.contains(name) {
            checkpoints.append(name)
        }
        XCTAssertGreaterThan(checkpoints.count, 20, "\(checkpoints)")
        print("rig upgrade crash points (\(checkpoints.count)): \(checkpoints.joined(separator: ", "))")
        for phase in ["draining", "stopping", "swapping", "starting", "verifying", "completing", "completed"] {
            XCTAssertTrue(checkpoints.contains(phase), "no checkpoint after \(phase)")
        }
        for name in checkpoints {
            let fixture = try RigFixture()
            try await fixture.engine.prepare(fixture.staged, options: fixture.options)
            fixture.crash.target.update { $0 = name }
            do {
                _ = try await fixture.engine.run()
                if name != "completed" { XCTFail("\(name): the engine did not stop") }
            } catch let interruption as RigUpgradeInterruption {
                XCTAssertEqual(interruption.checkpoint, name)
            }
            XCTAssertFalse(RigUpgradeStore(layout: fixture.layout).engineIsRunning, "\(name): lock outlived the crash")
            let resumed = try await fixture.engine.run()
            try fixture.assertUpgraded(resumed)
            XCTAssertEqual(
                fixture.drain.releases.get().count, 1, "\(name): drain released \(fixture.drain.releases.get())")
        }
    }

    func testFailedHealthGateRollsBackToThePreviousBytes() async throws {
        let fixture = try RigFixture()
        fixture.health.failVersions.update { $0 = ["0.14.1"] }
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        let journal = try await fixture.engine.run()
        fixture.assertRestored(journal)
        XCTAssertTrue(journal.failure?.hasPrefix("verifying:") == true, journal.failure ?? "")
        XCTAssertTrue(journal.reason?.contains("Rolled back to 0.14.0") == true, journal.reason ?? "")
        XCTAssertEqual(fixture.drain.releases.get(), [journal.operation])
        let state = try XCTUnwrap(
            UpdateStateResolver.rig(
                journal: journal, staged: RigStagedRelease.newest(in: fixture.layout), installedVersion: "0.14.0"))
        XCTAssertEqual(state.kind, .rolledBack)
        XCTAssertEqual(state.targetVersion, "0.14.1")
        XCTAssertEqual(state.operationID, journal.operation.uuidString)
    }

    func testCrashDuringRollbackResumesToTheRestoredRelease() async throws {
        let dry = try RigFixture()
        dry.health.failVersions.update { $0 = ["0.14.1"] }
        try await dry.engine.prepare(dry.staged, options: dry.options)
        dry.assertRestored(try await dry.engine.run())
        var checkpoints: [String] = []
        for name in dry.crash.seen.get() where name.hasPrefix("rollingBack") || name == "rolledBack" {
            if !checkpoints.contains(name) { checkpoints.append(name) }
        }
        XCTAssertTrue(checkpoints.contains("rollingBack:swapped-back"), "\(checkpoints)")
        XCTAssertTrue(checkpoints.contains("rollingBack:restored:MicropodAPI"), "\(checkpoints)")
        for name in checkpoints {
            let fixture = try RigFixture()
            fixture.health.failVersions.update { $0 = ["0.14.1"] }
            try await fixture.engine.prepare(fixture.staged, options: fixture.options)
            fixture.crash.target.update { $0 = name }
            _ = try? await fixture.engine.run()
            XCTAssertEqual(try fixture.journal().phase, name == "rolledBack" ? .rolledBack : .rollingBack, name)
            fixture.assertRestored(try await fixture.engine.run())
        }
    }

    func testTamperedStagedReleaseIsRefusedBeforeDraining() async throws {
        // Tampered before the upgrade is prepared: nothing is recorded.
        let early = try RigFixture()
        let api = early.staged.bundle(in: early.layout).appendingPathComponent("Contents/MacOS/MicropodAPI")
        try Data("MicropodAPI evil".utf8).write(to: api)
        do {
            try await early.engine.prepare(early.staged, options: early.options)
            XCTFail("a tampered bundle was prepared")
        } catch {
            XCTAssertTrue("\(error)".contains("not sealed"), "\(error)")
        }
        XCTAssertNil(try RigUpgradeStore(layout: early.layout).read())
        XCTAssertEqual(early.drain.drains.get(), 0)

        // Tampered after it was prepared: refused before any drain or stop.
        let late = try RigFixture()
        try await late.engine.prepare(late.staged, options: late.options)
        let main = late.staged.bundle(in: late.layout).appendingPathComponent("Contents/MacOS/Micropod")
        try Data("Micropod evil".utf8).write(to: main)
        let journal = try await late.engine.run()
        XCTAssertEqual(journal.phase, .refused)
        XCTAssertTrue(journal.reason?.contains("changed after it was verified") == true, journal.reason ?? "")
        XCTAssertEqual(late.drain.drains.get(), 0)
        XCTAssertEqual(late.app.calls.get(), [])
        XCTAssertEqual(late.launch.calls.get(), [])
        XCTAssertEqual(late.snapshot(), late.originals)
        let state = try XCTUnwrap(UpdateStateResolver.rig(journal: journal, staged: nil, installedVersion: "0.14.0"))
        XCTAssertEqual(state.kind, .blocked)
    }

    func testDrainTimeoutProceedsAndReleases() async throws {
        let fixture = try RigFixture(drain: FakeDrain(drainAfter: nil))
        var options = fixture.options
        options.drainTimeout = 30
        try await fixture.engine.prepare(fixture.staged, options: options)
        let journal = try await fixture.engine.run()
        try fixture.assertUpgraded(journal)
        XCTAssertEqual(journal.drain, .timedOut)
        XCTAssertGreaterThan(fixture.drain.drains.get(), 5)
        XCTAssertTrue(journal.notes.contains { $0.contains("had not drained after 30 s") }, "\(journal.notes)")
        XCTAssertEqual(fixture.drain.releases.get(), [journal.operation])
    }

    func testDrainDeadlineSurvivesAResume() async throws {
        let fixture = try RigFixture(drain: FakeDrain(drainAfter: nil))
        var options = fixture.options
        options.drainTimeout = 30
        try await fixture.engine.prepare(fixture.staged, options: options)
        fixture.crash.target.update { $0 = "draining:poll" }
        _ = try? await fixture.engine.run()
        let polls = fixture.drain.drains.get()
        let resumed = try await fixture.engine.run()
        try fixture.assertUpgraded(resumed)
        // 30 s at one poll per 2 s: the resume does not restart the wait.
        XCTAssertLessThanOrEqual(fixture.drain.drains.get(), 17, "first run polled \(polls)")
    }

    func testUndrainedCoordinatorRefusesBeforeStoppingUnlessForced() async throws {
        for state in [RigDrainReply.State.unavailable, .incompatible, .refused] {
            let refused = try RigFixture(drain: FakeDrain(drainAfter: nil, waiting: state))
            try await refused.engine.prepare(refused.staged, options: refused.options)
            let journal = try await refused.engine.run()
            XCTAssertEqual(journal.phase, .refused, "\(state)")
            XCTAssertEqual(journal.drain?.rawValue, state.rawValue)
            XCTAssertTrue(journal.reason?.contains("--force-undrained") == true, journal.reason ?? "")
            XCTAssertEqual(refused.app.calls.get(), [], "\(state): the app was stopped")
            XCTAssertEqual(refused.launch.calls.get(), [], "\(state): a service was stopped")
            XCTAssertEqual(refused.snapshot(), refused.originals)

            let forced = try RigFixture(drain: FakeDrain(drainAfter: nil, waiting: state))
            var options = forced.options
            options.forceUndrained = true
            try await forced.engine.prepare(forced.staged, options: options)
            let upgraded = try await forced.engine.run()
            try forced.assertUpgraded(upgraded)
            XCTAssertEqual(upgraded.drain?.rawValue, state.rawValue)
            XCTAssertTrue(upgraded.notes.contains { $0.contains("--force-undrained") }, "\(upgraded.notes)")
        }
        // An incompatible coordinator is not polled until the timeout.
        let old = try RigFixture(drain: FakeDrain(drainAfter: nil, waiting: .incompatible))
        try await old.engine.prepare(old.staged, options: old.options)
        _ = try await old.engine.run()
        XCTAssertEqual(old.drain.drains.get(), 1)

        let absent = try RigFixture(drain: FakeDrain(configured: false))
        try await absent.engine.prepare(absent.staged, options: absent.options)
        let second = try await absent.engine.run()
        try absent.assertUpgraded(second)
        XCTAssertEqual(second.drain, .skipped)
        XCTAssertEqual(absent.drain.drains.get(), 0)
        XCTAssertEqual(absent.drain.releases.get(), [])
    }

    func testHeartbeatContinuesAfterAnUnreachableCoordinator() async throws {
        let drain = FakeDrain(drainAfter: nil, waiting: .unavailable)
        let fixture = try RigFixture(drain: drain)
        fixture.heartbeat = .milliseconds(5)
        fixture.app.beforeStopCompletes.update { hook in
            hook = {
                // The initial drain polling has finished once stop begins. Keep the
                // app stop suspended until two further calls return unavailable.
                let callsAtStop = drain.drains.get()
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(3))
                while drain.drains.get() < callsAtStop + 2 {
                    guard clock.now < deadline else {
                        throw MicropodError.message("drain heartbeat did not repeat while the app was stopping")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        var options = fixture.options
        options.forceUndrained = true
        try await fixture.engine.prepare(fixture.staged, options: options)
        let journal = try await fixture.engine.run()
        try fixture.assertUpgraded(journal)
        XCTAssertEqual(fixture.drain.specs.get(), [journal.drainSpec], "every call names the pinned drain")
    }

    func testGarbageCollectionKeepsCurrentPreviousAndInUse() async throws {
        let fixture = try RigFixture()
        let fm = FileManager.default
        // An older payload a still-running process uses, and one nothing uses.
        let busy = fixture.layout.payloadsRoot.appendingPathComponent("0.13.0-busy")
        let idle = fixture.layout.payloadsRoot.appendingPathComponent("0.12.0-idle")
        try RigFixture.makeBundle(
            busy.appendingPathComponent("Micropod.app"), version: "0.13.0", revision: String(repeating: "c", count: 40))
        try RigFixture.makeBundle(
            idle.appendingPathComponent("Micropod.app"), version: "0.12.0", revision: String(repeating: "d", count: 40))
        fixture.running.update { $0 = [busy.path + "/Micropod.app/Contents/MacOS/micropod-docker-shim"] }
        // An older staged release, and a newer one staged meanwhile.
        _ = try fixture.stage(version: "0.13.9", revision: String(repeating: "e", count: 40))
        let newer = try fixture.stage(version: "0.15.0", revision: String(repeating: "f", count: 40))
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        let journal = try await fixture.engine.run()
        try fixture.assertUpgraded(journal)
        let payloads = Set(try fm.contentsOfDirectory(atPath: fixture.layout.payloadsRoot.path))
        XCTAssertEqual(
            payloads,
            [
                URL(fileURLWithPath: journal.targetPayload).deletingLastPathComponent().lastPathComponent,
                fixture.sourcePayload.deletingLastPathComponent().lastPathComponent, "0.13.0-busy",
            ])
        let releases = Set(try fm.contentsOfDirectory(atPath: fixture.layout.releasesRoot.path))
        XCTAssertEqual(releases, [journal.source.key, newer.identity.key])
        let state = try XCTUnwrap(UpdateStateResolver.rig(layout: fixture.layout))
        XCTAssertEqual(state.kind, .staged)
        XCTAssertEqual(state.targetVersion, "0.15.0")
    }

    func testRollbackThatKeepsFailingNeedsRecoveryAndRecoverRetriesIt() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        // launchd refuses docker-shim, so the upgrade fails and so does every rollback.
        fixture.launch.failBootstrap.update { $0 = [RetainedServiceLaunchAgent.label("docker-shim")] }
        let journal = try await fixture.runToEnd()
        XCTAssertEqual(journal.phase, .recoveryRequired, journal.reason ?? "")
        // Everything else was started again, and the previous bytes are back.
        XCTAssertNotNil(fixture.launch.loaded.get()[RetainedServiceLaunchAgent.label("shared-fs")])
        XCTAssertNotNil(fixture.launch.loaded.get()[RigUpgradeLayout.connectLabel])
        XCTAssertEqual(fixture.app.running.get(), "Micropod 0.14.0")
        XCTAssertEqual(fixture.snapshot(), fixture.originals)
        // The rollback needs docker-shim back too; once launchd takes it, recovery restores.
        fixture.launch.failBootstrap.update { $0 = [] }
        let recovered = try await fixture.engine.recover()
        fixture.assertRestored(recovered)
    }

    func testEngineCrashLoopInAForwardPhaseRollsBack() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        for _ in 0..<RigUpgradeEngine.maximumAttempts {
            fixture.crash.target.update { $0 = "starting:bootstrap:docker-shim" }
            _ = try? await fixture.engine.run()
        }
        let journal = try await fixture.engine.run()
        fixture.assertRestored(journal)
        XCTAssertTrue(journal.failure?.contains("gave up after") == true, journal.failure ?? "")
    }

    func testDesktopTransactionInFlightRefusesTheUpgrade() async throws {
        let fixture = try RigFixture()
        let owner = try XCTUnwrap(try RuntimeProcessBirth.read(getpid()))
        try fixture.layout.desktopUpdates.prepare(
            UpdateContinuityReceipt(
                operation: UUID(), owner: owner, sourceVersion: "0.14.0", sourceExecutableSHA256: "00",
                sourceAppPath: fixture.layout.appPath.path, targetVersion: "0.14.1",
                targetSourceRevision: RigFixture.targetRevision, artifactURL: "https://example.invalid/a.dmg",
                artifactSignature: "AA", artifactBytes: 1, runtimeInstance: UUID(), apiConfigurationSHA256: "00",
                services: []))
        do {
            try await fixture.engine.prepare(fixture.staged, options: fixture.options)
            XCTFail("prepared while a Sparkle install was in flight")
        } catch {
            XCTAssertTrue("\(error)".contains("micropod update recover"), "\(error)")
        }
        XCTAssertEqual(fixture.snapshot(), fixture.originals)
    }

    func testRuntimeMaintenanceInFlightRefusesTheUpgrade() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        // Maintenance began after the upgrade was prepared: refused before the drain.
        fixture.runtimeMaintenance.update { $0 = true }
        let journal = try await fixture.engine.run()
        XCTAssertEqual(journal.phase, .refused)
        XCTAssertTrue(journal.reason?.contains("micropod runtime recover") == true, journal.reason ?? "")
        XCTAssertEqual(fixture.drain.drains.get(), 0)
        XCTAssertEqual(fixture.snapshot(), fixture.originals)
    }

    func testDedicatedRuntimeIsLeftAloneAndSaysSo() async throws {
        let fixture = try RigFixture(dedicated: true)
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        fixture.crash.target.update { $0 = "verifying" }
        _ = try? await fixture.engine.run()
        let state = try XCTUnwrap(UpdateStateResolver.rig(layout: fixture.layout))
        XCTAssertEqual(state.kind, .upgrading)
        XCTAssertEqual(state.phase, "rig-verifying")
        XCTAssertTrue(state.reason.contains(RigUpgradeEngine.dedicatedNote), state.reason)
        let journal = try await fixture.engine.run()
        try fixture.assertUpgraded(journal)
        XCTAssertTrue(journal.reason?.contains(RigUpgradeEngine.dedicatedNote) == true)
    }

    func testFenceHoldsOnlyWhileALiveEngineReplacesServices() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        fixture.crash.target.update { $0 = "swapping" }
        _ = try? await fixture.engine.run()
        XCTAssertEqual(try fixture.journal().phase, .swapping)
        // The engine crashed: the app must not wait on a dead upgrade.
        XCTAssertFalse(RigUpgradeFence.isReplacingServices(layout: fixture.layout))
        XCTAssertNotNil(RigUpgradeFence.inFlight(layout: fixture.layout))
        let lock = try RigUpgradeStore(layout: fixture.layout).lock()
        XCTAssertTrue(RigUpgradeFence.isReplacingServices(layout: fixture.layout))
        XCTAssertThrowsError(try RigUpgradeStore(layout: fixture.layout).lock())
        lock.release()
        try fixture.assertUpgraded(try await fixture.engine.run())
        XCTAssertNil(RigUpgradeFence.inFlight(layout: fixture.layout))
    }

    func testWithoutConnectAPIOnlyRetainedServicesAndAppChange() async throws {
        let fixture = try RigFixture(connect: false)
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        let journal = try await fixture.engine.run()
        try fixture.assertUpgraded(journal)
        XCTAssertEqual(journal.services.map(\.id), ["docker-shim", "shared-fs"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.connectBinary.path))
    }

    func testAlreadyInstalledReleaseIsNotPrepared() async throws {
        let fixture = try RigFixture()
        let same = try fixture.stage(version: "0.14.0", revision: RigFixture.sourceRevision)
        do {
            try await fixture.engine.prepare(same, options: fixture.options)
            XCTFail("prepared the installed release")
        } catch {
            XCTAssertTrue("\(error)".contains("already installed"), "\(error)")
        }
    }
}

final class RigUpgradeStateTests: XCTestCase {
    private func state(_ kind: Micropod_V1_UpdateState.Kind, scope: String = "desktop") -> Micropod_V1_UpdateState {
        Micropod_V1_UpdateState.with {
            $0.kind = kind
            $0.scope = scope
            $0.currentVersion = "0.14.0"
        }
    }

    func testWithoutARigUpgradeTheCombinedStateIsUnchanged() {
        for desktop in [state(.current), state(.staged), state(.recoveryRequired), state(.unknown)] {
            for runtime in [state(.current, scope: "runtime"), state(.upgrading, scope: "runtime")] {
                XCTAssertEqual(
                    UpdateStateResolver.combined(desktop: desktop, runtime: runtime, rig: nil),
                    UpdateStateResolver.combined(desktop: desktop, runtime: runtime))
            }
        }
    }

    func testRigUpgradeInFlightOutranksEverything() {
        var rig = state(.upgrading)
        rig.phase = "rig-swapping"
        XCTAssertEqual(
            UpdateStateResolver.combined(
                desktop: state(.recoveryRequired), runtime: state(.upgrading, scope: "runtime"), rig: rig),
            rig)
    }

    func testRigOutcomeOutranksOnlyAQuietDesktop() {
        let rolledBack = state(.rolledBack)
        XCTAssertEqual(
            UpdateStateResolver.combined(desktop: state(.current), runtime: state(.current), rig: rolledBack).kind,
            .rolledBack)
        XCTAssertEqual(
            UpdateStateResolver.combined(desktop: state(.blocked), runtime: state(.current), rig: rolledBack).kind,
            .blocked)
    }

    func testStagedReleaseIsReportedOnlyWhenNewer() throws {
        let identity = RigBundleIdentity(
            version: "0.14.1", build: "0.14.1", revision: String(repeating: "b", count: 40), executable: "Micropod",
            executableSHA256: "00")
        let staged = RigStagedRelease(identity: identity, artifactURL: "https://example.invalid", artifactSHA256: "00")
        XCTAssertEqual(UpdateStateResolver.rig(journal: nil, staged: staged, installedVersion: "0.14.0")?.kind, .staged)
        XCTAssertNil(UpdateStateResolver.rig(journal: nil, staged: staged, installedVersion: "0.14.1"))
        XCTAssertNil(UpdateStateResolver.rig(journal: nil, staged: nil, installedVersion: "0.14.0"))
    }
}
