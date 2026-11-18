import Darwin
import Foundation
import XCTest

@testable import MicropodCore

/// Leftover admission receipts: which ones maintenance may retire, and that
/// everything it cannot prove dead still blocks it.
final class PendingOperationReconciliationTests: XCTestCase {
    private var root: URL!
    private var gate: RuntimeAdmission!
    private let stale = PendingOperationReconciliation.staleOperationAge

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        gate = RuntimeAdmission(root: root)
        // Enrol, so claims write receipts.
        try gate.begin(operation: UUID()).releaseAfterVerification()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Settlement at the source

    func testDefinitiveFailureSettlesTheReceipt() throws {
        var claim = try XCTUnwrap(gate.claim("native.start", container: "c1")) as RuntimeAdmissionClaim?
        try claim?.settle(after: MicropodError.message("internalError: bootstrap failed"))
        claim = nil
        XCTAssertEqual(pendingNames(), [])
        try gate.begin(operation: UUID()).releaseAfterVerification()
    }

    func testFailureBeforeTheRuntimeSettlesEvenWhenCancelled() throws {
        var claim = try XCTUnwrap(gate.claim("native.start", container: "c1")) as RuntimeAdmissionClaim?
        try claim?.settle(after: CancellationError(), reachedRuntime: false)
        claim = nil
        XCTAssertEqual(pendingNames(), [])
    }

    func testUncertainOutcomeIsRetainedAndBlocksWhileItsOwnerRuns() throws {
        var claim = try XCTUnwrap(gate.claim("native.start", container: "c1")) as RuntimeAdmissionClaim?
        try claim?.settle(
            after: MicropodError.message("deadlineExceeded: XPC timeout for apiserver/containerBootstrap"))
        claim = nil
        let record = try onlyRecord()
        XCTAssertEqual(record.outcome, .uncertain)
        XCTAssertEqual(record.container, "c1")
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.owner, PendingRuntimeOperation.currentOwner)
        XCTAssertThrowsError(try gate.begin(operation: UUID())) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Runtime has pending or uncertain operations; maintenance is blocked"), text)
            XCTAssertTrue(text.contains("native.start: owner running"), text)
        }
        XCTAssertEqual(pendingNames().count, 1, "an unproven receipt is never discarded")
    }

    func testLiveClaimStillBlocksMaintenance() throws {
        let claim = try XCTUnwrap(gate.claim("containerCreate"))
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        try claim.completed()
    }

    // MARK: - Reconciliation in begin

    func testRetiresAnInProcessReceiptWhoseOwnerExited() throws {
        try writeRecord(route: "native.start", owner: exitedOwner(), createdAt: Date())
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        let retired = try retiredRecords()
        XCTAssertEqual(retired.count, 1)
        XCTAssertTrue(retired[0].reason.contains("owner process exited"), retired[0].reason)
        XCTAssertEqual(retired[0].record?.route, "native.start")
    }

    func testRuntimeCallOfAnExitedOwnerWaitsForTheBound() throws {
        // Apple's apiserver may still run a request its dead client queued.
        try writeRecord(route: "containerCreate", owner: exitedOwner(), createdAt: Date().addingTimeInterval(-60))
        XCTAssertThrowsError(try gate.begin(operation: UUID())) { error in
            XCTAssertTrue(error.localizedDescription.contains("owner exited less than 10 min ago"), "\(error)")
        }
        try FileManager.default.removeItem(at: pending)
        try writeRecord(
            route: "containerCreate", owner: exitedOwner(), createdAt: Date().addingTimeInterval(-stale - 1))
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
    }

    func testRetiresAReceiptFromAnEarlierBoot() throws {
        var owner = try XCTUnwrap(PendingRuntimeOperation.currentOwner)
        owner = RuntimeProcessBirth(
            pid: owner.pid, uid: owner.uid, seconds: owner.seconds, microseconds: owner.microseconds,
            bootSession: "an-earlier-boot")
        try writeRecord(route: "containerBootstrap", owner: owner, createdAt: Date())
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(try retiredRecords().first?.reason, "written before the current boot")
    }

    func testRetiresAStaleReceiptForAnAbsentContainer() throws {
        let old = Date().addingTimeInterval(-stale - 30)
        try writeRecord(
            route: "native.start", owner: PendingRuntimeOperation.currentOwner, createdAt: old, container: "gone")
        let evidence = StaleOperationEvidence(observedAt: Date(), liveContainers: ["other"])
        try gate.begin(operation: UUID(), evidence: evidence).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        XCTAssertTrue(try retiredRecords()[0].reason.contains("container gone was absent"))
    }

    func testKeepsAStaleReceiptForAListedContainer() throws {
        let old = Date().addingTimeInterval(-stale - 30)
        try writeRecord(
            route: "native.start", owner: PendingRuntimeOperation.currentOwner, createdAt: old, container: "here")
        let evidence = StaleOperationEvidence(observedAt: Date(), liveContainers: ["here"])
        XCTAssertThrowsError(try gate.begin(operation: UUID(), evidence: evidence))
        XCTAssertEqual(pendingNames().count, 1)
    }

    func testLegacyReceiptsAreJudgedByPidAndFileTime() throws {
        // Older builds wrote {operation, route, pid} only.
        let live = try writeLegacy(route: "native.start", pid: getpid())
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        // Before this boot: retired whatever its pid.
        var times = [timeval(tv_sec: 1, tv_usec: 0), timeval(tv_sec: 1, tv_usec: 0)]
        XCTAssertEqual(utimes(live.path, &times), 0)
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        XCTAssertEqual(try retiredRecords().first?.reason, "written before the current boot")
    }

    func testRetiresAnIncompleteReceiptWriteAndBlocksAnUnrecognisedEntry() throws {
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: pending.appendingPathComponent(".intent-" + UUID().uuidString))
        try Data("x".utf8).write(to: pending.appendingPathComponent("not-a-receipt"))
        XCTAssertThrowsError(try gate.begin(operation: UUID())) { error in
            XCTAssertTrue(error.localizedDescription.contains("unrecognised entry"), "\(error)")
        }
        XCTAssertEqual(pendingNames(), ["not-a-receipt"])
    }

    func testReconciledAuditIsBounded() throws {
        let reconciled = root.appendingPathComponent("reconciled")
        for _ in 0..<(PendingOperationReconciliation.retainedReconciledReceipts + 3) {
            try writeRecord(route: "native.create", owner: exitedOwner(), createdAt: Date())
        }
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: reconciled.path).count,
            PendingOperationReconciliation.retainedReconciledReceipts)
    }

    // MARK: - The rules

    func testVerdictTable() throws {
        let now = Date()
        let young = now.addingTimeInterval(-30)
        let old = now.addingTimeInterval(-stale - 1)
        func record(_ route: String, container: String? = nil, outcome: PendingRuntimeOperation.Outcome? = nil)
            -> PendingRuntimeOperation
        {
            PendingRuntimeOperation(
                operation: UUID(), route: route, pid: 1, container: container, outcome: outcome)
        }
        let fresh = StaleOperationEvidence(observedAt: now, liveContainers: ["listed"])
        let outdated = StaleOperationEvidence(
            observedAt: now.addingTimeInterval(-PendingOperationReconciliation.evidenceMaximumAge - 1),
            liveContainers: [])
        typealias R = PendingOperationReconciliation
        func dead(_ verdict: PendingOperationVerdict) -> Bool {
            if case .dead = verdict { return true }
            return false
        }
        // 1. definitive failure
        XCTAssertTrue(
            dead(R.verdict(record("x", outcome: .failed), writtenAt: young, owner: .running, evidence: nil, now: now)))
        // 2. earlier boot, any route
        XCTAssertTrue(
            dead(R.verdict(record("containerCreate"), writtenAt: young, owner: .earlierBoot, evidence: nil, now: now)))
        // 3. exited owner: in-process at once, runtime calls after the bound
        XCTAssertTrue(
            dead(
                R.verdict(
                    record("managed-api:/v1/containers"), writtenAt: young, owner: .exited, evidence: nil, now: now)))
        XCTAssertFalse(dead(R.verdict(record("terminal"), writtenAt: young, owner: .exited, evidence: nil, now: now)))
        XCTAssertFalse(
            dead(R.verdict(record("containerDelete"), writtenAt: young, owner: .exited, evidence: nil, now: now)))
        XCTAssertTrue(
            dead(R.verdict(record("containerDelete"), writtenAt: old, owner: .exited, evidence: nil, now: now)))
        XCTAssertFalse(
            dead(R.verdict(record("native.start"), writtenAt: old, owner: .running, evidence: nil, now: now)))
        XCTAssertFalse(
            dead(R.verdict(record("native.start"), writtenAt: old, owner: .unknown, evidence: nil, now: now)))
        // 4. absent container: old enough, fresh listing, not listed
        XCTAssertTrue(
            dead(
                R.verdict(
                    record("native.start", container: "gone"), writtenAt: old, owner: .running, evidence: fresh,
                    now: now)))
        XCTAssertFalse(
            dead(
                R.verdict(
                    record("native.start", container: "listed"), writtenAt: old, owner: .running, evidence: fresh,
                    now: now)))
        XCTAssertFalse(
            dead(
                R.verdict(
                    record("native.start", container: "gone"), writtenAt: young, owner: .running, evidence: fresh,
                    now: now)))
        XCTAssertFalse(
            dead(
                R.verdict(
                    record("native.start", container: "gone"), writtenAt: old, owner: .running, evidence: outdated,
                    now: now)))
        XCTAssertFalse(
            dead(R.verdict(record("native.start"), writtenAt: old, owner: .running, evidence: fresh, now: now)))
        // The listing must have been requested at least the bound after the
        // operation began, not merely be fresh now.
        let justAfter = StaleOperationEvidence(observedAt: young.addingTimeInterval(1), liveContainers: [])
        XCTAssertFalse(
            dead(
                R.verdict(
                    record("native.start", container: "gone"), writtenAt: young, owner: .running, evidence: justAfter,
                    now: young.addingTimeInterval(2))))
    }

    func testRefusalGroupsWhatBlocks() {
        let text = PendingOperationReconciliation.describe([
            .init(route: "native.start", age: 300, why: "owner running"),
            .init(route: "native.start", age: 900, why: "owner running"),
            .init(route: "containerCreate", age: 5, why: "owner exited less than 10 min ago"),
        ])
        XCTAssertEqual(
            text,
            "2× native.start: owner running, oldest 15m; 1× containerCreate: owner exited less than 10 min ago, oldest 5s"
        )
    }

    // MARK: - Helpers

    private var pending: URL { root.appendingPathComponent("pending") }

    private func pendingNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: pending.path)) ?? []).sorted()
    }

    private func onlyRecord() throws -> PendingRuntimeOperation {
        let names = pendingNames()
        XCTAssertEqual(names.count, 1)
        return try JSONDecoder().decode(
            PendingRuntimeOperation.self, from: Data(contentsOf: pending.appendingPathComponent(names[0])))
    }

    private func retiredRecords() throws -> [RetiredPendingOperation] {
        let reconciled = root.appendingPathComponent("reconciled")
        return try FileManager.default.contentsOfDirectory(at: reconciled, includingPropertiesForKeys: nil).map {
            try JSONDecoder().decode(RetiredPendingOperation.self, from: Data(contentsOf: $0))
        }
    }

    /// This process's pid with another start time: a process that has
    /// since exited, its pid reused.
    private func exitedOwner() throws -> RuntimeProcessBirth {
        let current = try XCTUnwrap(PendingRuntimeOperation.currentOwner)
        return RuntimeProcessBirth(
            pid: current.pid, uid: current.uid, seconds: 1, microseconds: 0, bootSession: current.bootSession)
    }

    private func writeRecord(
        route: String, owner: RuntimeProcessBirth?, createdAt: Date, container: String? = nil,
        outcome: PendingRuntimeOperation.Outcome? = .uncertain
    ) throws {
        let operation = UUID()
        try RuntimeDurableFile.write(
            PendingRuntimeOperation(
                operation: operation, route: route, pid: owner?.pid ?? getpid(), owner: owner, createdAt: createdAt,
                container: container, outcome: outcome, endedAt: outcome == nil ? nil : createdAt),
            to: pending.appendingPathComponent(operation.uuidString + ".json"))
    }

    @discardableResult
    private func writeLegacy(route: String, pid: Int32) throws -> URL {
        struct Legacy: Encodable {
            let operation: UUID
            let route: String
            let pid: Int32
        }
        let operation = UUID()
        let url = pending.appendingPathComponent(operation.uuidString + ".json")
        try RuntimeDurableFile.write(Legacy(operation: operation, route: route, pid: pid), to: url)
        return url
    }
}
