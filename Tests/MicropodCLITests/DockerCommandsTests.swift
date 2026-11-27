import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodCLI

/// `micropod docker …`: routing past the global flags (before `Services`,
/// so no Apple runtime is resolved), flag values, and the status lines.
final class DockerCommandsTests: XCTestCase {
    func testGlobalFlagsAnywhereStillRouteToDockerCommands() {
        XCTAssertEqual(DockerCommands.route(["--json", "docker", "status"])?.args, ["status"])
        XCTAssertEqual(DockerCommands.route(["--json", "docker", "status"])?.json, true)
        XCTAssertEqual(DockerCommands.route(["docker", "status"])?.json, false)
        XCTAssertEqual(DockerCommands.route(["docker", "install", "--use", "--no-color"])?.args, ["install", "--use"])
        XCTAssertEqual(
            DockerCommands.route(["--cli", "/x/container", "docker", "uninstall", "--force"])?.args,
            ["uninstall", "--force"])
        XCTAssertEqual(DockerCommands.route(["docker"])?.args, [])
        XCTAssertNil(DockerCommands.route(["machine", "status"]))
        XCTAssertNil(DockerCommands.route(["ps", "--json"]))
        XCTAssertNil(MachineCommands.route(["docker", "status"]))
        XCTAssertNil(CacheCommands.route(["docker", "status"]))
    }

    func testBuilderModes() throws {
        XCTAssertEqual(try DockerCommands.builderMode(nil), .auto)
        XCTAssertEqual(try DockerCommands.builderMode("remote"), .remote)
        XCTAssertEqual(try DockerCommands.builderMode("NONE"), HVFDockerWiring.BuilderMode.none)
        XCTAssertThrowsError(try DockerCommands.builderMode("buildkit")) { XCTAssertTrue($0 is UsageError) }
    }

    func testStatusLinesNameTheSelectionAndWhatIsMissing() throws {
        let data = Data(
            #"""
            {"endpoint":"unix:///r/run/docker.sock",
             "dockerCLI":{"path":"/opt/homebrew/bin/docker","version":"29.7.2","apiVersion":"1.43","tooOld":true},
             "context":{"state":"ok","host":"unix:///r/run/docker.sock"},
             "currentContext":"micropod","selected":true,"previousContext":"desktop-linux","recorded":true,
             "environmentOverride":{"DOCKER_HOST":"unix:///x.sock"},
             "compose":{"version":"5.5.0"},"buildx":{"error":"unknown command"},
             "builder":"the context's own builder","dockerBuild":"ready",
             "credentialHelpers":[{"key":"credsStore","name":"desktop","found":false}],
             "otherRuntimes":[{"name":"desktop-linux","endpoint":"unix:///d.sock"}],
             "canonicalLink":{"path":"/c.sock","summary":"absent"},
             "systemSocket":{"path":"/var/run/docker.sock","target":"/d.sock","summary":"-> /d.sock"},
             "machinePhase":"stopped","machineInstalled":true,"notes":[]}
            """#.utf8)
        let status = try JSONDecoder().decode(HVFDockerWiring.Status.self, from: data)
        let lines = Dictionary(DockerCommands.lines(status), uniquingKeysWith: { $1 })
        XCTAssertEqual(lines["docker CLI:"], "/opt/homebrew/bin/docker 29.7.2 (API 1.43, too old)")
        XCTAssertEqual(lines["context:"], "micropod -> unix:///r/run/docker.sock")
        XCTAssertEqual(lines["current context:"], "micropod (selected; uninstall restores desktop-linux)")
        XCTAssertEqual(lines["shell overrides:"], "DOCKER_HOST=unix:///x.sock")
        XCTAssertEqual(lines["buildx:"], "missing")
        XCTAssertEqual(lines["credentials:"], "credsStore desktop (not on PATH)")
        XCTAssertEqual(lines["other runtimes:"], "desktop-linux unix:///d.sock")
        XCTAssertEqual(lines["system socket:"], "/var/run/docker.sock -> /d.sock")
        XCTAssertEqual(lines["machine:"], "stopped")
        XCTAssertTrue(MicropodCLI.helpText.contains("docker install [--use]|uninstall|status"))
        XCTAssertTrue(DockerCommands.helpText.contains("--system-socket"))
    }
}
