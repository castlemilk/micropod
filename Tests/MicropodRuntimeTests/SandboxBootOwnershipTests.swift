import Foundation
import XCTest

@testable import MicropodRuntime

final class SandboxBootOwnershipTests: XCTestCase {
    func testLostCreateReplyCannotErasePendingPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let session = Session(
            id: "fixture", image: "fixture", options: .init(base: .image("fixture")), labels: [:],
            runDir: root.appendingPathComponent("fixture"))
        try await store.add(session)
        _ = try await store.beginBoot("fixture")
        do {
            try await store.remove("fixture", force: true)
            XCTFail("force deletion forgot an in-flight create")
        } catch {}
        do {
            try await store.stop("fixture", signal: nil)
            XCTFail("stop claimed an in-flight create was absent")
        } catch {}
        let retained = try await store.require("fixture")
        XCTAssertEqual(retained.state, .running)
    }
}
