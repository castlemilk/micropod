import Foundation
import XCTest

@testable import MicropodCLI

/// `micropod sandbox` flag semantics that mirror shuru: `--mount` never
/// writes to the host unless asked twice, and `micropod.json` reads like
/// `shuru.json`.
final class SandboxCommandsTests: XCTestCase {
    func testMountDefaultsToDiscardingGuestWrites() throws {
        XCTAssertEqual(try SandboxCommands.mountSpec("/src:/w", allowHostWrites: false), "/src:/w:overlay")
        XCTAssertEqual(try SandboxCommands.mountSpec("/src:/w:ro", allowHostWrites: false), "/src:/w:ro")
        XCTAssertThrowsError(try SandboxCommands.mountSpec("/src:/w:rw", allowHostWrites: false)) { error in
            XCTAssertTrue((error as? UsageError)?.message.contains("--allow-host-writes") == true)
        }
        XCTAssertEqual(try SandboxCommands.mountSpec("/src:/w:rw", allowHostWrites: true), "/src:/w:rw")
        XCTAssertEqual(
            try SandboxCommands.mountSpec("~/src:/w", allowHostWrites: false),
            "\(NSHomeDirectory())/src:/w:overlay")
        XCTAssertThrowsError(try SandboxCommands.mountSpec("/src", allowHostWrites: false))
        XCTAssertThrowsError(try SandboxCommands.mountSpec("/src:/w:overlay", allowHostWrites: false))
    }

    func testConfigReadsShuruShapedJSON() throws {
        let json = """
            {
              "image": "python:3.12-slim",
              "cpus": 4, "memory": 4096, "disk_size": 8192,
              "allow_net": true,
              "ports": ["8080:80"],
              "mounts": ["./src:/workspace"],
              "command": ["python", "script.py"],
              "env": {"B": "2", "A": "1"},
              "expose_host": [5432],
              "secrets": {"API_KEY": {"from": "OPENAI_API_KEY", "hosts": ["api.openai.com"]}},
              "network": {"allow": ["api.openai.com", "*.npmjs.org"]}
            }
            """
        let config = try JSONDecoder().decode(SandboxConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.image, "python:3.12-slim")
        XCTAssertEqual(config.cpus, 4)
        XCTAssertEqual(config.memory, 4096)
        XCTAssertEqual(config.diskSize, 8192)
        XCTAssertEqual(config.allowNet, true)
        XCTAssertEqual(config.ports, ["8080:80"])
        XCTAssertEqual(config.command, ["python", "script.py"])
        XCTAssertEqual(config.env, ["A=1", "B=2"], "a map becomes sorted KEY=VAL")
        XCTAssertEqual(config.exposeHost, [5432])
        let secrets = try config.sandboxSecrets(environment: ["OPENAI_API_KEY": "sk-real"])
        XCTAssertEqual(secrets.map(\.name), ["API_KEY"])
        XCTAssertEqual(secrets.first?.hosts, ["api.openai.com"])
        XCTAssertEqual(secrets.first?.source.kind, .fixed("sk-real"))
        XCTAssertEqual(config.network?.allow, ["api.openai.com", "*.npmjs.org"])

        let list = try JSONDecoder().decode(SandboxConfig.self, from: Data(#"{"env": ["X=1"]}"#.utf8))
        XCTAssertEqual(list.env, ["X=1"])
    }

    /// shuru's refreshable form: a host command (relative to micropod.json)
    /// mints the value.
    func testConfigCommandSecretsRunFromTheConfigDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("micropod.json")
        try #"{"secrets": {"GH": {"command": ["./mint.sh", "--app"], "hosts": ["api.github.com"], "ttl": "15m"}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(try SandboxConfig.load(explicit: file.path))
        let secret = try XCTUnwrap(try config.sandboxSecrets().first)
        XCTAssertEqual(secret.name, "GH")
        XCTAssertEqual(
            secret.source.kind,
            .command(argv: ["./mint.sh", "--app"], directory: dir.standardizedFileURL, ttl: .seconds(900)))

        for bad in [
            #"{"secrets": {"X": {"command": ["m"], "hosts": ["h"], "ttl": "soon"}}}"#,
            #"{"secrets": {"X": {"from": "E", "command": ["m"], "hosts": ["h"]}}}"#,
            #"{"secrets": {"X": {"hosts": ["h"]}}}"#,
        ] {
            let config = try JSONDecoder().decode(SandboxConfig.self, from: Data(bad.utf8))
            XCTAssertThrowsError(try config.sandboxSecrets(environment: ["E": "v"]), bad)
        }
    }

    func testConfigLoadsOnlyWhenPresentOrNamed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(dir.path)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }

        XCTAssertNil(try SandboxConfig.load(explicit: nil), "no micropod.json, no config")
        XCTAssertThrowsError(try SandboxConfig.load(explicit: "missing.json"), "a named file must exist")
        try #"{"cpus": 3}"#.write(toFile: "micropod.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(try SandboxConfig.load(explicit: nil)?.cpus, 3)
        try "{".write(toFile: "micropod.json", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SandboxConfig.load(explicit: nil), "a broken file is an error, not ignored")
    }
}
