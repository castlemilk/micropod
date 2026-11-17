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
        let configuration = RigUpgradeHelper.configuration(
            helper: URL(fileURLWithPath: "/Users/me/.micropod/rig-upgrade/ops/x/micropod"), layout: layout)
        XCTAssertEqual(configuration["Label"] as? String, "com.skunkworq.micropod.rig-upgrade")
        XCTAssertEqual(
            configuration["ProgramArguments"] as? [String],
            [
                "/Users/me/.micropod/rig-upgrade/ops/x/micropod", "update", "rig-helper", "--app",
                "/Applications/Micropod.app",
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
