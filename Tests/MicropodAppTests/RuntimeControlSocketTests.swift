import Foundation
import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodApp

private struct SocketRuntimeDriver: RuntimeLifecycleDriving {
    func stage(root: URL) async throws -> ManagedRuntimeReceipt {
        .init(
            selection: .init(
                version: AppleRuntimeRelease.supported.version,
                packageSHA256: AppleRuntimeRelease.supported.packageSHA256, incarnation: UUID()),
            files: AppleRuntimeRelease.payloadSHA256)
    }
    func verifyStaged(_ receipt: ManagedRuntimeReceipt, root: URL) async throws {
        XCTFail("Unqualified runtime cannot reach verification")
    }
    func assertIdle(executable: URL) async throws { XCTFail("Unqualified runtime cannot reach maintenance") }
    func status(executable: URL) async throws -> String {
        XCTFail("Unqualified runtime cannot reach status mutation")
        return "running"
    }
    func stop(executable: URL) async throws { XCTFail("Shared service was stopped") }
    func start(executable: URL) async throws { XCTFail("Shared service was started") }
    func verify(executable: URL, installRoot: URL, stopped: Bool) async throws {
        XCTFail("Unqualified runtime cannot reach activation")
    }
}
private struct SocketOfflineRig: RuntimeRigCoordinating {
    func transition(operation: UUID, action: String, installRoot: URL, localGeneration: UInt64, targetState: String)
        async throws -> RuntimeRigReceipt?
    {
        throw RuntimeRigAdmissionError.unavailable("Fixture coordinator is offline")
    }
}
@MainActor
final class RuntimeControlSocketTests: XCTestCase {
    func testManagedOperationProgressAndRefusalUseRealAppControlSocket() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mp-runtime-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ManagedRuntimeController(
            manager: RuntimeLifecycleManager(root: root, rig: SocketOfflineRig(), driver: SocketRuntimeDriver()))
        let socket = root.appendingPathComponent("control.sock").path
        let server = AppControlServer(socketPath: socket, runtimeController: { controller })
        server.start()
        defer { server.stop() }
        try await waitUntil { FileManager.default.fileExists(atPath: socket) }
        let client = AppControlClient(socketPath: socket, requestTimeout: 2)
        let initial = try await client.call("runtime.status")
        XCTAssertEqual(initial["phase"] as? String, "idle")
        _ = try await client.call("runtime.install")
        var report: [String: Any] = [:]
        for _ in 0..<100 {
            report = try await client.call("runtime.status")
            if report["phase"] as? String == "blocked" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(report["phase"] as? String, "blocked")
        XCTAssertEqual(report["error"] as? String, "Fixture coordinator is offline")
        XCTAssertNotNil(report["id"] as? String)
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
        XCTAssertFalse(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
        _ = try await client.call("runtime.recover")
        for _ in 0..<100 {
            report = try await client.call("runtime.status")
            if report["phase"] as? String == "cancelled" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(report["phase"] as? String, "cancelled")
    }
}
