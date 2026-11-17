import Foundation
import MicropodCore
import Sparkle
import XCTest

@testable import MicropodApp

/// After the receipt records a rejected guarded download, the reported
/// status must not contradict itself: "up to date" never names an
/// available version.
@MainActor
final class UpdateRejectedDownloadStatusTests: XCTestCase {
    private func offeredController() async throws -> UpdateController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-rejected-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = UpdateController(feedConfigured: false, store: .init(root: root))
        controller.updater(controller.controller.updater, didFindValidUpdate: SUAppcastItem.empty())
        for _ in 0..<200 where controller.status != .updateAvailable { await Task.yield() }
        XCTAssertEqual(controller.status, .updateAvailable)
        XCTAssertNotNil(controller.availableVersion)
        return controller
    }

    func testNothingInstallableWithdrawsTheOfferInsteadOfContradictingIt() async throws {
        let controller = try await offeredController()
        controller.settleRejectedDownload(failure: nil)
        XCTAssertEqual(controller.status, .upToDate)
        XCTAssertNil(controller.availableVersion)
        let report = controller.statusReport
        XCTAssertEqual(report["state"] as? String, "upToDate")
        XCTAssertNil(report["availableVersion"])
        XCTAssertEqual(UpdateStateResolver.desktop(report: report).kind, .current)
        XCTAssertEqual(UpdateStateResolver.desktop(report: report).availableVersion, "")
    }

    func testFailedDownloadKeepsTheOfferBesideItsError() async throws {
        let controller = try await offeredController()
        controller.settleRejectedDownload(failure: "The update archive failed validation")
        XCTAssertEqual(controller.status, .error)
        XCTAssertNotNil(controller.availableVersion)
        let report = controller.statusReport
        XCTAssertEqual(report["state"] as? String, "error")
        XCTAssertEqual(report["error"] as? String, "The update archive failed validation")
        XCTAssertNotNil(report["availableVersion"])
    }
}
