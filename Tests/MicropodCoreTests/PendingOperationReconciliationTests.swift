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

    func testUncertainRuntimeCallIsRetainedAndBlocksWhileItsOwnerRuns() throws {
        // A runtime call — here an XPC route — may still be queued in Apple's
        // apiserver after its caller gave up.
        var claim = try XCTUnwrap(gate.claim("containerBootstrap", container: "c1")) as RuntimeAdmissionClaim?
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
            XCTAssertTrue(text.contains("containerBootstrap: owner running"), text)
        }
        XCTAssertEqual(pendingNames().count, 1, "an unproven receipt is never discarded")
    }

    func testLiveClaimStillBlocksMaintenance() throws {
        let claim = try XCTUnwrap(gate.claim("containerCreate"))
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        try claim.completed()
    }

    func testAnUncertainStartBlocksWhileItsClaimIsHeldAndIsRetiredOnceReleased() throws {
        var claim = try XCTUnwrap(gate.claim("native.start", container: "c1")) as RuntimeAdmissionClaim?
        try claim?.uncertain()
        // In flight: the claim is held, so maintenance cannot close the gate.
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        XCTAssertEqual(pendingNames().count, 1)
        claim = nil
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        XCTAssertEqual(try retiredRecords().first?.rule, .claimReleased)
    }

    // MARK: - Gamma-128, 2026-11-18

    /// The rig's receipts came from an older build — operation, route and
    /// pid only — and their owner, the long-lived dedicated API, was still
    /// running when restart was refused. native.start and native.create
    /// hold their claim for the whole operation, so once the gate is held
    /// exclusively they are retired; any live claim still blocks first.
    func testOldFormatStartReceiptsOfALiveAPIDoNotBlockMaintenance() throws {
        for _ in 0..<5 { try writeLegacy(route: "native.start", pid: getpid()) }
        try writeLegacy(route: "native.create", pid: getpid())
        // Genuinely in flight: maintenance waits for it.
        var inFlight = try XCTUnwrap(gate.claim("containerCreate")) as RuntimeAdmissionClaim?
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        XCTAssertEqual(pendingNames().count, 7, "nothing is judged while a claim is live")
        try inFlight?.completed()
        inFlight = nil
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        let retired = try retiredRecords()
        XCTAssertEqual(retired.count, 6)
        XCTAssertTrue(retired.allSatisfy { $0.rule == .claimReleased }, "\(retired.map(\.rule))")
        XCTAssertTrue(retired.allSatisfy { $0.reason.contains("owner still running") })
    }

    /// A runtime call's old-format receipt with a live owner cannot be
    /// proved dead: it still blocks, alone among the rig's receipts.
    func testOldFormatRuntimeCallOfALiveOwnerStillBlocks() throws {
        try writeLegacy(route: "native.start", pid: getpid())
        try writeLegacy(route: "containerBootstrap", pid: getpid())
        XCTAssertThrowsError(try gate.begin(operation: UUID())) { error in
            XCTAssertTrue(error.localizedDescription.contains("1× containerBootstrap: owner running"), "\(error)")
        }
        XCTAssertEqual(try retiredRecords().map(\.record?.route), ["native.start"])
        XCTAssertEqual(pendingNames().count, 1)
    }

    func testAPidThatStartedAfterAnOldReceiptIsAReusedPid() throws {
        let current = try XCTUnwrap(PendingRuntimeOperation.currentOwner)
        let started = Date(
            timeIntervalSince1970: TimeInterval(current.seconds) + TimeInterval(current.microseconds) / 1_000_000)
        let legacy = PendingRuntimeOperation(operation: UUID(), route: "containerCreate", pid: getpid())
        func owner(writtenAt: Date) -> PendingOwnerState {
            PendingOperationReconciliation.ownerState(legacy, writtenAt: writtenAt, bootSession: nil, bootTime: nil)
        }
        XCTAssertEqual(owner(writtenAt: started.addingTimeInterval(-60)), .exited)
        XCTAssertEqual(owner(writtenAt: started.addingTimeInterval(-1)), .running, "within the clock tolerance")
        XCTAssertEqual(owner(writtenAt: Date()), .running)
    }

    // MARK: - Reconciliation in begin

    func testRetiresAStartReceiptWhoseOwnerExited() throws {
        try writeRecord(route: "native.start", owner: exitedOwner(), createdAt: Date())
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        let retired = try retiredRecords()
        XCTAssertEqual(retired.count, 1)
        XCTAssertEqual(retired[0].rule, .claimReleased)
        XCTAssertFalse(retired[0].reason.contains("owner still running"), retired[0].reason)
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
        XCTAssertEqual(try retiredRecords().first?.rule, .ownerExited)
    }

    func testManagedAPIRequestsAreNotTreatedAsInProcessWork() throws {
        // A crashed API can strand a `container` child a request started.
        try writeRecord(route: "managed-api:/v1/k8s/start", owner: exitedOwner(), createdAt: Date())
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        XCTAssertEqual(pendingNames().count, 1)
    }

    func testRetiresAReceiptFromAnEarlierBoot() throws {
        var owner = try XCTUnwrap(PendingRuntimeOperation.currentOwner)
        owner = RuntimeProcessBirth(
            pid: owner.pid, uid: owner.uid, seconds: owner.seconds, microseconds: owner.microseconds,
            bootSession: "an-earlier-boot")
        try writeRecord(route: "containerBootstrap", owner: owner, createdAt: Date())
        try gate.begin(operation: UUID()).releaseAfterVerification()
        let retired = try retiredRecords()
        XCTAssertEqual(retired.first?.reason, "written before the current boot")
        XCTAssertEqual(retired.first?.rule, .earlierBoot)
    }

    func testRetiresAStaleReceiptForAnAbsentContainer() throws {
        let old = Date().addingTimeInterval(-stale - 30)
        try writeRecord(
            route: "containerCreate", owner: PendingRuntimeOperation.currentOwner, createdAt: old, container: "gone")
        let evidence = StaleOperationEvidence(observedAt: Date(), liveContainers: ["other"])
        try gate.begin(operation: UUID(), evidence: evidence).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        let retired = try retiredRecords()
        XCTAssertEqual(retired.first?.rule, .containerAbsent)
        XCTAssertTrue(retired.first?.reason.contains("container gone was absent") == true)
    }

    func testKeepsAStaleReceiptForAListedContainer() throws {
        let old = Date().addingTimeInterval(-stale - 30)
        try writeRecord(
            route: "containerDelete", owner: PendingRuntimeOperation.currentOwner, createdAt: old, container: "here")
        let evidence = StaleOperationEvidence(observedAt: Date(), liveContainers: ["here"])
        XCTAssertThrowsError(try gate.begin(operation: UUID(), evidence: evidence))
        XCTAssertEqual(pendingNames().count, 1)
    }

    func testOldFormatReceiptsFromBeforeThisBootAreRetired() throws {
        let live = try writeLegacy(route: "containerBootstrap", pid: getpid())
        XCTAssertThrowsError(try gate.begin(operation: UUID()))
        var times = [timeval(tv_sec: 1, tv_usec: 0), timeval(tv_sec: 1, tv_usec: 0)]
        XCTAssertEqual(utimes(live.path, &times), 0)
        try gate.begin(operation: UUID()).releaseAfterVerification()
        XCTAssertEqual(pendingNames(), [])
        XCTAssertEqual(try retiredRecords().first?.rule, .earlierBoot)
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
            PendingRuntimeOperation(operation: UUID(), route: route, pid: 1, container: container, outcome: outcome)
        }
        let fresh = StaleOperationEvidence(observedAt: now, liveContainers: ["listed"])
        let outdated = StaleOperationEvidence(
            observedAt: now.addingTimeInterval(-PendingOperationReconciliation.evidenceMaximumAge - 1),
            liveContainers: [])
        func rule(
            _ record: PendingRuntimeOperation, _ writtenAt: Date, _ owner: PendingOwnerState,
            _ evidence: StaleOperationEvidence? = nil, now at: Date? = nil
        ) -> PendingRetirement.Rule? {
            let verdict = PendingOperationReconciliation.verdict(
                record, writtenAt: writtenAt, owner: owner, evidence: evidence, now: at ?? now)
            if case .dead(let retirement) = verdict { return retirement.rule }
            return nil
        }
        // 1. definitive failure
        XCTAssertEqual(rule(record("containerCreate", outcome: .failed), young, .running), .failed)
        // 2. earlier boot, any route
        XCTAssertEqual(rule(record("containerCreate"), young, .earlierBoot), .earlierBoot)
        // 3. claim released: in-process work, whatever its owner
        for owner in [PendingOwnerState.running, .exited, .unknown] {
            XCTAssertEqual(rule(record("native.start"), young, owner), .claimReleased)
            XCTAssertEqual(rule(record("native.create"), young, owner), .claimReleased)
        }
        // 4. exited owner of work outside it: only after the bound
        for route in ["containerDelete", "managed-api:/v1/containers", "terminal", "container.start"] {
            XCTAssertNil(rule(record(route), young, .exited), route)
            XCTAssertEqual(rule(record(route), old, .exited), .ownerExited, route)
            XCTAssertNil(rule(record(route), old, .running), route)
            XCTAssertNil(rule(record(route), old, .unknown), route)
        }
        // 5. absent container: old enough, fresh listing, not listed
        let gone = record("containerDelete", container: "gone")
        XCTAssertEqual(rule(gone, old, .running, fresh), .containerAbsent)
        XCTAssertNil(rule(record("containerDelete", container: "listed"), old, .running, fresh))
        XCTAssertNil(rule(gone, young, .running, fresh))
        XCTAssertNil(rule(gone, old, .running, outdated))
        XCTAssertNil(rule(record("containerDelete"), old, .running, fresh))
        // The listing must have been requested at least the bound after the
        // operation began, not merely be fresh now.
        let justAfter = StaleOperationEvidence(observedAt: young.addingTimeInterval(1), liveContainers: [])
        XCTAssertNil(rule(gone, young, .running, justAfter, now: young.addingTimeInterval(2)))
    }

    func testRefusalGroupsWhatBlocks() {
        let text = PendingOperationReconciliation.describe([
            .init(route: "containerBootstrap", age: 300, why: "owner running"),
            .init(route: "containerBootstrap", age: 900, why: "owner running"),
            .init(route: "containerCreate", age: 5, why: "owner exited less than 10 min ago"),
        ])
        XCTAssertEqual(
            text,
            "2× containerBootstrap: owner running, oldest 15m; "
                + "1× containerCreate: owner exited less than 10 min ago, oldest 5s")
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

    /// A receipt as builds before this change wrote it: operation, route
    /// and pid only.
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
