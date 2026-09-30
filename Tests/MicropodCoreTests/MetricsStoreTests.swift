import Foundation
import XCTest

@testable import MicropodCore

final class MetricsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() throws -> MetricsStore {
        try MetricsStore(url: dir.appendingPathComponent("metrics.sqlite"))
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)  // on a 15 min boundary

    func testSamplesRollUpIntoEveryTierWithAverageAndPeak() throws {
        let store = try store()
        store.record([(.container, "web", .init(cpuPercent: 10, memoryUsedBytes: 100))], at: t0)
        store.record([(.container, "web", .init(cpuPercent: 30, memoryUsedBytes: 300))], at: t0.addingTimeInterval(5))
        store.record([(.container, "web", .init(cpuPercent: 50, memoryUsedBytes: 500))], at: t0.addingTimeInterval(15))
        let now = t0.addingTimeInterval(20)

        let fine = store.history(.container, "web", range: 3600, now: now)
        XCTAssertEqual(fine.resolution, 10)
        XCTAssertEqual(fine.points.map(\.average.cpuPercent), [20, 50], "10 s buckets average what lands in them")
        XCTAssertEqual(fine.points.map(\.peak.cpuPercent), [30, 50])
        XCTAssertEqual(fine.points.first?.timestamp, t0)

        let minute = store.history(.container, "web", range: 24 * 3600, now: now)
        XCTAssertEqual(minute.resolution, 60)
        XCTAssertEqual(minute.points.count, 1)
        XCTAssertEqual(minute.points[0].average.memoryUsedBytes, 300, accuracy: 0.001)
        XCTAssertEqual(minute.points[0].peak.memoryUsedBytes, 500)

        let coarse = store.history(.container, "web", range: 7 * 86400, now: now)
        XCTAssertEqual(coarse.resolution, 900)
        XCTAssertEqual(coarse.points.first?.average.cpuPercent ?? 0, 30, accuracy: 0.001)

        XCTAssertTrue(store.history(.container, "other", range: 3600, now: now).points.isEmpty)
        XCTAssertTrue(store.history(.machine, "web", range: 3600, now: now).points.isEmpty, "kinds don't mix")
    }

    func testTierSelectionCoversTheRange() {
        XCTAssertEqual(MetricsStore.tier(for: 15 * 60), 0)
        XCTAssertEqual(MetricsStore.tier(for: 3 * 3600), 0)
        XCTAssertEqual(MetricsStore.tier(for: 3 * 3600 + 1), 1)
        XCTAssertEqual(MetricsStore.tier(for: 48 * 3600), 1)
        XCTAssertEqual(MetricsStore.tier(for: 7 * 86400), 2)
        XCTAssertEqual(MetricsStore.tier(for: 90 * 86400), 2, "past every retention: the coarsest")
    }

    func testPruneDropsEachTierByAgeAndEmptySeries() throws {
        let store = try store()
        store.record([(.container, "old", .init(cpuPercent: 1))], at: t0)
        let later = t0.addingTimeInterval(4 * 3600)
        store.prune(now: later)
        XCTAssertTrue(
            store.history(.container, "old", range: 5 * 3600, now: later).points.count == 1,
            "the 1 min tier still has it")
        XCTAssertTrue(store.history(.container, "old", range: 3600 * 3, now: t0.addingTimeInterval(60)).points.isEmpty)

        store.prune(now: t0.addingTimeInterval(31 * 86400))
        XCTAssertTrue(store.targets(.container).isEmpty, "a series with no points left is dropped")
    }

    func testRemoveAndRetainDeleteHistory() throws {
        let store = try store()
        for name in ["a", "b", "c"] {
            store.record([(.container, name, .init(cpuPercent: 1))], at: t0)
        }
        store.record([(.machine, "m", .init(cpuPercent: 1))], at: t0)
        store.remove(.container, "a")
        XCTAssertEqual(Set(store.targets(.container)), ["b", "c"])
        store.retain(.container, ["c"])
        XCTAssertEqual(store.targets(.container), ["c"])
        XCTAssertEqual(store.targets(.machine), ["m"], "retain touches one kind only")
        XCTAssertTrue(store.history(.container, "a", range: 3600, now: t0).points.isEmpty)
    }

    func testTwoWritersOnOneFileAverageRatherThanDoubleCount() throws {
        let a = try store()
        let b = try store()
        a.record([(.system, "all", .init(cpuPercent: 40))], at: t0)
        b.record([(.system, "all", .init(cpuPercent: 40))], at: t0.addingTimeInterval(1))
        XCTAssertEqual(a.history(.system, "all", range: 3600, now: t0).points.map(\.average.cpuPercent), [40])
    }

    func testRecorderTurnsCountersIntoRatesAndSumsTheSystem() throws {
        let store = try store()
        let recorder = MetricsRecorder(store: store)
        func snapshot(_ rx: UInt64, cpu: Double) -> Micropod_V1_StatsSnapshot {
            .with {
                $0.containers = [
                    .with {
                        $0.id = "web"
                        $0.cpuPercent = cpu
                        $0.networkRxBytes = rx
                        $0.blockWriteBytes = rx * 2
                    },
                    .with {
                        $0.id = "db"
                        $0.cpuPercent = 5
                    },
                ]
            }
        }
        recorder.record(snapshot(1000, cpu: 10), at: t0)
        recorder.record(snapshot(21000, cpu: 20), at: t0.addingTimeInterval(10))
        recorder.record(snapshot(500, cpu: 30), at: t0.addingTimeInterval(20))  // restarted: counter reset
        let now = t0.addingTimeInterval(25)
        let web = store.history(.container, "web", range: 3600, now: now).points
        XCTAssertEqual(web.map(\.average.networkRxRate), [0, 2000, 0], "first sample has no rate; a reset gives 0")
        XCTAssertEqual(web[1].average.blockWriteRate, 4000)
        let system = store.history(.system, "all", range: 3600, now: now).points
        XCTAssertEqual(system.map(\.average.cpuPercent), [15, 25, 35], "the aggregate sums containers")
    }

    func testRangeParsingAndSummary() throws {
        XCTAssertEqual(MetricsStore.parseRange("15m"), 900)
        XCTAssertEqual(MetricsStore.parseRange("24h"), 86400)
        XCTAssertEqual(MetricsStore.parseRange("7d"), 7 * 86400)
        XCTAssertEqual(MetricsStore.parseRange("90"), 90)
        XCTAssertNil(MetricsStore.parseRange("soon"))
        XCTAssertNil(MetricsStore.parseRange("-1h"))

        let store = try store()
        for i in 0..<30 {
            store.record(
                [(.container, "web", .init(cpuPercent: Double(i), memoryUsedBytes: 1_048_576))],
                at: t0.addingTimeInterval(Double(i) * 10))
        }
        let now = t0.addingTimeInterval(300)
        let text = MetricsStore.summary(
            store.history(.container, "web", range: 3600, now: now), title: "web", range: 3600)
        XCTAssertTrue(text.hasPrefix("web: 30 points at 10s resolution over the last 1h"), text)
        XCTAssertTrue(text.contains("cpu      peak 29.0%  avg 14.5%  now 29.0%"), text)
        XCTAssertTrue(text.contains("▁") && text.contains("█"), text)
        XCTAssertEqual(
            MetricsStore.summary((10, []), title: "idle", range: 900), "idle: no history in the last 15m")
    }
}
