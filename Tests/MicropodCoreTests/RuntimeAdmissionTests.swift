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

    // Gamma-128GB (2026-11-18): the generation advanced only when a fence
    // was taken, so three unfenced restarts in a row were all issued 25, and
    // the rig coordinator refused each one as not newer than the last.
    func testEveryIssuedGenerationIsNewEvenWithoutAFence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RuntimeAdmission(root: root)
        let fenced = try gate.begin(operation: UUID())
        try fenced.releaseAfterVerification()
        XCTAssertEqual(fenced.fence.generation, 1)

        let abandoned = try gate.issueGeneration(operation: UUID())
        let refused = try gate.issueGeneration(operation: UUID())
        XCTAssertEqual([abandoned, refused], [2, 3], "an operation that never fenced still used its generation")

        let started = UUID()
        let issued = try gate.issueGeneration(operation: started)
        let fence = try gate.begin(operation: started)
        XCTAssertEqual(fence.fence.generation, issued, "the fence keeps the generation the operation was issued")
        try fence.releaseAfterVerification()
        XCTAssertEqual(try gate.nextGeneration(), issued + 1)

        // An operation fenced without being issued still gets a fresh one.
        let unissued = try gate.begin(operation: UUID())
        XCTAssertEqual(unissued.fence.generation, issued + 1)
        try unissued.releaseAfterVerification()
        // Once something newer moved the counter, the old issue cannot fence.
        let stale = UUID()
        _ = try gate.issueGeneration(operation: stale)
        _ = try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertThrowsError(try gate.begin(operation: stale))
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
