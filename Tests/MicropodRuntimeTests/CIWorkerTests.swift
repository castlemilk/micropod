import Foundation
import MicropodCore
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

    func testRunRejectsAWorkerWithAPendingStopBeforeConnectingOrLaunching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ci-" + UUID().uuidString.prefix(8))
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": root.path])
        try worker.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        let instance = UUID()
        let session = CIWorker.Session(owner: owner, instance: instance, started: true)
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        try Data().write(to: root.appendingPathComponent("stop-" + instance.uuidString))
        do {
            _ = try await worker.runEndpoint(executable: root.appendingPathComponent("unused"))
            XCTFail("A draining worker accepted a job")
        } catch {
            XCTAssertEqual(error.localizedDescription, "CI worker is stopping")
        }
    }

    func testNetworkProbeRequiresAnAddressOnTheMac() throws {
        XCTAssertTrue(try CIWorker.hasLocalGateway("127.0.0.1"))
        XCTAssertFalse(try CIWorker.hasLocalGateway("192.0.2.254"))
        XCTAssertFalse(try CIWorker.hasLocalGateway("example.org"))
    }

    func testMetricsGroupsOverlappingScopeAndStoreNames() throws {
        XCTAssertNil(CIWorker.cacheStore("unrelated-gobuild", activeContainers: 5))
        XCTAssertNil(CIWorker.cacheStore("micropod-ci-scoped--npm", activeContainers: 0))
        let cache = try XCTUnwrap(CIWorker.cacheStore("micropod-ci-scoped-team-go-gobuild", activeContainers: 4))
        XCTAssertEqual(cache.store, "gobuild")
        XCTAssertEqual(cache.scope, "team-go")
        XCTAssertEqual(cache.activeContainers, 4)
    }

    func testWorkspaceUsesTheSamePhysicalPathAsDockerBindSources() throws {
        let directory = URL(fileURLWithPath: "/tmp/mp-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(try CIWorker.workspacePath(directory.path), "/private/tmp/" + directory.lastPathComponent)
        XCTAssertThrowsError(try CIWorker.workspacePath(directory.path, excluding: directory))
        XCTAssertThrowsError(try CIWorker.workspacePath("/"))
        XCTAssertThrowsError(try CIWorker.workspacePath("relative"))
    }

    func testLaunchAgentRunsTheStableBinaryInTheSpecifiedWorkerDirectory() throws {
        let root = URL(fileURLWithPath: "/Volumes/CI/Worker directory")
        let worker = CIWorker(environment: [
            "MICROPOD_CI_HOME": root.path, "MICROPOD_CI_CPUS": "6", "CI_JOB_ID": "example",
        ])
        let binary = URL(fileURLWithPath: "/Applications/Micropod.app/Contents/MacOS/micropod")
        let data = try worker.launchAgent(executable: binary)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [binary.path, "ci", "serve"])
        XCTAssertEqual(
            plist["EnvironmentVariables"] as? [String: String],
            ["MICROPOD_CI_HOME": root.path, "MICROPOD_CI_CPUS": "6"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["Crashed": true])
    }
}
