import XCTest

@testable import MicropodCore

final class NotificationMatchTests: XCTestCase {
    func testPullSuccessAndFailure() {
        XCTAssertEqual(notificationKind(category: "images", message: "Pulled nginx:1.27"), .pulls)
        XCTAssertEqual(
            notificationKind(category: "images", message: "Failed to pull nginx:1.27: timeout"), .pulls)
    }

    func testBuildCategory() {
        XCTAssertEqual(notificationKind(category: "build", message: "Built my/app:latest"), .builds)
        XCTAssertEqual(
            notificationKind(category: "build", message: "Build failed for my/app: no space"), .builds)
    }

    func testComposeLifecycle() {
        XCTAssertEqual(notificationKind(category: "compose", message: "Up complete — stack (5 steps)"), .compose)
        XCTAssertEqual(notificationKind(category: "compose", message: "Up failed for stack: boom"), .compose)
        XCTAssertEqual(notificationKind(category: "compose", message: "Tore down stack"), .compose)
        XCTAssertEqual(notificationKind(category: "compose", message: "Down failed for stack: boom"), .compose)
    }

    func testPruneAcrossCategories() {
        XCTAssertEqual(
            notificationKind(category: "containers", message: "Pruned stopped containers — 3 removed"), .prune)
        XCTAssertEqual(
            notificationKind(category: "images", message: "Pruned images — 1.2 GB reclaimed"), .prune)
        XCTAssertEqual(
            notificationKind(category: "volumes", message: "Volume prune failed: in use"), .prune)
    }

    func testOrdinaryActivitiesAreNotNotificationWorthy() {
        XCTAssertNil(notificationKind(category: "containers", message: "Started web"))
        XCTAssertNil(notificationKind(category: "images", message: "Tagged a → b"))
        XCTAssertNil(notificationKind(category: "registries", message: "Logged in to ghcr.io"))
        XCTAssertNil(notificationKind(category: "system", message: "Runtime started"))
    }
}
