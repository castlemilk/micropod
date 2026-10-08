import Foundation
import XCTest

@testable import MicropodApp

final class CICacheHistoryTests: XCTestCase {
    func testVersionCoverageAndValidJSONByteBound() throws {
        let valid = try historyPage(events: [])
        XCTAssertFalse(valid.complete)
        XCTAssertEqual(
            try historyPage(events: [], pending: 130).pendingRecords, 130,
            "Concurrent producer enqueuers can transiently exceed queue plus in-flight count")
        for field in ["schemaVersion", "complete", "leaseCoverage"] {
            var object = historyObject(events: [])
            object[field] = field == "complete" ? true : "unsupported"
            XCTAssertThrowsError(try CICacheHistoryPage.decode(JSONSerialization.data(withJSONObject: object)))
        }
        let prefix = Data("{\"padding\":\"".utf8)
        let suffix = Data(
            ("\",\"schema\":0,"
                + String(data: try JSONSerialization.data(withJSONObject: historyObject(events: [])), encoding: .utf8)!
                .dropFirst()).utf8)
        for count in [CICacheHistoryPage.byteLimit - 1, CICacheHistoryPage.byteLimit] {
            let data = prefix + Data(repeating: 120, count: count - prefix.count - suffix.count) + suffix
            XCTAssertEqual(data.count, count)
            XCTAssertNoThrow(try CICacheHistoryPage.decode(data))
        }
        let tooLarge =
            prefix + Data(repeating: 120, count: CICacheHistoryPage.byteLimit + 1 - prefix.count - suffix.count)
            + suffix
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: tooLarge) as? [String: Any])
        XCTAssertThrowsError(try CICacheHistoryPage.decode(tooLarge))
        XCTAssertThrowsError(try historyPage(events: (1...129).map { historyEvent(UInt64($0)) }))
    }

    func testCursorAndCuratedFactsSurviveObserverRestartWithoutEnvironment() async throws {
        let storage = HistoryMemoryPersistence()
        var event = historyEvent(1, kind: "attempt")
        var attempt = event["attempt"] as! [String: Any]
        var report = attempt["report"] as! [String: Any]
        report["env"] = ["PRIVATE_TEST": "ENV_SENTINEL"]
        attempt["report"] = report
        event["attempt"] = attempt
        let firstReader = HistoryScriptReader([try historyPage(events: [event])])
        let first = await CICacheHistoryConsumer(reader: firstReader, persistence: storage).read()
        XCTAssertEqual(first.state.after, 1)
        XCTAssertTrue(first.persisted)
        XCTAssertEqual(first.telemetry.attempts.first?.report.stores.first?.resolveMs, 0)
        let awaited1 = await storage.value()
        let data = try XCTUnwrap(awaited1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("ENV_SENTINEL"))
        let nextReader = HistoryScriptReader([try historyPage(events: [historyEvent(2, kind: "save")], last: 2)])
        let second = await CICacheHistoryConsumer(reader: nextReader, persistence: storage).read()
        let awaited2 = await nextReader.requests()
        XCTAssertEqual(awaited2, [1])
        XCTAssertEqual(second.state.events.count, 2)
        XCTAssertEqual(second.state.after, 2)
        XCTAssertEqual(second.telemetry.saves.first?.save.acknowledgedAllocation, 17)
        XCTAssertEqual(second.retentionBlockers.count, 2)
    }

    func testBoundedTraversalCapturesFirstUpperSequenceAndResumes() async throws {
        let reader = HistoryScriptReader([
            try historyPage(events: [historyEvent(1)], last: 2),
            try historyPage(events: [historyEvent(2), historyEvent(3)], last: 3),
            try historyPage(events: [historyEvent(3)], last: 3),
            try historyPage(events: [], last: 3, next: 3),
        ])
        let consumer = CICacheHistoryConsumer(reader: reader, persistence: HistoryMemoryPersistence())
        let first = await consumer.read()
        XCTAssertEqual(first.state.after, 2, "Writes after the first upper sequence wait until the next traversal")
        XCTAssertEqual(first.state.events.map(\.sequence), [1, 2])
        let second = await consumer.read()
        XCTAssertEqual(second.state.events.map(\.sequence), [1, 2, 3])
        let empty = await consumer.read()
        XCTAssertEqual(empty.state.events.count, 3, "An empty page neither invents zero usage nor duplicates records")
        let awaited3 = await reader.requests()
        XCTAssertEqual(awaited3, [0, 1, 2, 3])
    }

    func testFourPageBudgetAndIncompleteProtection() async throws {
        let reader = HistoryScriptReader(
            try (1...8).map { try historyPage(events: [historyEvent(UInt64($0))], last: 10) })
        let consumer = CICacheHistoryConsumer(reader: reader, persistence: HistoryMemoryPersistence())
        let first = await consumer.read()
        XCTAssertTrue(first.traversalLimited)
        XCTAssertEqual(first.state.after, 4)
        XCTAssertEqual(
            first.retentionBlockers,
            ["Cache access history is incomplete.", "Authoritative lease coverage is unavailable."])
        let second = await consumer.read()
        XCTAssertEqual(second.state.after, 8)
        XCTAssertTrue(second.traversalLimited)
        let awaited4 = await reader.requests()
        XCTAssertEqual(awaited4, Array(0...7).map(UInt64.init))
    }

    func testHistoryIdentityResetAndRestartNeverReuseForeignCursor() async throws {
        let newID = "00000000-0000-0000-0000-000000000003"
        let newSession = "00000000-0000-0000-0000-000000000004"
        let reader = HistoryScriptReader([
            try historyPage(events: [historyEvent(1), historyEvent(2)], last: 2),
            try historyPage(events: [], last: 2, next: 2, id: newID),
            try historyPage(events: [historyEvent(1), historyEvent(2)], last: 2, id: newID),
            try historyPage(
                events: [historyEvent(3, session: newSession)], last: 3, id: newID, session: newSession, sessions: 2),
        ])
        let consumer = CICacheHistoryConsumer(reader: reader, persistence: HistoryMemoryPersistence())
        _ = await consumer.read()
        let reset = await consumer.read()
        XCTAssertEqual(reset.state.historyId, newID)
        XCTAssertEqual(reset.state.events.count, 2)
        XCTAssertTrue(reset.state.gaps.contains("producer-history-reset"))
        let restarted = await consumer.read()
        XCTAssertTrue(restarted.state.gaps.contains("producer-restart"))
        XCTAssertTrue(restarted.state.gaps.contains("producer-restart-gap"))
        let awaited5 = await reader.requests()
        XCTAssertEqual(awaited5, [0, 2, 0, 2])
    }

    func testCursorAheadTruncationAndLossRemainVisible() async throws {
        let reader = HistoryScriptReader([
            try historyPage(events: [historyEvent(1), historyEvent(2)], last: 2),
            try historyPage(events: [], last: 1, next: 2),
            try historyPage(events: [historyEvent(1)], last: 1),
            try historyPage(events: [historyEvent(10)], last: 10, oldest: 10, truncated: true, lost: 3, pending: 2),
        ])
        let consumer = CICacheHistoryConsumer(reader: reader, persistence: HistoryMemoryPersistence())
        _ = await consumer.read()
        let reset = await consumer.read()
        XCTAssertTrue(reset.state.gaps.contains("cursor-ahead-of-producer"))
        let truncated = await consumer.read()
        XCTAssertTrue(truncated.state.gaps.contains("producer-retention-truncated"))
        XCTAssertTrue(truncated.state.gaps.contains("sequence-gap"))
        XCTAssertTrue(truncated.state.gaps.contains("producer-observations-lost"))
        XCTAssertEqual(truncated.state.summary?.pendingRecords, 2)
        XCTAssertEqual(truncated.state.after, 10)
    }

    func testInvalidSequenceAndUnavailableStatusDoNotAdvanceCursor() async throws {
        let reader = HistoryScriptReader([
            try historyPage(events: [historyEvent(1)]),
            try historyPage(events: [historyEvent(3), historyEvent(2)], last: 3),
            try historyPage(events: [], last: 1, next: 1, status: "write_failed"),
            try historyPage(events: [], last: 4, next: 1),
        ])
        let consumer = CICacheHistoryConsumer(reader: reader, persistence: HistoryMemoryPersistence())
        _ = await consumer.read()
        for _ in 0..<3 {
            let failed = await consumer.read()
            XCTAssertEqual(failed.state.after, 1)
            XCTAssertEqual(failed.state.events.count, 1)
            XCTAssertNotNil(failed.error)
        }
    }

    func testPersistenceFailureAndUnknownObserverVersionDoNotClaimDurableCursor() async throws {
        let failedStorage = HistoryMemoryPersistence(failSave: true)
        let failed = await CICacheHistoryConsumer(
            reader: HistoryScriptReader([try historyPage(events: [historyEvent(1)])]), persistence: failedStorage
        ).read()
        XCTAssertFalse(failed.persisted)
        XCTAssertTrue(failed.state.gaps.contains("consumer-persistence-unavailable"))
        var cached = CICacheHistoryState()
        cached.observerVersion = 99
        let unknownStorage = HistoryMemoryPersistence(data: try JSONEncoder().encode(cached))
        let unknown = await CICacheHistoryConsumer(
            reader: HistoryScriptReader([try historyPage(events: [historyEvent(1)])]), persistence: unknownStorage
        ).read()
        XCTAssertFalse(unknown.persisted)
        XCTAssertTrue(unknown.state.gaps.contains("consumer-state-unavailable"))
        let awaited6 = await unknownStorage.writes()
        XCTAssertEqual(awaited6, 0, "Do not overwrite unknown observer state")
    }

    func testCancelledReadDoesNotConsumeOrPersistPage() async throws {
        let storage = HistoryMemoryPersistence()
        let reader = HistoryScriptReader([try historyPage(events: [historyEvent(1)])], cancel: true)
        let task = Task { await CICacheHistoryConsumer(reader: reader, persistence: storage).read() }
        let snapshot = await task.value
        XCTAssertEqual(snapshot.state.after, 0)
        XCTAssertFalse(snapshot.persisted)
        let awaited7 = await storage.writes()
        XCTAssertEqual(awaited7, 0)
    }

    func testMalformedIdentityResetAndFailedZeroReadPreserveEarlierFacts() async throws {
        let newID = "00000000-0000-0000-0000-000000000003"
        let candidates = [
            try historyPage(events: [historyEvent(4), historyEvent(3)], last: 4, id: newID),
            try historyPage(events: [], last: 1, next: 0),
            try historyPage(events: [], last: 2, next: 2, id: newID),
        ]
        for candidate in candidates {
            let storage = HistoryMemoryPersistence()
            let reader = HistoryScriptReader([
                try historyPage(events: [historyEvent(1), historyEvent(2)], last: 2), candidate,
            ])
            let consumer = CICacheHistoryConsumer(reader: reader, persistence: storage)
            _ = await consumer.read()
            let failed = await consumer.read()
            XCTAssertEqual(failed.state.historyId, historyID)
            XCTAssertEqual(failed.state.after, 2)
            XCTAssertEqual(failed.state.events.map(\.sequence), [1, 2])
            XCTAssertNotNil(failed.error)
            let writes = await storage.writes()
            XCTAssertEqual(writes, 1)
        }
    }

    func testInvalidMeasurementQualitySurvivesPersistenceRoundTrip() async throws {
        var event = historyEvent(1, kind: "attempt")
        var attempt = event["attempt"] as! [String: Any]
        attempt["report"] = ["proxy": ["requests": 1], "stores": [["golden": "hit"]]]
        event["attempt"] = attempt
        let storage = HistoryMemoryPersistence()
        let consumer = CICacheHistoryConsumer(
            reader: HistoryScriptReader([try historyPage(events: [event])]), persistence: storage)
        let first = await consumer.read()
        XCTAssertEqual(first.telemetry.attempts.first?.report.invalidProxy, true)
        XCTAssertEqual(first.telemetry.attempts.first?.report.invalidStores, true)
        let reloaded = await CICacheHistoryConsumer(
            reader: HistoryScriptReader([
                try historyPage(events: [], last: 1, next: 1)
            ]), persistence: storage
        ).read()
        XCTAssertEqual(reloaded.telemetry.attempts.first?.report.invalidProxy, true)
        XCTAssertEqual(reloaded.telemetry.attempts.first?.report.invalidStores, true)
        XCTAssertNil(reloaded.telemetry.attempts.first?.report.proxy)
        XCTAssertTrue(reloaded.state.gaps.contains("invalid-measurements"))
    }

    func testCorruptCachedSequencesAndSummaryAreRejectedWithoutReplacement() async throws {
        let original = HistoryMemoryPersistence()
        _ = await CICacheHistoryConsumer(
            reader: HistoryScriptReader([try historyPage(events: [historyEvent(1)])]), persistence: original
        ).read()
        let bytes = await original.value()
        let data = try XCTUnwrap(bytes)
        let valid = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for corruption in ["sequence", "summary"] {
            var object = valid
            if corruption == "sequence" {
                let events = object["events"] as! [[String: Any]]
                object["events"] = events + events
            } else {
                var summary = object["summary"] as! [String: Any]
                summary["retainedRecords"] = 99999
                object["summary"] = summary
            }
            let storage = HistoryMemoryPersistence(data: try JSONSerialization.data(withJSONObject: object))
            let observed = await CICacheHistoryConsumer(
                reader: HistoryScriptReader([try historyPage(events: [historyEvent(1)])]), persistence: storage
            ).read()
            XCTAssertFalse(observed.persisted)
            XCTAssertTrue(observed.state.gaps.contains("consumer-state-unavailable"))
            let writes = await storage.writes()
            XCTAssertEqual(writes, 0)
        }
    }

    func testEmptyResetPageBeforeUpperPreservesEarlierFacts() async throws {
        let newID = "00000000-0000-0000-0000-000000000003"
        let reader = HistoryScriptReader([
            try historyPage(events: [historyEvent(1), historyEvent(2)], last: 2),
            try historyPage(events: [], last: 2, next: 2, id: newID),
            try historyPage(events: [], last: 2, next: 0, id: newID),
        ])
        let consumer = CICacheHistoryConsumer(reader: reader, persistence: HistoryMemoryPersistence())
        _ = await consumer.read()
        let failed = await consumer.read()
        XCTAssertEqual(failed.state.historyId, historyID)
        XCTAssertEqual(failed.state.events.map(\.sequence), [1, 2])
        XCTAssertEqual(failed.state.after, 2)
        XCTAssertNotNil(failed.error)
    }

    @MainActor
    func testCachePageCancellationStopsFurtherHistoryRequests() async throws {
        let reader = HistoryGatedReader(page: try historyPage(events: [historyEvent(1)], last: 2))
        let storage = HistoryMemoryPersistence()
        let consumer = CICacheHistoryConsumer(reader: reader, persistence: storage)
        let store = CICacheStore()
        let refresh = Task {
            await store.refresh(
                reader: HistoryInventoryReader(), sourceID: "fixture",
                telemetryReader: HistoryTelemetryReader(), historyReader: consumer)
        }
        await reader.waitUntilReading()
        store.cancelRefresh()  // CacheView.onDisappear calls this owner cancellation.
        await reader.release()
        await refresh.value
        let requests = await reader.requests()
        let writes = await storage.writes()
        XCTAssertEqual(requests, [0])
        XCTAssertEqual(writes, 0)
        XCTAssertNil(store.history)
        XCTAssertFalse(store.isRefreshing)
    }

    func testLocalPersistenceUsesOnlyOwnedTemporaryObserverFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = LocalCICacheHistoryPersistence(url: directory.appendingPathComponent("observations.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let awaited8 = try await persistence.load()
        XCTAssertNil(awaited8)
        let bytes = Data("fixture".utf8)
        try await persistence.save(bytes)
        let awaited9 = try await persistence.load()
        XCTAssertEqual(awaited9, bytes)
        do {
            try await persistence.save(Data(repeating: 0, count: LocalCICacheHistoryPersistence.byteLimit + 1))
            XCTFail("Oversized observer data must be refused")
        } catch {}
    }
}

private let historyID = "00000000-0000-0000-0000-000000000001"
private let sessionID = "00000000-0000-0000-0000-000000000002"
private let recorded = "2026-10-08T22:00:00Z"

private func historyEvent(_ sequence: UInt64, kind: String = "session-start", session: String = sessionID) -> [String:
    Any]
{
    var object: [String: Any] = ["sequence": sequence, "sessionId": session, "recordedAt": recorded, "kind": kind]
    if kind == "attempt" {
        object["attempt"] = [
            "runnerId": "rig-a", "projectId": "alpha", "runId": "run-a", "attemptId": "attempt-a", "nodeId": "build",
            "observedAt": recorded,
            "report": [
                "stores": [
                    [
                        "cacheId": String(repeating: "a", count: 64), "volumeName": "cf-cache-node-a", "kind": "volume",
                        "mountPath": "/cache", "golden": "hit", "resolveMs": 0,
                    ]
                ]
            ],
        ]
    } else if kind == "save" {
        object["save"] = [
            "runnerId": "rig-a", "projectId": "alpha", "runId": "run-a", "attemptId": "attempt-a", "nodeId": "build",
            "observedAt": recorded,
            "save": [
                "cacheId": String(repeating: "a", count: 64), "volumeName": "cf-cache-node-a", "containerId": "job-a",
                "outcome": "committed", "durationMs": 0, "allocatedBytes": 17, "finishedAt": recorded,
            ],
        ]
    }
    return object
}

private func historyObject(
    events: [[String: Any]], last: UInt64? = nil, next: UInt64? = nil, id: String = historyID,
    session: String = sessionID,
    sessions: UInt64 = 1, oldest: UInt64 = 1, truncated: Bool = false, lost: UInt64 = 0, pending: UInt64 = 0,
    status: String = "available"
) -> [String: Any] {
    let end = last ?? events.last?["sequence"] as? UInt64 ?? 0
    return [
        "schemaVersion": "cache-history-v1", "historyId": id, "sessionId": session, "createdAt": recorded,
        "lastSequence": end,
        "sessions": sessions, "evictedRecords": truncated ? 9 : 0, "lostRecords": lost, "retainedBytes": 100,
        "retainedRecords": end,
        "status": status, "complete": false, "leaseCoverage": "unavailable",
        "coverageReasons": ["startup-gap-unmeasured"],
        "pendingRecords": pending, "unpersistedLoss": 0, "oldestSequence": end == 0 ? 0 : oldest,
        "nextAfter": next ?? events.last?["sequence"] as? UInt64 ?? 0, "truncatedBefore": truncated, "events": events,
    ]
}

private func historyPage(
    events: [[String: Any]], last: UInt64? = nil, next: UInt64? = nil, id: String = historyID,
    session: String = sessionID,
    sessions: UInt64 = 1, oldest: UInt64 = 1, truncated: Bool = false, lost: UInt64 = 0, pending: UInt64 = 0,
    status: String = "available"
) throws -> CICacheHistoryPage {
    try CICacheHistoryPage.decode(
        JSONSerialization.data(
            withJSONObject: historyObject(
                events: events, last: last, next: next, id: id, session: session,
                sessions: sessions, oldest: oldest, truncated: truncated, lost: lost, pending: pending, status: status))
    )
}

private actor HistoryScriptReader: CICacheHistoryPageReading {
    var pages: [CICacheHistoryPage]
    var asked: [UInt64] = []
    let cancel: Bool
    init(_ pages: [CICacheHistoryPage], cancel: Bool = false) {
        self.pages = pages
        self.cancel = cancel
    }
    func read(after: UInt64) throws -> CICacheHistoryPage {
        asked.append(after)
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        guard !pages.isEmpty else { throw CICacheReadError.unavailable }
        return pages.removeFirst()
    }
    func requests() -> [UInt64] { asked }
}

private actor HistoryMemoryPersistence: CICacheHistoryPersisting {
    var data: Data?
    var count = 0
    let failSave: Bool
    init(data: Data? = nil, failSave: Bool = false) {
        self.data = data
        self.failSave = failSave
    }
    func load() -> Data? { data }
    func save(_ data: Data) throws {
        if failSave { throw CICacheReadError.unavailable }
        self.data = data
        count += 1
    }
    func value() -> Data? { data }
    func writes() -> Int { count }
}

private struct HistoryInventoryReader: CICacheInventoryReading {
    func read() async throws -> CICacheRead { CICacheRead(volumes: [], containers: [], truncated: false) }
}
private struct HistoryTelemetryReader: CICacheTelemetryReading {
    func read() async throws -> CICacheTelemetry { CICacheTelemetry(receivedAt: Date(), counters: []) }
}
private actor HistoryGatedReader: CICacheHistoryPageReading {
    let page: CICacheHistoryPage
    private var asked: [UInt64] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<CICacheHistoryPage, Never>?
    init(page: CICacheHistoryPage) { self.page = page }
    func read(after: UInt64) async -> CICacheHistoryPage {
        asked.append(after)
        waiting.forEach { $0.resume() }
        waiting = []
        return await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilReading() async {
        if !asked.isEmpty { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        blocked?.resume(returning: page)
        blocked = nil
    }
    func requests() -> [UInt64] { asked }
}
