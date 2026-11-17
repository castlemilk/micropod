import Crypto
import Foundation
import MicropodCore
import XCTest

@testable import MicropodCLI

final class RigUpgradeCommandsTests: XCTestCase {
    private let none: () -> String? = { nil }

    // MARK: apply routing

    func testApplyWithoutDisruptiveStaysOnTheGuardedSparklePath() throws {
        let request = try RigUpgradeCommands.parseApply([], policy: .guarded, environment: [:], channel: none)
        XCTAssertFalse(request.disruptive)
        XCTAssertNil(request.feed, "the Sparkle path resolves no feed of its own")
    }

    func testDisruptiveHostPolicyMakesApplyDisruptive() throws {
        let request = try RigUpgradeCommands.parseApply([], policy: .disruptive, environment: [:], channel: none)
        XCTAssertTrue(request.disruptive)
        XCTAssertEqual(request.feed, SelfUpdate.feedURL)
        XCTAssertEqual(request.drainTimeout, 120)
        XCTAssertEqual(request.smokeImage, "docker.io/library/alpine:3.23.2")
    }

    func testRigOptionsRequireDisruptive() {
        for args in [
            ["--no-smoke"], ["--drain-timeout", "5"], ["--foreground"], ["--feed", "https://x.invalid/a.xml"],
        ] {
            XCTAssertThrowsError(
                try RigUpgradeCommands.parseApply(args, policy: .guarded, environment: [:], channel: none), "\(args)")
        }
    }

    func testDisruptiveOptions() throws {
        let request = try RigUpgradeCommands.parseApply(
            [
                "--disruptive", "--drain-timeout", "45", "--health-timeout=90", "--no-smoke", "--foreground",
                "--channel", "qualification", "--app", "/tmp/Other.app",
            ], policy: .guarded, environment: [:], channel: none)
        XCTAssertTrue(request.disruptive)
        XCTAssertTrue(request.foreground)
        XCTAssertEqual(request.drainTimeout, 45)
        XCTAssertEqual(request.healthTimeout, 90)
        XCTAssertNil(request.smokeImage)
        XCTAssertEqual(request.appPath.path, "/tmp/Other.app")
        XCTAssertEqual(request.feed?.absoluteString, "https://castlemilk.github.io/micropod/qualification-appcast.xml")
        XCTAssertThrowsError(
            try RigUpgradeCommands.parseApply(
                ["--disruptive", "--drain-timeout", "-1"], policy: .guarded, environment: [:], channel: none))
        XCTAssertThrowsError(
            try RigUpgradeCommands.parseApply(
                ["--disruptive", "--health-timeout", "nan"], policy: .guarded, environment: [:], channel: none))
    }

    func testFeedFollowsFlagThenEnvironmentThenChannel() throws {
        XCTAssertThrowsError(
            try RigUpgradeCommands.feedURL(
                feed: "http://plain.invalid/a.xml", channel: nil, environment: [:], saved: none))
        XCTAssertEqual(
            try RigUpgradeCommands.feedURL(
                feed: nil, channel: nil, environment: ["MICROPOD_UPDATE_FEED": "https://e.invalid/f.xml"], saved: none
            ).absoluteString, "https://e.invalid/f.xml")
        XCTAssertEqual(
            try RigUpgradeCommands.feedURL(feed: nil, channel: nil, environment: [:], saved: { "qualification" })
                .lastPathComponent, "qualification-appcast.xml")
        XCTAssertThrowsError(
            try RigUpgradeCommands.feedURL(feed: nil, channel: "nightly", environment: [:], saved: none))
    }

    func testFeedCarriesTheSourceRevision() throws {
        let revision = String(repeating: "c", count: 40)
        let feed = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><sparkle:version>0.14.1</sparkle:version><sparkle:shortVersionString>0.14.1</sparkle:shortVersionString>
            <enclosure url="https://github.com/castlemilk/micropod/releases/download/v0.14.1/Micropod.dmg"
              sparkle:edSignature="AAAA" length="10" type="application/octet-stream" micropodSourceRevision="\(revision)"/></item>
            <item><sparkle:version>0.14.0</sparkle:version><sparkle:shortVersionString>0.14.0</sparkle:shortVersionString>
            <enclosure url="https://github.com/castlemilk/micropod/releases/download/v0.14.0/Micropod.dmg"
              sparkle:edSignature="AAAA" length="10" type="application/octet-stream" micropodSourceRevision="not-a-sha"/></item>
            </channel></rss>
            """
        let releases = try SelfUpdate.parseFeed(Data(feed.utf8))
        XCTAssertEqual(releases.first { $0.version.description == "0.14.1" }?.sourceRevision, revision)
        XCTAssertNil(releases.first { $0.version.description == "0.14.0" }?.sourceRevision)
    }

    // MARK: staging

    private struct AcceptingVerifier: RigBundleVerifying {
        func verifyApp(_ bundle: URL) throws {}
        func verifyExecutable(_ url: URL, identifier: String) throws {}
    }

    private static func bundle(at url: URL, version: String, revision: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleShortVersionString": version, "CFBundleVersion": version, "CFBundleExecutable": "Micropod",
            "MicropodSourceRevision": revision,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("Micropod \(version)".utf8).write(to: url.appendingPathComponent("Contents/MacOS/Micropod"))
    }

    private func stager(
        _ home: URL, key: Curve25519.Signing.PrivateKey, served: Data, unpacks revision: String
    ) -> RigReleaseStager {
        var stager = RigReleaseStager(layout: RigUpgradeLayout(home: home))
        stager.publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        stager.verifier = AcceptingVerifier()
        stager.download = { _, destination in try served.write(to: destination) }
        stager.extract = { _, destination in try Self.bundle(at: destination, version: "0.14.1", revision: revision) }
        stager.progress = { _ in }
        return stager
    }

    private func release(_ data: Data, key: Curve25519.Signing.PrivateKey, revision: String?) throws
        -> SelfUpdate.Release
    {
        SelfUpdate.Release(
            version: try XCTUnwrap(ReleaseVersion("0.14.1")),
            url: try XCTUnwrap(URL(string: "https://github.com/castlemilk/micropod/releases/download/v0.14.1/M.dmg")),
            signature: try key.signature(for: data), length: data.count, sourceRevision: revision)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rig-stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testTamperedDownloadIsNeverStaged() async throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let revision = String(repeating: "b", count: 40)
        let original = Data("signed disk image".utf8)
        var tampered = original
        tampered[0] ^= 0xFF
        let stager = stager(home, key: key, served: tampered, unpacks: revision)
        do {
            _ = try await stager.stage(try release(original, key: key, revision: revision))
            XCTFail("a tampered download was staged")
        } catch {
            XCTAssertTrue("\(error)".contains("signature"), "\(error)")
        }
        let layout = RigUpgradeLayout(home: home)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: layout.releasesRoot.path)) ?? []
        XCTAssertEqual(left.filter { !$0.hasPrefix(".") }, [])
        XCTAssertNil(RigStagedRelease.newest(in: layout))
    }

    func testVerifiedReleaseIsStagedWithItsIdentity() async throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let revision = String(repeating: "b", count: 40)
        let data = Data("signed disk image".utf8)
        let staged = try await stager(home, key: key, served: data, unpacks: revision).stage(
            try release(data, key: key, revision: revision))
        let layout = RigUpgradeLayout(home: home)
        XCTAssertEqual(staged.identity.version, "0.14.1")
        XCTAssertEqual(staged.identity.revision, revision)
        XCTAssertTrue(staged.identity.matches(staged.bundle(in: layout)))
        XCTAssertEqual(RigStagedRelease.newest(in: layout), staged)
        XCTAssertEqual(staged.bundle(in: layout).deletingLastPathComponent().lastPathComponent, "0.14.1-bbbbbbbbbbbb")
        XCTAssertEqual(UpdateStateResolver.rig(journal: nil, staged: staged, installedVersion: "0.14.0")?.kind, .staged)
    }

    func testBundleThatIsNotTheAdvertisedBuildIsRefused() async throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("signed disk image".utf8)
        let other = stager(home, key: key, served: data, unpacks: String(repeating: "e", count: 40))
        do {
            _ = try await other.stage(try release(data, key: key, revision: String(repeating: "b", count: 40)))
            XCTFail("staged a bundle from another revision")
        } catch {
            XCTAssertTrue("\(error)".contains("not the 0.14.1"), "\(error)")
        }
        let unrevisioned = stager(home, key: key, served: data, unpacks: String(repeating: "b", count: 40))
        do {
            _ = try await unrevisioned.stage(try release(data, key: key, revision: nil))
            XCTFail("staged a release without a source revision")
        } catch {
            XCTAssertTrue("\(error)".contains("source revision"), "\(error)")
        }
    }

    // MARK: helper and status

    func testHelperJobRestartsOnlyOnFailureAndResumesAtLogin() {
        let layout = RigUpgradeLayout(home: URL(fileURLWithPath: "/Users/me"))
        let operation = UUID()
        let configuration = RigUpgradeHelper.configuration(
            helper: URL(fileURLWithPath: "/Users/me/.micropod/rig-upgrade/ops/x/micropod"), layout: layout,
            operation: operation)
        XCTAssertEqual(configuration["Label"] as? String, "com.skunkworq.micropod.rig-upgrade")
        XCTAssertEqual(
            configuration["ProgramArguments"] as? [String],
            [
                "/Users/me/.micropod/rig-upgrade/ops/x/micropod", "update", "rig-helper", "--app",
                "/Applications/Micropod.app", "--operation", operation.uuidString,
            ])
        XCTAssertEqual(configuration["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(configuration["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(
            layout.helperPlist.path, "/Users/me/Library/LaunchAgents/com.skunkworq.micropod.rig-upgrade.plist")
        let probe = try? JSONSerialization.jsonObject(with: Data(RigUpgradeHelper.probe.utf8)) as? [String: Any]
        XCTAssertEqual(probe?["journalSchemas"] as? [Int], [RigUpgradeJournal.schemaVersion])
    }

    func testStatusLines() {
        XCTAssertNil(RigUpgradeCommands.statusLine(nil, policy: .guarded))
        XCTAssertNotNil(RigUpgradeCommands.statusLine(nil, policy: .disruptive))
        let upgrading = Micropod_V1_UpdateState.with {
            $0.kind = .upgrading
            $0.phase = "rig-swapping"
            $0.operationID = "12345678-aaaa"
            $0.currentVersion = "0.14.0"
            $0.targetVersion = "0.14.1"
        }
        XCTAssertEqual(
            RigUpgradeCommands.statusLine(upgrading, policy: .guarded),
            "Rig upgrade 12345678 — rig-swapping: 0.14.0 → 0.14.1")
    }
}

/// The launchd helper handoff, with a fake launchd domain.
final class RigUpgradeHelperTests: XCTestCase {
    final class FakeLaunch: RigLaunchControlling, @unchecked Sendable {
        let lock = NSLock()
        var programs: [String: String] = [:]
        var calls: [String] = []
        var failBootstrap = false
        func record(_ call: String) { lock.withLock { calls.append(call) } }
        func isLoaded(_ label: String) async -> Bool { lock.withLock { programs[label] != nil } }
        func loadedProgram(_ label: String) async -> String? { lock.withLock { programs[label] } }
        func bootout(_ label: String) async throws {
            record("bootout")
            lock.withLock { programs[label] = nil }
        }
        func bootstrap(_ plist: URL, label: String) async throws {
            record("bootstrap")
            if lock.withLock({ failBootstrap }) { throw MicropodError.message("no GUI session") }
            let data = try Data(contentsOf: plist)
            let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            lock.withLock { programs[label] = (value?["ProgramArguments"] as? [String])?.first }
        }
        func kickstart(_ label: String) async throws { record("kickstart") }
    }

    private struct Quiet: RigAppControlling, RigDrainCoordinating, RigHealthProbing, RigBundleVerifying {
        func isRunning(_ app: URL) async -> Bool { false }
        func stop(_ app: URL, timeout: Duration) async throws {}
        func launch(_ app: URL) async throws {}
        func isConfigured() -> Bool { false }
        func drain(_ spec: RigDrainSpec) async -> RigDrainReply { RigDrainReply(.drained) }
        func release(_ spec: RigDrainSpec) async throws -> RigDrainRelease { .released }
        func check(_ expectation: RigHealthExpectation) async -> RigHealthReport { RigHealthReport() }
        func smoke(_ expectation: RigHealthExpectation, image: String) async throws {}
        func connectAnswers(port: UInt16) async -> Bool { false }
        func verifyApp(_ bundle: URL) throws {}
        func verifyExecutable(_ url: URL, identifier: String) throws {}
    }

    private var layout: RigUpgradeLayout!

    override func setUpWithError() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rig-helper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        layout = RigUpgradeLayout(home: home, appPath: home.appendingPathComponent("Applications/Micropod.app"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    }

    private func engine(_ launch: FakeLaunch) -> RigUpgradeEngine {
        let quiet = Quiet()
        return RigUpgradeEngine(
            layout: layout,
            environment: RigUpgradeEnvironment(
                launch: launch, app: quiet, drain: quiet, health: quiet, verifier: quiet, dedicatedRuntime: { false },
                runningExecutables: { [] }, portOwner: { _ in nil }))
    }

    /// A journal on disk in `phase`.
    private func journal(_ phase: RigUpgradeJournal.Phase) throws -> RigUpgradeJournal {
        func identity(_ version: String) -> RigBundleIdentity {
            RigBundleIdentity(
                version: version, build: version, revision: String(repeating: "a", count: 40), executable: "Micropod",
                executableSHA256: version)
        }
        var journal = RigUpgradeJournal(
            operation: UUID(), createdAt: Date(), source: identity("0.14.0"), target: identity("0.14.1"),
            appPath: layout.appPath.path,
            stagedBundle: layout.releasesRoot.appendingPathComponent("x/Micropod.app").path,
            previousBundle: layout.releasesRoot.appendingPathComponent("y/Micropod.app").path, targetPayload: "/none",
            appWasRunning: false, dedicatedRuntime: false, services: [], files: [], baseline: RigHealthBaseline(),
            options: RigUpgradeOptions(dockerShimSocket: "/none", sharedFSSocket: "/none", appControlSocket: "/none"))
        journal.phase = phase
        try RigUpgradeStore(layout: layout).write(journal)
        return journal
    }

    private func source() throws -> URL {
        let url = layout.home.appendingPathComponent("micropod-cli")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url
    }

    private let speaks: (URL) -> RigUpgradeHelper.Probe? = { _ in
        RigUpgradeHelper.parseProbe(RigUpgradeHelper.probe)
    }

    func testProbeReportsSchemaAndServiceDefinitions() throws {
        let probe = try XCTUnwrap(RigUpgradeHelper.parseProbe("noise\n" + RigUpgradeHelper.probe))
        XCTAssertEqual(probe.journalSchemas, [RigUpgradeJournal.schemaVersion])
        XCTAssertEqual(probe.services, RetainedServiceLaunchAgent.definitions)
        XCTAssertNil(RigUpgradeHelper.parseProbe("micropod: unknown command"))
    }

    func testLaunchBootstrapsKickstartsOrReplaces() async throws {
        let journal = try journal(.prepared)
        let launch = FakeLaunch()
        try await RigUpgradeHelper.launch(journal, layout: layout, source: try source(), launch: launch, probe: speaks)
        XCTAssertEqual(launch.calls, ["bootstrap"])
        let helper = RigUpgradeHelper.helperURL(journal, layout: layout).path
        XCTAssertEqual(launch.programs[RigUpgradeLayout.helperLabel], helper)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.helperPlist.path))

        // A second caller resuming the same journal does not boot the helper out.
        try await RigUpgradeHelper.launch(journal, layout: layout, source: try source(), launch: launch, probe: speaks)
        XCTAssertEqual(launch.calls, ["bootstrap", "kickstart"])

        // An earlier operation's helper, still loaded, is replaced.
        launch.programs[RigUpgradeLayout.helperLabel] = "/old/helper"
        try await RigUpgradeHelper.launch(journal, layout: layout, source: try source(), launch: launch, probe: speaks)
        XCTAssertEqual(launch.calls, ["bootstrap", "kickstart", "bootout", "bootstrap"])
    }

    func testLaunchDoesNothingWhileAnEngineRuns() async throws {
        let journal = try journal(.stopping)
        let lock = try RigUpgradeStore(layout: layout).lock()
        defer { lock.release() }
        let launch = FakeLaunch()
        try await RigUpgradeHelper.launch(journal, layout: layout, source: try source(), launch: launch, probe: speaks)
        XCTAssertEqual(launch.calls, [])
    }

    func testHelperThatCannotRunIsNeverInstalled() async throws {
        let journal = try journal(.prepared)
        let launch = FakeLaunch()
        do {
            try await RigUpgradeHelper.launch(
                journal, layout: layout, source: try source(), launch: launch, probe: { _ in nil })
            XCTFail("installed a helper that cannot run")
        } catch {}
        XCTAssertEqual(launch.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.helperPlist.path))
    }

    func testFailedHandOffRefusesAPreparedJournal() async throws {
        let journal = try journal(.prepared)
        let launch = FakeLaunch()
        launch.failBootstrap = true
        let request = try RigUpgradeCommands.parseApply(
            ["--disruptive", "--detach"], policy: .guarded, environment: [:], channel: { nil })
        do {
            _ = try await RigUpgradeCommands.handOff(
                journal, layout: layout, engine: engine(launch), request: request, json: true, launch: launch)
            XCTFail("the handoff did not report the failure")
        } catch {}
        let after = try XCTUnwrap(try RigUpgradeStore(layout: layout).read())
        XCTAssertEqual(after.phase, .refused)
        XCTAssertTrue(after.reason?.contains("helper could not be started") == true, after.reason ?? "")
        XCTAssertNil(RigUpgradeFence.inFlight(layout: layout, helperProgram: { _ in nil }))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.helperPlist.path), "a failed launch left its definition")
    }

    func testFailedHandOffLeavesAStartedUpgradeForRecovery() async throws {
        _ = try journal(.swapping)
        let journal = try XCTUnwrap(try RigUpgradeStore(layout: layout).read())
        let launch = FakeLaunch()
        launch.failBootstrap = true
        let request = try RigUpgradeCommands.parseApply(
            ["--disruptive", "--detach"], policy: .guarded, environment: [:], channel: { nil })
        _ = try? await RigUpgradeCommands.handOff(
            journal, layout: layout, engine: engine(launch), request: request, json: true, launch: launch)
        XCTAssertEqual(try RigUpgradeStore(layout: layout).read()?.phase, .swapping)
    }

    func testHelperRetiresWithNothingToDoOrItsBudgetSpent() async throws {
        let launch = FakeLaunch()
        let idle = await RigUpgradeCommands.runHelper(
            layout: layout, operation: nil, engine: engine(launch), launch: launch)
        XCTAssertEqual(idle, 0)
        XCTAssertEqual(launch.calls, ["bootout"], "no journal: the job boots itself out")

        for phase in [RigUpgradeJournal.Phase.swapping, .rollingBack] {
            let journal = try journal(phase)
            let runs = RigUpgradeHelper.runsURL(journal.operation, layout: layout)
            try FileManager.default.createDirectory(
                at: runs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(RigUpgradeHelper.restartBudget)".utf8).write(to: runs)
            let spent = FakeLaunch()
            let gaveUp = await RigUpgradeCommands.runHelper(
                layout: layout, operation: journal.operation, engine: engine(spent), launch: spent)
            XCTAssertEqual(gaveUp, 0)
            XCTAssertEqual(spent.calls, ["bootout"])
            let after = try XCTUnwrap(try RigUpgradeStore(layout: layout).read())
            XCTAssertEqual(after.phase, .recoveryRequired, "\(phase): UpdateState must not stay UPGRADING")
            XCTAssertTrue(after.reason?.contains("gave up after 20 runs") == true, after.reason ?? "")
        }
    }

    func testHelperRefusesAnotherOperationsJournal() async throws {
        let journal = try journal(.prepared)
        let launch = FakeLaunch()
        let code = await RigUpgradeCommands.runHelper(
            layout: layout, operation: UUID(), engine: engine(launch), launch: launch)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(launch.calls, ["bootout"])
        XCTAssertEqual(try RigUpgradeStore(layout: layout).read(), journal, "the journal was not touched")
    }

    func testHelperStartedAtLoginDoesNotRunAnOldPreparedJournal() async throws {
        let journal = try journal(.prepared)
        let later = journal.updatedAt.addingTimeInterval(RigUpgradeHelper.staleAfter + 60)
        let launch = FakeLaunch()
        let code = await RigUpgradeCommands.runHelper(
            layout: layout, operation: journal.operation, engine: engine(launch), launch: launch, now: later)
        XCTAssertEqual(code, 0)
        let after = try XCTUnwrap(try RigUpgradeStore(layout: layout).read())
        XCTAssertEqual(after.phase, .refused)
        XCTAssertTrue(after.reason?.contains("started at login") == true, after.reason ?? "")

        // Started by a CLI just now, the same journal runs.
        let fresh = try self.journal(.prepared)
        let ticket = RigUpgradeHelper.ticketURL(fresh.operation, layout: layout)
        try FileManager.default.createDirectory(
            at: ticket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(later.timeIntervalSince1970)".utf8).write(to: ticket)
        _ = await RigUpgradeCommands.runHelper(
            layout: layout, operation: fresh.operation, engine: engine(launch), launch: launch, now: later)
        XCTAssertFalse(
            try RigUpgradeStore(layout: layout).read()?.reason?.contains("started at login") ?? true,
            "a helper a CLI just launched was treated as a login start")
    }

    func testHelperWaitsBoundedForAForegroundEngine() async throws {
        _ = try journal(.prepared)
        let lock = try RigUpgradeStore(layout: layout).lock()
        defer { lock.release() }
        let launch = FakeLaunch()
        let code = await RigUpgradeCommands.runHelper(
            layout: layout, operation: try RigUpgradeStore(layout: layout).read()?.operation, engine: engine(launch),
            launch: launch, lockWait: .milliseconds(50))
        XCTAssertEqual(code, 1, "launchd starts it again to resume")
    }

    func testAbandonAndForceFlags() throws {
        let abandon = try RigUpgradeCommands.parseApply(
            ["--abandon"], policy: .guarded, environment: [:], channel: { nil })
        XCTAssertTrue(abandon.abandon)
        XCTAssertTrue(abandon.disruptive)
        let force = try RigUpgradeCommands.parseApply(
            ["--disruptive", "--force-undrained"], policy: .guarded, environment: [:], channel: { nil })
        XCTAssertTrue(force.forceUndrained)
        XCTAssertThrowsError(
            try RigUpgradeCommands.parseApply(
                ["--force-undrained"], policy: .guarded, environment: [:], channel: { nil }))
    }
}
