import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

/// Isolated real transport; no installed app, helper or live admission calls.
@MainActor
final class UpdateControlSocketTests: XCTestCase {
    func testConfigurationIsTypedAtomicAndReportsAutomaticPolicy() async throws {
        let keys = ["updates.installAutomatically", "updates.idleSeconds", "updates.channel"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let controller = UpdateController(feedConfigured: false)
        let socket = NSTemporaryDirectory() + "mp-config-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: socket, updateController: { controller })
        server.start()
        defer { server.stop() }
        try await waitUntil { FileManager.default.fileExists(atPath: socket) }
        let client = AppControlClient(socketPath: socket, requestTimeout: 2)
        let report = try await client.call(
            "update.configure", params: ["automaticInstallation": false, "idleSeconds": 12])
        XCTAssertEqual(report["automaticInstallation"] as? Bool, false)
        XCTAssertEqual(report["automaticIdleSeconds"] as? Double, 12)
        do {
            _ = try await client.call(
                "update.configure", params: ["automaticInstallation": true, "channel": "untrusted-url"])
            XCTFail("Unknown channels must fail before changing a preference")
        } catch AppControlError.callFailed {}
        XCTAssertFalse(controller.installsAutomatically)
        do {
            _ = try await client.call("update.configure", params: ["automaticInstallation": "yes"])
            XCTFail("Strings must not be coerced to booleans")
        } catch AppControlError.callFailed {}
        XCTAssertFalse(controller.installsAutomatically)
    }

    func testBlockedApplyAndStatusSurviveRealControlSocketRoundTrip() async throws {
        let controller = UpdateController(feedConfigured: false)
        var installs = 0
        controller.stageUpdate(version: "test-version", handler: { installs += 1 })
        let socket = NSTemporaryDirectory() + "mp-update-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: socket, updateController: { controller })
        server.start()
        defer { server.stop() }
        try await waitUntil { FileManager.default.fileExists(atPath: socket) }
        let client = AppControlClient(socketPath: socket, requestTimeout: 2)
        let report = try await client.updateStatus()
        XCTAssertEqual(report["state"] as? String, "readyToInstall")
        XCTAssertEqual(report["restartGuard"] as? String, "unavailable")
        XCTAssertEqual(report["restartBlockedReason"] as? String, UpdateRestartGuard.unavailableReason)
        do {
            _ = try await client.applyUpdate()
            XCTFail("An unsupported production guard must refuse apply")
        } catch AppControlError.callFailed(let message) {
            XCTAssertEqual(message, UpdateRestartGuard.unavailableReason)
        }
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(controller.status, .readyToInstall)
    }
}
