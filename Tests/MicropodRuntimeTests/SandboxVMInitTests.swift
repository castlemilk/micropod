import Foundation
import XCTest

@testable import MicropodRuntime

/// The sandbox boots the `vminit` matching the Containerization release it
/// links, when the store has several (an upgraded `container` adds its own).
final class SandboxVMInitTests: XCTestCase {
    private let linked = "ghcr.io/apple/containerization/vminit:0.42.0"
    private let newer = "ghcr.io/apple/containerization/vminit:0.47.0"

    func testPrefersTheLinkedVMInit() {
        XCTAssertEqual(SandboxVM.pickVMInit([newer, "docker.io/library/alpine:3.20", linked]), linked)
        XCTAssertEqual(SandboxVM.pickVMInit([linked, newer]), linked)
    }

    func testFallsBackToAnyVMInit() {
        XCTAssertEqual(SandboxVM.pickVMInit(["docker.io/library/alpine:3.20", newer]), newer)
        XCTAssertNil(SandboxVM.pickVMInit(["docker.io/library/alpine:3.20"]))
        XCTAssertNil(SandboxVM.pickVMInit([]))
    }

    /// `linkedContainerizationVersion` is the version Package.swift pins.
    func testLinkedVersionMatchesPackageSwift() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let text = try String(contentsOf: package, encoding: .utf8)
        XCTAssertTrue(
            text.contains(
                #"containerization.git", exact: "\#(SandboxVM.linkedContainerizationVersion)""#),
            "Package.swift pins another Containerization release than SandboxVM.linkedContainerizationVersion")
    }
}
