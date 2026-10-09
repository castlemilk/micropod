import Crypto
import Foundation
import MicropodCore
import XCTest

@testable import MicropodCLI

final class SelfUpdateTests: XCTestCase {
    /// The live appcast's shape (two items, newest first — but order isn't
    /// trusted), plus a broken item that must be skipped.
    private let feed = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Micropod Updates</title>
            <item>
              <title>Version 0.11.1</title>
              <sparkle:version>0.11.1</sparkle:version>
              <sparkle:shortVersionString>0.11.1</sparkle:shortVersionString>
              <enclosure url="https://github.com/castlemilk/micropod/releases/download/v0.11.1/Micropod.dmg"
                sparkle:edSignature="AAAA" length="64405730" type="application/octet-stream"/>
            </item>
            <item>
              <title>Version 0.11.10</title>
              <sparkle:version>0.11.10</sparkle:version>
              <sparkle:shortVersionString>0.11.10</sparkle:shortVersionString>
              <enclosure url="https://github.com/castlemilk/micropod/releases/download/v0.11.10/Micropod.dmg"
                sparkle:edSignature="BBBB" length="65324129" type="application/octet-stream"/>
            </item>
            <item>
              <title>Version 9.9.9</title>
              <sparkle:version>9.9.9</sparkle:version>
              <enclosure url="http://insecure.example/Micropod.dmg" sparkle:edSignature="CCCC" length="1"/>
            </item>
          </channel>
        </rss>
        """

    func testFeedParsingPicksTheNewestUsableRelease() throws {
        let releases = try SelfUpdate.parseFeed(Data(feed.utf8))
        XCTAssertEqual(releases.map(\.version.description), ["0.11.1", "0.11.10"], "plain http is refused")
        let newest = try XCTUnwrap(releases.max { $0.version < $1.version })
        XCTAssertEqual(newest.version.description, "0.11.10", "0.11.10 > 0.11.1 numerically")
        XCTAssertEqual(newest.length, 65_324_129)
        XCTAssertEqual(newest.signature, Data(base64Encoded: "BBBB"))
        XCTAssertThrowsError(try SelfUpdate.parseFeed(Data("<rss><channel><item>".utf8)))
    }

    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let signature = try key.signature(for: payload)
        XCTAssertTrue(SelfUpdate.verify(payload, signature: signature, publicKey: publicKey))
        var tampered = payload
        tampered[100] ^= 1
        XCTAssertFalse(SelfUpdate.verify(tampered, signature: signature, publicKey: publicKey))
        XCTAssertFalse(
            SelfUpdate.verify(
                payload, signature: signature,
                publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()),
            "another key's signature doesn't count")
        XCTAssertFalse(SelfUpdate.verify(payload, signature: signature, publicKey: "not base64"))
    }

    func testInformationalAnnouncementCannotBecomeACLIInstall() throws {
        let announcement = """
            <item>
              <sparkle:version>0.12.6</sparkle:version>
              <sparkle:shortVersionString>0.12.6</sparkle:shortVersionString>
              <link>https://github.com/castlemilk/micropod/releases/tag/v0.12.6</link>
              <sparkle:informationalUpdate/>
            </item>
            """
        let announced = feed.replacingOccurrences(of: "</channel>", with: announcement + "</channel>")
        let releases = try SelfUpdate.parseFeed(Data(announced.utf8))
        XCTAssertEqual(releases.map(\.version.description), ["0.11.1", "0.11.10"])
        XCTAssertFalse(releases.contains { $0.version.description == "0.12.6" })
    }

    /// The key the CLI trusts is the one the app ships (SUPublicEDKey).
    func testTrustedKeyMatchesTheAppsSparkleKey() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/package_app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #""SUPublicEDKey"\s*:\s*"([^"]+)""#)
        let match = try XCTUnwrap(pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let keyRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
        XCTAssertEqual(String(text[keyRange]), SelfUpdate.publicKey)
    }

    func testCodeSignatureRequirement() {
        // Apple's own tools satisfy "anchor apple", not micropod's team.
        let ls = URL(fileURLWithPath: "/bin/ls")
        XCTAssertTrue(SelfUpdate.hasValidSignature(ls, requirement: "anchor apple"))
        XCTAssertFalse(SelfUpdate.hasValidSignature(ls), "not signed by micropod's Developer ID")
        XCTAssertFalse(SelfUpdate.hasValidSignature(URL(fileURLWithPath: "/nonexistent")))
    }

    func testInstalledFilesIncludeTheMCPServerBesideTheCLI() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("self-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("micropod")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 1]).write(to: cli)
        XCTAssertEqual(SelfUpdate.installedFiles(cli: cli).map(\.bundled), ["micropod-cli"])
        // install.sh's layout: a wrapper script + the Mach-O behind it.
        try Data("#!/bin/bash\nexec micropod-mcp-bin\n".utf8).write(to: dir.appendingPathComponent("micropod-mcp"))
        try Data([0xCF, 0xFA, 0xED, 0xFE, 2]).write(to: dir.appendingPathComponent("micropod-mcp-bin"))
        let files = SelfUpdate.installedFiles(cli: cli)
        XCTAssertEqual(files.map(\.bundled), ["micropod-cli", "MicropodMCP"])
        XCTAssertEqual(files.last?.path.lastPathComponent, "micropod-mcp-bin", "the Mach-O, not the wrapper")
    }

    func testNoticeWording() {
        let app = CLIInstall.Kind.appManaged(app: URL(fileURLWithPath: "/Applications/Micropod.app"))
        XCTAssertNil(UpdateNotice.message(latest: "0.11.2", kind: .standalone, current: "0.11.2"))
        XCTAssertNil(UpdateNotice.message(latest: "0.11.1", kind: .standalone, current: "0.11.2"))
        XCTAssertNil(UpdateNotice.message(latest: nil, kind: .standalone, current: "0.11.2"))
        XCTAssertNil(UpdateNotice.message(latest: "0.12.0", kind: .development, current: "0.11.2"))
        XCTAssertNil(UpdateNotice.message(latest: "0.12.0", kind: .standalone, current: "dev"))
        XCTAssertEqual(
            UpdateNotice.message(latest: "0.12.0", kind: .standalone, current: "0.11.2"),
            "micropod 0.12.0 is out (this is 0.11.2) — `micropod update cli` installs it")
        XCTAssertTrue(
            UpdateNotice.message(latest: "0.12.0", kind: app, current: "0.11.2")?.contains("comes with the app") == true
        )
    }
}
