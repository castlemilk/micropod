import Foundation
import XCTest

@testable import MicropodCore

final class CLIInstallTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func app(_ name: String, tools: [String] = ["micropod-cli", "MicropodMCP"]) throws -> URL {
        let app = root.appendingPathComponent("\(name)/Micropod.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        for tool in tools {
            FileManager.default.createFile(
                atPath: macOS.appendingPathComponent(tool).path, contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: 0o755])
        }
        return app
    }

    func testKindFollowsWhereTheBinaryLives() throws {
        let installed = try app("Applications")
        XCTAssertEqual(
            CLIInstall.kind(of: installed.appendingPathComponent("Contents/MacOS/micropod-cli")),
            .appManaged(app: installed.resolvingSymlinksInPath()))
        // Through a symlink, as ~/.local/bin/micropod is.
        let bin = root.appendingPathComponent("bin")
        try CLIInstall.linkTools(from: installed, into: bin)
        XCTAssertEqual(
            CLIInstall.kind(of: bin.appendingPathComponent("micropod")),
            .appManaged(app: installed.resolvingSymlinksInPath()))
        XCTAssertEqual(CLIInstall.kind(of: URL(fileURLWithPath: "/usr/local/bin/micropod")), .standalone)
        XCTAssertEqual(
            CLIInstall.kind(of: URL(fileURLWithPath: "/Users/me/src/micropod/.build/debug/micropod")), .development)
        XCTAssertEqual(
            CLIInstall.kind(of: URL(fileURLWithPath: "/Applications/Micropod.app/Contents/Resources/micropod")),
            .standalone, "only Contents/MacOS is the app's own code")
    }

    func testLinkingCreatesReplacesAndRepoints() throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // A standalone copy from install.sh / a tarball, and the old wrapper.
        try Data("old cli".utf8).write(to: bin.appendingPathComponent("micropod"))
        try Data("#!/bin/bash\nexec micropod-mcp-bin\n".utf8).write(to: bin.appendingPathComponent("micropod-mcp"))

        let first = try app("a")
        XCTAssertEqual(
            try CLIInstall.linkTools(from: first, into: bin),
            [
                .replaced("micropod", backup: "micropod.pre-app.bak"),
                .replaced("micropod-mcp", backup: "micropod-mcp.pre-app.bak"),
            ])
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("micropod").path),
            first.appendingPathComponent("Contents/MacOS/micropod-cli").path)
        XCTAssertEqual(
            try String(contentsOf: bin.appendingPathComponent("micropod.pre-app.bak"), encoding: .utf8), "old cli")
        XCTAssertEqual(CLIInstall.linkedTools(to: first, in: bin), ["micropod", "micropod-mcp"])

        XCTAssertEqual(
            try CLIInstall.linkTools(from: first, into: bin), [.unchanged("micropod"), .unchanged("micropod-mcp")])

        let second = try app("b")
        XCTAssertEqual(
            try CLIInstall.linkTools(from: second, into: bin), [.repointed("micropod"), .repointed("micropod-mcp")])
        XCTAssertEqual(CLIInstall.linkedTools(to: first, in: bin), [])
        XCTAssertEqual(
            try String(contentsOf: bin.appendingPathComponent("micropod.pre-app.bak"), encoding: .utf8), "old cli",
            "the first backup is never overwritten")

        let fresh = root.appendingPathComponent("fresh/bin")
        XCTAssertEqual(
            try CLIInstall.linkTools(from: first, into: fresh), [.created("micropod"), .created("micropod-mcp")])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bin.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "no staging links left behind")
    }

    func testAnOlderBundleWithoutTheToolsLinksNothing() throws {
        let old = try app("old", tools: [])
        let bin = root.appendingPathComponent("bin")
        XCTAssertEqual(try CLIInstall.linkTools(from: old, into: bin), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("micropod").path))
    }

    func testReleaseVersionOrdering() throws {
        func v(_ s: String) throws -> ReleaseVersion { try XCTUnwrap(ReleaseVersion(s), s) }
        XCTAssertLessThan(try v("0.11.2"), try v("0.11.10"))
        XCTAssertLessThan(try v("0.11.9"), try v("0.12.0"))
        XCTAssertLessThan(try v("0.12.0-rc1"), try v("0.12.0"), "a pre-release precedes its release")
        XCTAssertLessThan(try v("0.11.2-stamptest"), try v("0.11.2"))
        XCTAssertEqual(try v("v0.11.2"), try v("0.11.2"))
        XCTAssertEqual(try v("1.0"), try v("1.0.0"))
        XCTAssertNil(ReleaseVersion("dev"))
        XCTAssertNil(ReleaseVersion("1.x.0"))
        XCTAssertNil(ReleaseVersion(""))
    }
}
