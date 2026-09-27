import Foundation
import XCTest

@testable import MicropodCore

/// A stopped runtime is a *status*, not an error.
///
/// `container system status --format json` exits 1 with
/// `{"status":"unregistered"}` (or `"not running"`) on stdout and nothing on
/// stderr, while every apiserver-backed command fails with the CLI's
/// "XPC connection error" text. Drives the mock CLI's stopped mode
/// (`MICROPOD_MOCK_RUNTIME_STOPPED=1`, see `Support/mock-container`) so both
/// shapes stay locked in.
final class SystemStatusStoppedTests: XCTestCase {
    private var stateDir: URL!

    override func tearDown() {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    /// The checked-in mock lives with the integration tests; this target has
    /// no other CLI fixture.
    private static var mockScriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/MicropodCoreTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("MicropodIntegrationTests/Support/mock-container")
    }

    /// Wrapper that pins the mock's state dir + stopped mode — the CLI client
    /// copies `ProcessInfo.environment`, so `setenv` in-process is unreliable.
    private func makeStoppedClient() throws -> ContainerCLIClient {
        let script = Self.mockScriptURL
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw XCTSkip("mock container CLI missing or not executable at \(script.path)")
        }
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-stopped-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let wrapper = stateDir.appendingPathComponent("mock-container")
        let contents =
            "#!/bin/bash\n"
            + "export MICROPOD_MOCK_STATE_DIR=\"\(stateDir.path)\"\n"
            + "export MICROPOD_MOCK_RUNTIME_STOPPED=1\n"
            + "exec \"\(script.path)\" \"$@\"\n"
        try Data(contents.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return ContainerCLIClient(executableURL: wrapper)
    }

    func testStatusReportsStoppedInsteadOfThrowing() async throws {
        let client = try makeStoppedClient()
        let clock = ContinuousClock()
        let started = clock.now
        let status = try await SystemService(client: client).status()
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(status.status, "stopped")
        // `system version` is a local call — it still answers when the daemon is down.
        XCTAssertEqual(status.cliVersion, "1.2.3")
        XCTAssertEqual(status.apiServerVersion, "")
        XCTAssertEqual(status.appRoot, "")
        XCTAssertLessThan(elapsed, .seconds(5), "a stopped runtime must not wait out the CLI timeout")
    }

    /// Runtime-backed commands still fail — and classify as `unavailable`,
    /// not `internal`, so Connect clients know to back off and retry.
    func testRuntimeBackedCommandsFailAsUnavailable() async throws {
        let client = try makeStoppedClient()

        do {
            _ = try await ContainerService(client: client).list()
            XCTFail("list must fail while the runtime is stopped")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable", "\(error)")
        }

        do {
            _ = try await VolumeService(client: client).list()
            XCTFail("volume list must fail while the runtime is stopped")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable", "\(error)")
        }

        do {
            _ = try await SystemService(client: client).diskUsage()
            XCTFail("system df must fail while the runtime is stopped")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable", "\(error)")
        }
    }
}
