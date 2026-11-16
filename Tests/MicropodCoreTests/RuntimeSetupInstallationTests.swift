import Foundation
import XCTest

@testable import MicropodCore

final class RuntimeSetupInstallationTests: XCTestCase {
    func testPublishesVerifiedSetupOutsideDesktopAndNeverOverwritesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-setup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("desktop/Setup.app")
        let destination = root.appendingPathComponent("Applications/Setup.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("approved-source".utf8).write(to: source.appendingPathComponent("identity"))
        let verify: (URL) throws -> Void = { url in
            guard try Data(contentsOf: url.appendingPathComponent("identity")) == Data("approved-source".utf8) else {
                throw MicropodError.message("signature mismatch")
            }
        }
        let result = try RuntimeSetupInstallation.stage(source: source, destination: destination, verify: verify)
        XCTAssertEqual(result, destination)
        try Data("different-desktop".utf8).write(to: source.appendingPathComponent("identity"))
        XCTAssertEqual(
            try RuntimeSetupInstallation.stage(source: source, destination: destination, verify: verify), destination)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("identity")), Data("approved-source".utf8))
    }

    func testRejectedSignatureNeverPublishesOrReplacesASetupApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-setup-bad-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("Setup.app")
        XCTAssertThrowsError(
            try RuntimeSetupInstallation.stage(
                source: root.appendingPathComponent("untrusted.app"), destination: destination,
                verify: { _ in throw MicropodError.message("signature mismatch") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
