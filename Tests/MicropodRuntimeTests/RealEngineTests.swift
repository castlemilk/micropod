import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Live engine round trips. Gated behind `MICROPOD_REAL_E2E=1`; each engine
/// skips itself when unavailable (no Docker daemon; an xctest process
/// without com.apple.security.virtualization for the sandbox).
///
/// Run: MICROPOD_REAL_E2E=1 swift test --filter RealEngineTests
final class RealEngineTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MICROPOD_REAL_E2E"] == "1",
            "set MICROPOD_REAL_E2E=1 to run live engine tests")
    }

    func testDockerLifecycle() async throws {
        let docker = DockerEngine(endpoint: nil)
        let probe = await docker.probe()
        try XCTSkipUnless(probe.available, "docker unavailable: \(probe.reason)")

        let name = "mp-engine-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        let id = try await docker.run(
            ContainerRunRequest(
                image: "alpine:3.20", name: name, env: ["GREETING=hi"],
                arguments: ["sh", "-c", "echo $GREETING-log; sleep 60"]))
        addTeardownBlock { try? await docker.delete(id, force: true) }
        XCTAssertEqual(id, name)

        let listed = try await docker.list().first { $0.id == name }
        XCTAssertEqual(listed?.state, "running")
        XCTAssertEqual(listed?.runtime, "docker")
        let ownsIt = await docker.owns(name)
        let ownsOther = await docker.owns("definitely-not-\(name)")
        XCTAssertTrue(ownsIt)
        XCTAssertFalse(ownsOther)

        let ok = try await docker.execDetailed(ContainerExecRequest(containerID: name, arguments: ["echo", "out"]))
        XCTAssertEqual(ok.output, "out\n")
        let failed = try await docker.execDetailed(
            ContainerExecRequest(containerID: name, arguments: ["sh", "-c", "echo o; echo e >&2; exit 3"]))
        XCTAssertEqual(failed.exitCode, 3)
        XCTAssertEqual(failed.output, "o\n")
        XCTAssertEqual(failed.error, "e\n")

        try await Task.sleep(for: .milliseconds(500))
        let lines = try await docker.tail(id: name, lines: 10, boot: false).map(\.text)
        XCTAssertEqual(lines, ["hi-log"])

        try await docker.stop(name, timeout: 1)
        let exited = try await docker.list().first { $0.id == name }
        XCTAssertEqual(exited?.state, "exited")
        try await docker.delete(name, force: false)
        let deleted = try await docker.list().first { $0.id == name }
        XCTAssertNil(deleted)
    }

    func testSandboxLifecycle() async throws {
        let engine = SandboxEngine(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("sbx-e2e-\(UUID())"))
        let probe = await engine.probe()
        try XCTSkipUnless(probe.available, "sandbox unavailable: \(probe.reason)")

        let id = try await engine.run(
            ContainerRunRequest(
                image: "alpine:3.20", labels: [LabelSpec(key: SandboxEngine.networkLabel, value: "none")],
                arguments: ["sh", "-c", "echo booted; sleep 60"]))
        addTeardownBlock { try? await engine.delete(id, force: true) }
        let running = try await engine.list().first { $0.id == id }
        XCTAssertEqual(running?.state, "running")

        let result = try await engine.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["sh", "-c", "ls /sys/class/net; exit 2"]))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.output, "lo\n", "networkLabel=none boots without eth0")

        let lines = try await engine.tail(id: id, lines: 5, boot: false).map(\.text)
        XCTAssertEqual(lines, ["booted"])

        try await engine.stop(id, timeout: 1)
        let stopped = try await engine.list().first { $0.id == id }
        XCTAssertEqual(stopped?.state, "stopped")
        XCTAssertEqual(stopped?.exitCode, "137")
        do {
            try await engine.start(id)
            XCTFail("sandboxes are ephemeral")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
        }
        try await engine.delete(id, force: false)
        let gone = await engine.owns(id)
        XCTAssertFalse(gone)
    }
}
