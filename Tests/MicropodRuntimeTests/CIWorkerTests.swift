import Foundation
import XCTest

@testable import MicropodRuntime

final class CIWorkerTests: XCTestCase {
    func testDiscoveryUsesOnlyTheOwnedEndpointAndDoesNotStartAWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = EngineRegistry(environment: [
            "MICROPOD_CI_HOME": root.path,
            "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
            "DOCKER_HOST": "tcp://127.0.0.1:1",
        ])
        let engine = try XCTUnwrap(registry.engine("ci") as? DockerEngine)
        let probe = await engine.probe()
        XCTAssertEqual(probe.endpoint, "unix://" + root.appendingPathComponent("docker.sock").path)
        XCTAssertFalse(probe.available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try registry.update("ci", enabled: true, endpoint: "unix:///var/run/docker.sock"))
    }

    func testLaunchAgentRunsTheStableBinaryInTheSpecifiedWorkerDirectory() throws {
        let root = URL(fileURLWithPath: "/Volumes/CI/Worker directory")
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": root.path])
        let binary = URL(fileURLWithPath: "/Applications/Micropod.app/Contents/MacOS/micropod")
        let data = try worker.launchAgent(executable: binary)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [binary.path, "ci", "serve"])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?["MICROPOD_CI_HOME"], root.path)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["Crashed": true])
    }
}
