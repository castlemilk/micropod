import Foundation
import XCTest

@testable import MicropodApp

final class CICacheMeasurementsTests: XCTestCase {
    private let cacheA = String(repeating: "a", count: 64)
    private let cacheB = String(repeating: "b", count: 64)
    private let time = "2026-10-08T22:05:00.123456789Z"

    private func job(_ id: String, rig: String = "rig-a", cache: String? = nil, cost: Int? = 0) -> [String: Any] {
        var store: [String: Any] = [
            "cacheId": cache ?? cacheA, "volumeName": "cf-cache-example", "kind": "dep", "mountPath": "/cache/npm",
            "golden": "hit", "commit": "queued",
        ]
        if let cost { store["resolveMs"] = cost }
        return [
            "attemptId": id, "nodeId": "install", "runnerId": rig, "projectId": "project", "runId": "run",
            "observedAt": time, "report": ["stores": [store], "trust": "trusted"],
        ]
    }
    private func save(_ id: String, rig: String = "rig-a", outcome: String = "committed") -> [String: Any] {
        [
            "runnerId": rig, "projectId": "project", "runId": "run", "attemptId": id, "nodeId": "install",
            "observedAt": time,
            "save": [
                "cacheId": cacheA, "volumeName": "cf-cache-example", "containerId": "clone-\(id)", "outcome": outcome,
                "durationMs": 24, "allocatedBytes": 1024, "finishedAt": time,
            ],
        ]
    }
    private func decode(_ jobs: [[String: Any]] = [], saves: [[String: Any]] = []) throws -> CICacheTelemetry {
        try .decode(
            JSONSerialization.data(withJSONObject: ["ok": true, "metrics": [], "attempts": jobs, "saves": saves]),
            receivedAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testProducerAttributionAndMeasuredZeroResolutionRemainDistinctFromMissing() throws {
        let telemetry = try decode([job("zero"), job("unknown", cost: nil)])
        let zero = telemetry.attempts[0]
        XCTAssertEqual(zero.runnerId, "rig-a")
        XCTAssertEqual(zero.projectId, "project")
        XCTAssertEqual(zero.report.trust, "trusted")
        XCTAssertNotNil(zero.observationTime)
        XCTAssertEqual(zero.report.stores[0].cacheId, cacheA)
        XCTAssertEqual(zero.report.stores[0].resolveMs, 0)
        XCTAssertNil(telemetry.attempts[1].report.stores[0].resolveMs)
        XCTAssertEqual(CICacheDurationFormat.string(0), "0 ms")
        XCTAssertEqual(CICacheDurationFormat.string(nil), "Unknown")
        XCTAssertEqual(telemetry.jobReports(for: .init(project: "project")).count, 2)
        XCTAssertTrue(telemetry.jobReports(for: .init(project: "other")).isEmpty)
        XCTAssertTrue(
            telemetry.jobReports(for: .init(owner: "rig-a")).isEmpty, "Owner label cannot be equated to a rig ID")
    }

    func testLateSavesDeduplicateByRigAttemptCacheCloneAndFinish() throws {
        let event = save("job")
        let telemetry = try decode(saves: [event, event, save("job", rig: "rig-b")])
        XCTAssertEqual(telemetry.saveReports(for: .init()).count, 2)
        XCTAssertEqual(CICacheRecentActivity.observations(telemetry, selection: .init()).count, 2)
        XCTAssertEqual(telemetry.saveReports(for: .init(project: "project")).count, 2)
        XCTAssertTrue(telemetry.saveReports(for: .init(project: "other")).isEmpty)
    }

    func testUnknownSaveIsNeitherSuccessNorContentMissAndAllocationIsNotAcknowledged() throws {
        let telemetry = try decode([job("job")], saves: [save("job", outcome: "unknown")])
        let event = try XCTUnwrap(telemetry.saves.first)
        XCTAssertEqual(event.save.outcomeLabel, "Save outcome unknown; may have landed")
        XCTAssertNil(event.save.acknowledgedAllocation)
        XCTAssertEqual(telemetry.attempts[0].report.stores[0].commitDecision, "Save queued; completion unknown")
        let group = try XCTUnwrap(CICacheRecentActivity.observations(telemetry, selection: .init()).first)
        XCTAssertEqual(group.existing, 1, "Resolution reuse stays separate from content hits")
        XCTAssertEqual(group.saveCost, 24)
        XCTAssertEqual(group.resolutionCost, 0)
    }

    func testChangedKeysRigsAndDuplicateJobReportsRemainSeparated() throws {
        let telemetry = try decode([job("job"), job("job"), job("new-key", cache: cacheB), job("job", rig: "rig-b")])
        let groups = CICacheRecentActivity.observations(telemetry, selection: .init())
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.attemptIDs.count == 1 && $0.existing == 1 })
    }

    func testRestartOrRolloverEmptyWindowCannotEstablishUnusedCache() throws {
        let first = try decode([job("job")], saves: [save("job")])
        XCTAssertFalse(CICacheRecentActivity.observations(first, selection: .init()).isEmpty)
        let reset = try decode()
        XCTAssertTrue(reset.saveFeedAvailable)
        XCTAssertTrue(CICacheRecentActivity.observations(reset, selection: .init()).isEmpty)
        let legacy = try CICacheTelemetry.decode(
            Data(#"{"ok":true,"metrics":[],"attempts":[]}"#.utf8), receivedAt: Date())
        XCTAssertFalse(legacy.saveFeedAvailable)
        // Neither window supplies a generation, complete history or lease API.
        XCTAssertTrue(reset.attempts.isEmpty)
    }

    func testInvalidLateSaveDoesNotHideIndependentValidRecords() throws {
        var invalid = save("bad")
        invalid["save"] = [
            "cacheId": "not-an-identity", "containerId": "clone", "outcome": "committed", "durationMs": -1,
            "finishedAt": time,
        ]
        let telemetry = try decode([job("job")], saves: [invalid, save("job")])
        XCTAssertEqual(telemetry.invalidSaves, 1)
        XCTAssertEqual(telemetry.saves.count, 1)
        XCTAssertEqual(telemetry.saves[0].save.acknowledgedAllocation, 1024)
        XCTAssertEqual(telemetry.attempts.count, 1)
        XCTAssertThrowsError(try decode(saves: Array(repeating: save("job"), count: 129)))
        let negative = try decode([job("negative", cost: -1)])
        XCTAssertTrue(negative.attempts[0].report.invalidStores)
    }
}
