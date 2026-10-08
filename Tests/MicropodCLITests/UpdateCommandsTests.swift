import XCTest

@testable import MicropodCLI

final class UpdateCommandsTests: XCTestCase {
    func testBlockedStagedUpdateDoesNotInviteUnsafeApply() {
        let line = UpdateCommands.appLine([
            "state": "readyToInstall", "currentVersion": "test-old", "downloadedVersion": "test-new",
            "restartBlockedReason": "admission unavailable",
        ])
        XCTAssertTrue(line.contains("test-new is downloaded"))
        XCTAssertTrue(line.contains("installation blocked: admission unavailable"))
        XCTAssertFalse(line.contains("micropod update apply"))
    }

    func testInformationCheckDoesNotClaimDownloadAndKeepsCheckFailure() {
        let available = UpdateCommands.appLine(["state": "updateAvailable", "availableVersion": "test-new"])
        XCTAssertTrue(available.contains("test-new is available"))
        XCTAssertFalse(available.contains("downloading"))
        let failed = UpdateCommands.appLine([
            "state": "error", "error": "feed unavailable", "restartBlockedReason": "admission unavailable",
        ])
        XCTAssertTrue(failed.contains("feed unavailable"))
        XCTAssertTrue(failed.contains("admission unavailable"))
        let recovery = UpdateCommands.appLine([
            "state": "error", "restartGuard": "recoveryRequired", "restartBlockedReason": "outcome unknown",
        ])
        XCTAssertTrue(recovery.contains("update recovery required"))
        XCTAssertFalse(recovery.contains("last check failed"))
    }
}
