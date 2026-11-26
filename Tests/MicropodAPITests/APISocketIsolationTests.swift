import Foundation
import XCTest

/// Every test and script that runs a dev build of the API (or of the app,
/// whose agents start one) names its own socket in MICROPOD_API_SOCK, a
/// throwaway path or `off`. Without it the scratch API binds the owner's
/// ~/.micropod/api.sock beside the rig's API; MicropodAPI now refuses to
/// replace a live socket, and this keeps the launchers from relying on that.
final class APISocketIsolationTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let launchMarkers = [".build/debug/MicropodAPI", ".build/debug/MicropodApp"]

    func testEveryLauncherIsolatesTheAPISocket() throws {
        let fm = FileManager.default
        var launchers: [String] = []
        var unisolated: [String] = []
        for top in ["Tests", "scripts"] {
            let base = Self.repo.appendingPathComponent(top)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where ["swift", "sh", "py"].contains(url.pathExtension) {
                guard url.lastPathComponent != "APISocketIsolationTests.swift",
                    let text = try? String(contentsOf: url, encoding: .utf8),
                    Self.launchMarkers.contains(where: text.contains)
                else { continue }
                let relative = String(url.path.dropFirst(Self.repo.path.count + 1))
                launchers.append(relative)
                if !text.contains("MICROPOD_API_SOCK") { unisolated.append(relative) }
            }
        }
        XCTAssertTrue(
            launchers.contains("Tests/MicropodIntegrationTests/MicropodAPITests.swift"),
            "the scan finds the known launchers: \(launchers)")
        XCTAssertTrue(launchers.contains("scripts/e2e_runtimes.sh"), "\(launchers)")
        XCTAssertEqual(unisolated, [], "these run a dev API without MICROPOD_API_SOCK")
    }
}
