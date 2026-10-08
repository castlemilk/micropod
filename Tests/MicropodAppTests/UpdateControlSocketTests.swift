import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

/// Isolated real transport; no installed app, helper or live admission calls.
@MainActor
final class UpdateControlSocketTests: XCTestCase {
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
