import Foundation
import XCTest

@testable import MicropodCore

@MainActor
final class RuntimeAdmissionTests: XCTestCase {
    func testClosedAdmissionPersistsAfterOwnerExitAndRequiresExactRecoveryOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RuntimeAdmission(root: root)
        let id = UUID()
        var fence: RuntimeMaintenanceFence? = try gate.begin(operation: id)
        XCTAssertThrowsError(try gate.claim("containerCreate"))
        try RuntimeAdmission.$maintenanceOwner.withValue(id) {
            XCTAssertNil(try gate.claim("containerCreate"))
        }
        try fence?.beginAction()
        fence = nil
        XCTAssertThrowsError(try gate.claim("containerCreate"))
        XCTAssertThrowsError(try gate.begin(operation: UUID(), recovering: true))
        let recovery = try gate.begin(operation: id, recovering: true)
        XCTAssertTrue(recovery.fence.actionStarted)
        try recovery.releaseAfterVerification()
    }

    func testPendingAndUncertainOperationsPreventMaintenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RuntimeAdmission(root: root)
        do {
            let setup = try gate.begin(operation: UUID())
            try setup.releaseAfterVerification()
        }
        var claim = try XCTUnwrap(gate.claim("containerCreate")) as RuntimeAdmissionClaim?
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        claim = nil  // process/transport loss does not clear pending intent
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        XCTAssertNil(claim)
    }

    func testDefiniteCompletionAllowsNewGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RuntimeAdmission(root: root)
        let first = try gate.begin(operation: UUID())
        let generation = first.fence.generation
        try first.releaseAfterVerification()
        let claim = try XCTUnwrap(gate.claim("containerCreate"))
        try claim.completed()
        // Release fd before attempting another process's shared lock.
        try RuntimeDurableFile.write(["test": true], to: root.appendingPathComponent("probe.json"))
        XCTAssertGreaterThan(generation, 0)
    }

    func testJournalReadsRejectLinksOversizeAndGenerationOverflow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        try RuntimeDurableFile.write(UInt64.max, to: target)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RuntimeDurableFile.read(link, maximumBytes: 4096))
        XCTAssertThrowsError(try RuntimeDurableFile.read(target, maximumBytes: 2))
        try RuntimeDurableFile.write(UInt64.max, to: root.appendingPathComponent("generation.json"))
        XCTAssertThrowsError(try RuntimeAdmission(root: root).begin(operation: UUID()))
    }
}
