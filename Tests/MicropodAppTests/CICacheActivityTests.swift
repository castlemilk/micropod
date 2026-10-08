import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

final class CICacheActivityTests: XCTestCase {
    func testStoreProvisioningAndSaveDecisionsDoNotBecomeContentHits() throws {
        let telemetry = try decode([
            [
                "attemptId": "warm", "nodeId": "build",
                "report": [
                    "stores": [
                        [
                            "ecosystem": "go", "kind": "build", "mountPath": "/cache/go", "golden": "hit",
                            "commit": "queued",
                        ],
                        ["kind": "dep", "mountPath": "/cache/npm", "golden": "seeded"],
                        ["kind": "path", "mountPath": "/cache/path", "golden": "cold", "commit": "not-committed"],
                    ], "env": [["name": "ignored", "value": "not-decoded"]],
                ],
            ]
        ])
        let report = try XCTUnwrap(telemetry.attempts.first?.report)
        XCTAssertNil(report.proxy, "Existing store is not a measured proxy/content hit")
        XCTAssertEqual(
            report.stores.map(\.provisioning),
            ["Existing store mounted", "Store seeded from earlier lineage", "Cold store provisioned"])
        XCTAssertEqual(report.stores[0].commitDecision, "Save queued; completion unknown")
        let invalid = try decode([
            [
                "attemptId": "bad", "nodeId": "build",
                "report": ["stores": [["golden": "hit"]], "proxy": proxy(local: 0)],
            ]
        ])
        XCTAssertTrue(invalid.attempts[0].report.invalidStores)
        XCTAssertNotNil(invalid.attempts[0].report.proxy, "Bad store facts must not hide independent valid proxy facts")
    }

    func testMeasuredZeroAndMissingIncompleteProxyReportsStayDistinct() throws {
        let telemetry = try decode([
            ["attemptId": "measured", "nodeId": "install", "report": ["proxy": proxy(local: 0)]],
            ["attemptId": "missing", "nodeId": "build", "report": [:]],
            ["attemptId": "incomplete", "nodeId": "test", "report": ["proxy": ["requests": 5]]],
            ["attemptId": "invalid", "nodeId": "test", "report": ["proxy": proxy(local: -1)]],
        ])
        let reports = telemetry.proxyReports(for: .init())
        XCTAssertEqual(reports.map(\.id), ["measured"])
        XCTAssertEqual(reports.first?.report.proxy?.localHits, 0)
        XCTAssertEqual(reports.first?.report.proxy?.upstreamFetches, 1724)
        XCTAssertNil(telemetry.attempts[1].report.proxy)
        XCTAssertFalse(telemetry.attempts[1].report.invalidProxy)
        XCTAssertTrue(telemetry.attempts[2].report.invalidProxy)
        XCTAssertTrue(telemetry.attempts[3].report.invalidProxy)
    }

    func testUnscopedProxyCannotBeJoinedToProjectOrOwnerAndEnvIsNotDecoded() throws {
        let telemetry = try decode([
            [
                "attemptId": "a", "nodeId": "install",
                "report": ["proxy": proxy(local: 0), "env": ["unexpected": "ignored"]],
            ]
        ])
        XCTAssertEqual(telemetry.proxyReports(for: .init()).count, 1)
        XCTAssertTrue(telemetry.proxyReports(for: .init(project: "project")).isEmpty)
        XCTAssertTrue(telemetry.proxyReports(for: .init(owner: "owner")).isEmpty)
        XCTAssertThrowsError(try decode(Array(repeating: ["attemptId": "a", "nodeId": "n", "report": [:]], count: 21)))
    }

    func testAllResolutionOutcomesAndProxyRequestsBytesAreIndependent() throws {
        let rows: [[String: Any]] = [
            metric("cache_volume_total", 800, ["outcome": "hit", "project": "a"]),
            metric("cache_volume_total", 7, ["outcome": "created", "project": "a"]),
            metric("cache_store_total", 2, ["outcome": "seeded"]),
            metric("cache_store_total", 9, ["outcome": "cold"]),
            metric("depcache_requests_total", 6, ["tier": "upstream"]),
            metric("depcache_requests_total", 1, ["tier": "error"]),
            metric("depcache_bytes_total", 99, ["source": "upstream"]),
            metric("shared_cache_hit_total", 0, [:]),
        ]
        let telemetry = try CICacheTelemetry.decode(
            JSONSerialization.data(withJSONObject: ["ok": true, "metrics": rows]), receivedAt: Date())
        let observed = Dictionary(
            telemetry.observations(for: .init()).map { ($0.label, $0.value) }, uniquingKeysWith: +)
        XCTAssertEqual(observed["Existing goldens"], 800)
        XCTAssertEqual(observed["New goldens"], 7)
        XCTAssertEqual(observed["Seeded store mounts"], 2)
        XCTAssertEqual(observed["Cold store mounts"], 9)
        XCTAssertEqual(observed["Proxy upstream requests"], 6)
        XCTAssertEqual(observed["Proxy errors"], 1)
        XCTAssertEqual(observed["Proxy bytes fetched"], 99)
        XCTAssertNil(observed["Proxy local requests"], "No local series is not a zero-hit measurement")
        XCTAssertFalse(observed.keys.contains { $0.contains("shared") })
        XCTAssertEqual(telemetry.observations(for: .init(project: "a")).map(\.value), [800, 7])
    }

    func testRuntimeIORequiresMatchingActiveReferenceAndPreservesPresence() {
        let volume = Micropod_V1_Volume.with {
            $0.id = "cf-cache-a"
            $0.format = "ext4"
            $0.source = "/volumes/cf-cache-a/volume.img"
        }
        let mounted = Micropod_V1_Container.with {
            $0.id = "job"
            $0.state = "running"
            $0.mounts = [.with { $0.source = "/clones/volume-clones/job/cf-cache-a.img" }]
        }
        let inventory = CICacheInventorySnapshot(
            read: .init(volumes: [volume], containers: [mounted], truncated: false), sourceID: "native",
            measuredAt: Date())
        var stats = Micropod_V1_StatsSnapshot.with {
            $0.containers = [
                .with {
                    $0.id = "job"
                    $0.blockIoObserved = true
                }
            ]
        }
        let zero = CICacheRuntimeIO.observations(inventory: inventory, selection: .init(), stats: stats)
        XCTAssertEqual(zero.first?.readBytes, 0)
        XCTAssertEqual(zero.first?.writeBytes, 0)
        stats.containers[0].blockIoObserved = false
        XCTAssertNil(
            CICacheRuntimeIO.observations(inventory: inventory, selection: .init(), stats: stats).first?.readBytes)
        stats.containers[0].clearBlockIoObserved()
        stats.containers[0].blockReadBytes = 8
        let legacy = CICacheRuntimeIO.observations(inventory: inventory, selection: .init(), stats: stats)
        XCTAssertEqual(legacy.first?.readBytes, 8)
        XCTAssertNil(legacy.first?.writeBytes)
        stats.containers[0].id = "other-job"
        XCTAssertTrue(CICacheRuntimeIO.observations(inventory: inventory, selection: .init(), stats: stats).isEmpty)
    }

    @MainActor
    func testVisiblePageRefreshesAgainAndStopsOnCancellation() async {
        var reads = 0
        var waits = 0
        await CachePageRefreshLoop.run(
            refresh: { reads += 1 },
            pause: {
                waits += 1
                if waits == 2 { throw CancellationError() }
            })
        XCTAssertEqual(reads, 2)
        let cancelled = Task { @MainActor in
            await Task.yield()
            await CachePageRefreshLoop.run(refresh: { reads += 1 }, pause: {})
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(reads, 2, "No new off-page read after cancellation")
    }

    private func decode(_ attempts: [[String: Any]]) throws -> CICacheTelemetry {
        try .decode(
            JSONSerialization.data(withJSONObject: ["ok": true, "metrics": [], "attempts": attempts]),
            receivedAt: Date())
    }
    private func proxy(local: Int) -> [String: Int] {
        [
            "requests": 1724, "localHits": local, "upstreamFetches": 1724,
            "upstreamMetadataFetches": 0, "upstreamBytes": 95941350, "servedBytes": 95941350,
        ]
    }
    private func metric(_ name: String, _ value: Int, _ attributes: [String: String]) -> [String: Any] {
        ["name": name, "type": "counter", "value": value, "attributes": attributes]
    }
}
