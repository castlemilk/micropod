import Foundation
import Synchronization
import XCTest
import vmnet

@testable import MicropodRuntime

final class SandboxBootOwnershipTests: XCTestCase {
    final class PendingNetwork: SandboxNetworkCleanup, @unchecked Sendable {
        private let stopConfirmation = SandboxNetworkStopConfirmation(timeout: .milliseconds(0))
        private let callback = Mutex<(@Sendable (vmnet_return_t) -> Void)?>(nil)
        private let calls = Mutex(0)

        var issuedStops: Int { calls.withLock { $0 } }

        func stop() throws {
            try stopConfirmation.stop { complete in
                calls.withLock { $0 += 1 }
                callback.withLock { $0 = complete }
                return .VMNET_SUCCESS
            }
        }

        func confirmStop() { callback.withLock { $0 }?(.VMNET_SUCCESS) }
    }

    func testPreparationFailureRetainsNetworkUntilStopIsConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let runDir = root.appendingPathComponent("fixture")
        var session = Session(
            id: "fixture", image: "fixture", options: .init(base: .image("fixture")), labels: [:], runDir: runDir)
        session.state = .running
        try await store.add(session)
        let network = PendingNetwork()
        await store.ownPreparationNetwork("fixture", network)
        await store.recordBootFailure("fixture")

        do {
            try await store.remove("fixture", force: true)
            XCTFail("delete acknowledged an unconfirmed network stop")
        } catch {}
        let retained = try await store.require("fixture")
        XCTAssertEqual(retained.state, .running)
        XCTAssertNil(retained.exitCode)
        XCTAssertNotNil(retained.preparationNetwork)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.path))
        XCTAssertEqual(network.issuedStops, 1)

        network.confirmStop()
        try await store.remove("fixture", force: true)
        let removed = await store.session("fixture")
        XCTAssertNil(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir.path))
        XCTAssertEqual(network.issuedStops, 1, "late confirmation must not replay network teardown")
    }

    func testPreparationFailureWithoutResourcesCanBeRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        var session = Session(
            id: "fixture", image: "fixture", options: .init(base: .image("fixture")), labels: [:],
            runDir: root.appendingPathComponent("fixture"))
        session.state = .running
        try await store.add(session)
        await store.recordBootFailure("fixture")
        let failed = try await store.require("fixture")
        XCTAssertEqual(failed.state, .exited)
        XCTAssertEqual(failed.exitCode, -1)
        try await store.remove("fixture", force: false)
        let removed = await store.session("fixture")
        XCTAssertNil(removed)
    }

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
