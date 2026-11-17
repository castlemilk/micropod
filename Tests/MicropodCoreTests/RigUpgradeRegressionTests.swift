import Foundation
import XCTest

@testable import MicropodCore

/// Regressions from the review of the first rig upgrade (PR #113), and the
/// recovery paths it found untested.
final class RigUpgradeRegressionTests: XCTestCase {
    func testSymlinkedInstalledFileIsRefusedBeforeAnythingIsRecorded() async throws {
        let fixture = try RigFixture()
        let fm = FileManager.default
        let real = fixture.root.appendingPathComponent("elsewhere/MicropodAPI")
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MicropodAPI 0.14.0".utf8).write(to: real)
        try fm.removeItem(at: fixture.layout.connectBinary)
        try fm.createSymbolicLink(at: fixture.layout.connectBinary, withDestinationURL: real)
        do {
            try await fixture.engine.prepare(fixture.staged, options: fixture.options)
            XCTFail("prepared over a symbolic link")
        } catch {
            XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
        }
        XCTAssertNil(try RigUpgradeStore(layout: fixture.layout).read())
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: fixture.layout.connectBinary.path), real.path)
    }

    func testRollbackGetsItsOwnAttempts() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        for _ in 0..<4 {
            fixture.crash.target.update { $0 = "starting:bootstrap:docker-shim" }
            _ = try? await fixture.engine.run()
        }
        XCTAssertEqual(try fixture.journal().attempts, 4)
        // The fifth run fails a step for real and rolls back; it crashes once there.
        fixture.launch.failBootstrap.update { $0 = [RetainedServiceLaunchAgent.label("docker-shim")] }
        fixture.crash.target.update { $0 = "rollingBack:swapped-back" }
        _ = try? await fixture.engine.run()
        XCTAssertEqual(try fixture.journal().phase, .rollingBack)
        XCTAssertEqual(try fixture.journal().attempts, 1)
        fixture.launch.failBootstrap.update { $0 = [] }
        fixture.assertRestored(try await fixture.engine.run())
    }

    func testAppReplacedBySomethingElseStillRestoresServices() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        fixture.crash.target.update { $0 = "stopping:stopped-app" }
        _ = try? await fixture.engine.run()
        try FileManager.default.removeItem(at: fixture.layout.appPath)
        try RigFixture.makeBundle(
            fixture.layout.appPath, version: "0.14.2", revision: String(repeating: "9", count: 40))
        let journal = try await fixture.runToEnd()
        XCTAssertEqual(journal.phase, .recoveryRequired, journal.reason ?? "")
        XCTAssertTrue(journal.reason?.contains("neither") == true, journal.reason ?? "")
        fixture.assertServicesLoaded()
        XCTAssertEqual(fixture.app.running.get(), "Micropod 0.14.2", "the app was relaunched as it is")
        var expected = fixture.originals
        expected[fixture.layout.appPath.appendingPathComponent("Contents/MacOS/Micropod").path] = nil
        var now = fixture.snapshot()
        now[fixture.layout.appPath.appendingPathComponent("Contents/MacOS/Micropod").path] = nil
        XCTAssertEqual(now, expected, "every service file is back")

        // recover --rig runs the rollback again and leaves everything running.
        fixture.launch.loaded.update { $0 = [:] }
        fixture.app.running.update { $0 = nil }
        let recovered = try await fixture.engine.recover()
        XCTAssertEqual(recovered.phase, .recoveryRequired)
        fixture.assertServicesLoaded()
        XCTAssertEqual(fixture.app.running.get(), "Micropod 0.14.2")
    }

    func testSparkleInstallOnQuitDuringStopIsRolledBackAround() async throws {
        let fixture = try RigFixture()
        let app = fixture.layout.appPath
        fixture.app.onStop.update {
            $0 = {
                try? FileManager.default.removeItem(at: app)
                try? RigFixture.makeBundle(app, version: "0.14.2", revision: String(repeating: "8", count: 40))
            }
        }
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        let journal = try await fixture.engine.run()
        XCTAssertEqual(journal.phase, .recoveryRequired, journal.reason ?? "")
        XCTAssertTrue(journal.failure?.contains("something else replaced it") == true, journal.failure ?? "")
        fixture.assertServicesLoaded()
        XCTAssertTrue(
            fixture.staged.identity.matches(fixture.staged.bundle(in: fixture.layout)), "the target was not swapped")
    }

    func testSparkleInstallerRunningRefusesBeforeStopping() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        fixture.installerRunning.update { $0 = true }
        let journal = try await fixture.engine.run()
        XCTAssertEqual(journal.phase, .refused)
        XCTAssertTrue(journal.reason?.contains("Sparkle") == true, journal.reason ?? "")
        XCTAssertEqual(fixture.app.calls.get(), [])
        XCTAssertEqual(fixture.drain.drains.get(), 0, "refused before the rig was asked to drain")
    }

    func testRecoverOnAPreparedJournalAbandonsIt() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        // No engine runs and no helper is installed: a stale journal fences nothing.
        XCTAssertNil(RigUpgradeFence.inFlight(layout: fixture.layout))
        XCTAssertNotNil(RigUpgradeFence.unfinished(layout: fixture.layout))
        XCTAssertNotEqual(UpdateStateResolver.rig(layout: fixture.layout)?.kind, .upgrading)
        // With a helper installed it is under way.
        try FileManager.default.createDirectory(at: fixture.layout.launchAgents, withIntermediateDirectories: true)
        try Data().write(to: fixture.layout.helperPlist)
        XCTAssertNotNil(RigUpgradeFence.inFlight(layout: fixture.layout))
        XCTAssertEqual(UpdateStateResolver.rig(layout: fixture.layout)?.kind, .upgrading)

        let journal = try await fixture.engine.recover()
        XCTAssertEqual(journal.phase, .refused)
        XCTAssertEqual(fixture.app.calls.get(), [])
        XCTAssertEqual(fixture.snapshot(), fixture.originals)
    }

    func testAbandonOnlyBeforeServicesStop() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        fixture.crash.target.update { $0 = "draining:poll" }
        let slow = try RigFixture(drain: FakeDrain(drainAfter: nil))
        try await slow.engine.prepare(slow.staged, options: slow.options)
        slow.crash.target.update { $0 = "draining:poll" }
        _ = try? await slow.engine.run()
        let abandoned = try await slow.engine.abandon(reason: "Abandoned by a test.")
        XCTAssertEqual(abandoned.phase, .refused)
        XCTAssertEqual(slow.drain.releases.get(), [abandoned.operation], "the drain it took is released")

        fixture.crash.target.update { $0 = "swapping" }
        _ = try? await fixture.engine.run()
        do {
            _ = try await fixture.engine.abandon(reason: "too late")
            XCTFail("abandoned an upgrade that had stopped services")
        } catch {
            XCTAssertTrue("\(error)".contains("recover --rig"), "\(error)")
        }
    }

    func testRebootAtEveryCheckpointResumesToCompletion() async throws {
        let dry = try RigFixture()
        try await dry.engine.prepare(dry.staged, options: dry.options)
        try dry.assertUpgraded(try await dry.engine.run())
        var checkpoints: [String] = []
        // After `completed` nothing is the engine's to restart.
        for name in dry.crash.seen.get() where !["prepared", "completed"].contains(name) && !checkpoints.contains(name)
        {
            checkpoints.append(name)
        }
        for name in checkpoints {
            let fixture = try RigFixture()
            try await fixture.engine.prepare(fixture.staged, options: fixture.options)
            fixture.crash.target.update { $0 = name }
            _ = try? await fixture.engine.run()
            fixture.reboot()
            let resumed = try await fixture.engine.run()
            try fixture.assertUpgraded(resumed)
            // launchd runs the definitions on disk, not ones from before the reboot.
            for (label, job) in fixture.launch.loaded.get() {
                XCTAssertEqual(job.program, RigUpgradeEngine.programPath(job.plist), "\(name): \(label) is stale")
            }
        }
    }

    func testRebootDuringVerifyingRelaunchesTheApp() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        fixture.crash.target.update { $0 = "verifying" }
        _ = try? await fixture.engine.run()
        fixture.app.running.update { $0 = nil }
        try fixture.assertUpgraded(try await fixture.engine.run())
    }

    func testStaleDefinitionIsReplacedOnResume() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        fixture.crash.target.update { $0 = "verifying" }
        _ = try? await fixture.engine.run()
        // launchd still runs docker-shim from the previous payload's definition.
        let label = RetainedServiceLaunchAgent.label("docker-shim")
        let old = fixture.sourcePayload.appendingPathComponent("Contents/MacOS/micropod-docker-shim").path
        fixture.launch.loaded.update { $0[label] = .init(plist: $0[label]!.plist, program: old) }
        try fixture.assertUpgraded(try await fixture.engine.run())
        XCTAssertNotEqual(fixture.launch.loaded.get()[label]?.program, old)
    }

    func testFailingStopBootoutAndConnectRollBack() async throws {
        let stop = try RigFixture()
        stop.app.failStops.update { $0 = 1 }
        try await stop.engine.prepare(stop.staged, options: stop.options)
        stop.assertRestored(try await stop.engine.run())

        let bootout = try RigFixture()
        bootout.launch.failBootoutOnce.update { $0 = [RigUpgradeLayout.connectLabel] }
        try await bootout.engine.prepare(bootout.staged, options: bootout.options)
        let journal = try await bootout.engine.run()
        bootout.assertRestored(journal)
        XCTAssertTrue(journal.failure?.hasPrefix("stopping:") == true, journal.failure ?? "")

        let connect = try RigFixture()
        connect.health.connectDown.update { $0 = ["0.14.1"] }
        try await connect.engine.prepare(connect.staged, options: connect.options)
        let down = try await connect.engine.run()
        connect.assertRestored(down)
        XCTAssertTrue(down.failure?.contains("Connect API") == true, down.failure ?? "")
    }

    func testUnreleasedDrainIsReleasedByTheNextUpgrade() async throws {
        let fixture = try RigFixture()
        fixture.drain.releaseFails.update { $0 = true }
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        let first = try await fixture.engine.run()
        try fixture.assertUpgraded(first)
        XCTAssertFalse(first.drainReleased)
        XCTAssertEqual(RigDrainLedger(layout: fixture.layout).entries(), [first.drainSpec])
        // A later upgrade replaces the journal, and still releases the first drain.
        fixture.drain.releaseFails.update { $0 = false }
        let next = try fixture.stage(version: "0.14.2", revision: String(repeating: "7", count: 40))
        try await fixture.engine.prepare(next, options: fixture.options)
        XCTAssertEqual(fixture.drain.releases.get(), [first.operation])
        XCTAssertEqual(RigDrainLedger(layout: fixture.layout).entries(), [])
    }

    func testPreviousAppIsKeptWhenItCannotBeMoved() async throws {
        let fixture = try RigFixture()
        try await fixture.engine.prepare(fixture.staged, options: fixture.options)
        let journal = try fixture.journal()
        // Something occupies the previous release's directory name.
        let blocker = URL(fileURLWithPath: journal.previousBundle).deletingLastPathComponent()
        try Data("not a directory".utf8).write(to: blocker)
        let done = try await fixture.engine.run()
        XCTAssertEqual(done.phase, .completed)
        XCTAssertTrue(
            done.source.matches(URL(fileURLWithPath: done.stagedBundle)), "the only previous copy was removed")
    }
}

/// RigCuttlefishDrain against the reply shapes in docs/contracts/rig-upgrade-drain.json,
/// which Cuttlefish's maintenance server tests against too.
final class RigDrainContractTests: XCTestCase {
    private struct Contract: Decodable {
        struct Request: Decodable {
            let action: String
            let request: [String: String]
        }
        struct DrainReply: Decodable {
            let reply: [String: JSONValue]
            let state: String
        }
        struct ReleaseSequence: Decodable {
            let replies: [[String: JSONValue]]
            let outcome: String
        }
        let operation: UUID
        let requests: [Request]
        let drainReplies: [DrainReply]
        let releaseSequences: [ReleaseSequence]
    }

    private func contract() throws -> Contract {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/contracts/rig-upgrade-drain.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    private func line(_ value: [String: JSONValue]) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func spec(_ contract: Contract) -> RigDrainSpec {
        RigDrainSpec(operation: contract.operation, createdAt: Date())
    }

    /// A transport that records requests and answers with `replies` in order.
    private final class Script: @unchecked Sendable {
        let requests = Locked<[[String: String]]>([])
        let replies: Locked<[Result<Data, Error>]>
        init(_ replies: [Result<Data, Error>]) { self.replies = Locked(replies) }
        func exchange(_ request: Data) throws -> Data {
            XCTAssertEqual(request.last, 10, "a request is one line")
            let fields = try JSONDecoder().decode([String: String].self, from: request.dropLast())
            requests.update { $0.append(fields) }
            return try replies.update { $0.isEmpty ? .failure(RuntimePeerNoReply()) : $0.removeFirst() }.get()
        }
    }

    private func client(_ script: Script) -> RigCuttlefishDrain {
        RigCuttlefishDrain(home: URL(fileURLWithPath: "/nonexistent")) { try script.exchange($0) }
    }

    func testRequestsCarryOnlyTheOperationKindAndAction() throws {
        let contract = try contract()
        for expected in contract.requests {
            let data = try RigCuttlefishDrain.request(spec(contract), action: expected.action)
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: data.dropLast()), expected.request)
        }
    }

    func testDrainReplyShapes() async throws {
        let contract = try contract()
        for fixture in contract.drainReplies {
            let script = Script([.success(try line(fixture.reply))])
            let reply = await client(script).drain(spec(contract))
            XCTAssertEqual(reply.state.rawValue, fixture.state, "\(fixture.reply)")
            XCTAssertEqual(script.requests.get().first?["action"], "drain")
        }
    }

    func testTransportFailuresAreLoudNotDraining() async throws {
        let contract = try contract()
        let silent = await client(Script([.failure(RuntimePeerNoReply())])).drain(spec(contract))
        XCTAssertEqual(silent.state, .incompatible)
        XCTAssertTrue(silent.reason?.contains("does not accept rig-upgrade drains") == true)
        let absent = await client(Script([.failure(RuntimeRigAdmissionError.unavailable("no socket"))])).drain(
            spec(contract))
        XCTAssertEqual(absent.state, .unavailable)
        let garbage = await client(Script([.success(Data("{\"ok\":true}".utf8))])).drain(spec(contract))
        XCTAssertEqual(garbage.state, .incompatible)
        let empty = await client(Script([.success(Data())])).drain(spec(contract))
        XCTAssertEqual(empty.state, .incompatible)
    }

    func testReleaseSequences() async throws {
        let contract = try contract()
        for sequence in contract.releaseSequences {
            let script = Script(try sequence.replies.map { .success(try line($0)) })
            let drain = client(script)
            switch sequence.outcome {
            case "released":
                let outcome = try await drain.release(spec(contract))
                XCTAssertEqual(outcome, .released)
                XCTAssertEqual(script.requests.get().map { $0["action"] }, ["abort", "abortComplete"])
            case "notHeld":
                let outcome = try await drain.release(spec(contract))
                XCTAssertEqual(outcome, .notHeld)
            default:
                do {
                    _ = try await drain.release(spec(contract))
                    XCTFail("an unconfirmed release was reported released")
                } catch {}
            }
        }
        // An older Cuttlefish rejects every rig-upgrade call, so it holds nothing.
        let old = try await client(Script([.failure(RuntimePeerNoReply())])).release(spec(contract))
        XCTAssertEqual(old, .notHeld)
        do {
            _ = try await client(Script([.failure(RuntimeRigAdmissionError.unavailable("down"))])).release(
                spec(contract))
            XCTFail("a release that was never sent was reported done")
        } catch {}
    }
}
