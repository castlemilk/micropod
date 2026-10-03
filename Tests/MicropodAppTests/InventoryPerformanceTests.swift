import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

@MainActor
final class InventoryPerformanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCachedInventoryMatchesPureMappingAcrossMetricAndRuntimeChanges() {
        let containers = fixtures(count: 120)
        let machines = [MachineEntry(name: "runner", state: "running")]
        var stats = statistics(for: containers)
        var machineStats = Micropod_V1_MachineStats()
        machineStats.id = "runner"
        machineStats.containerID = containers[0].id
        machineStats.cpuPercent = 120
        machineStats.memoryUsedBytes = 1024
        let machineMap = ["runner": machineStats]
        let cache = WorkloadInventoryCache()
        for revision in 0..<4 {
            stats[containers[1].id]?.cpuPercent = Double(revision * 50)
            let available = revision != 2
            let expected = WorkloadInventory.items(
                containers: containers, machines: machines, containerStats: stats,
                machineStats: machineMap, sampledAt: now, runtimeAvailable: available)
            let actual = cache.items(
                containers: containers, machines: machines, containerStats: stats,
                machineStats: machineMap, sampledAt: now, runtimeAvailable: available,
                metadataRevision: 0, metricsRevision: UInt64(revision))
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(cache.ids, expected.map(\.id))
            XCTAssertEqual(cache.item(id: "machine:runner"), expected.last)
            XCTAssertNil(cache.item(id: WorkloadRoute.container(containers[0].id).id))
        }
    }

    func testMetadataChangesInvalidateSearchTermsAndRemovedRoutes() {
        var containers = fixtures(count: 2)
        let cache = WorkloadInventoryCache()
        _ = cache.items(
            containers: containers, machines: [], containerStats: [:], machineStats: [:],
            sampledAt: nil, runtimeAvailable: true, metadataRevision: 0, metricsRevision: 0)
        containers[0].image = "registry.example/new-image:v2"
        containers.removeLast()
        let actual = cache.items(
            containers: containers, machines: [], containerStats: [:], machineStats: [:],
            sampledAt: nil, runtimeAvailable: true, metadataRevision: 1, metricsRevision: 0)
        XCTAssertEqual(actual.count, 1)
        XCTAssertTrue(actual[0].searchTerms.contains("new-image:v2"))
        XCTAssertNil(cache.item(id: "container:workload-1"))
        XCTAssertEqual(cache.current(metadataRevision: 1, metricsRevision: 0, runtimeAvailable: true), actual)
        XCTAssertNil(cache.current(metadataRevision: 1, metricsRevision: 0, runtimeAvailable: false))
    }

    func testGroupingCacheRefreshesValuesWithoutLosingSortOrNewlyVisibleBackingContainers() {
        let containers = fixtures(count: 5)
        let cache = WorkloadInventoryCache()
        let grouping = WorkloadGroupingCache()
        var stats = statistics(for: containers)
        for revision in 0..<3 {
            stats[containers[0].id]?.cpuPercent = Double(revision * 100)
            let items = cache.items(
                containers: containers, machines: [], containerStats: stats, machineStats: [:],
                sampledAt: now, runtimeAvailable: true, metadataRevision: 0, metricsRevision: UInt64(revision))
            for sort in WorkloadSort.allCases {
                let actual = grouping.groups(
                    items: items, ids: cache.ids, metadataRevision: 0, metricsRevision: UInt64(revision),
                    runtimeAvailable: true, query: "project", type: .all, state: .all,
                    sort: sort, ascending: false)
                XCTAssertEqual(
                    actual, WorkloadInventory.groups(items: items, query: "project", sort: sort, ascending: false))
            }
        }
        // A metrics change can restore a backing container without changing metadata.
        let all = cache.items(
            containers: containers, machines: [], containerStats: stats, machineStats: [:],
            sampledAt: now, runtimeAvailable: true, metadataRevision: 0, metricsRevision: 5)
        let first = grouping.groups(
            items: Array(all.dropFirst()), ids: Array(all.dropFirst()).map(\.id), metadataRevision: 0,
            metricsRevision: 5, runtimeAvailable: true, query: "", type: .all, state: .all, sort: .name, ascending: true
        )
        XCTAssertEqual(first.flatMap(\.items).count, 4)
        let restored = grouping.groups(
            items: all, ids: all.map(\.id), metadataRevision: 0, metricsRevision: 6,
            runtimeAvailable: true, query: "", type: .all, state: .all, sort: .name, ascending: true)
        XCTAssertEqual(restored, WorkloadInventory.groups(items: all))
    }

    func testTopologyIndexesOnlyRealUniqueAttachmentsAndKeepsUnattachedNetworks() {
        var a = Micropod_V1_Network()
        a.id = "a"
        var b = Micropod_V1_Network()
        b.id = "b"
        var c = fixtures(count: 3)
        c[0].networks = ["a", "a", "missing"]
        c[1].networks = ["b", "a"]
        c[2].networks = []
        let model = NetworkTopologyModel(networks: [a, b], containers: c)
        XCTAssertEqual(model.networks.map(\.id), ["a", "b"])
        XCTAssertEqual(model.containers.map(\.id), [c[0].id, c[1].id])
        XCTAssertEqual(model.edges.count, 3)
        XCTAssertTrue(model.edges.contains(.init(networkIndex: 0, containerIndex: 0)))
        XCTAssertTrue(model.edges.contains(.init(networkIndex: 0, containerIndex: 1)))
        XCTAssertTrue(model.edges.contains(.init(networkIndex: 1, containerIndex: 1)))
    }

    func testPaletteIdentityRemainsStableAcrossRendersAndMetadataChanges() {
        let container = fixtures(count: 1)[0]
        let item = WorkloadInventory.items(
            containers: [container], machines: [], containerStats: [:], machineStats: [:], sampledAt: nil)[0]
        XCTAssertEqual(PaletteItem.forWorkload(item).id, PaletteItem.forWorkload(item).id)
        XCTAssertEqual(
            PaletteItem(icon: "a", title: "First", action: .selectImage("image")).id,
            PaletteItem(icon: "b", title: "Renamed", action: .selectImage("image")).id)
        XCTAssertNotEqual(
            PaletteItem.forWorkload(item).id,
            PaletteItem(icon: "a", title: item.name, action: .selectImage(item.name)).id)
    }

    /// Opt-in measurements emit repeatable numbers without hardware-dependent
    /// test thresholds. Run release tests with MICROPOD_PERF_BENCH=1.
    func testInventoryBenchmarks() throws {
        guard ProcessInfo.processInfo.environment["MICROPOD_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set MICROPOD_PERF_BENCH=1 to collect inventory timings")
        }
        for count in [1000, 5000] {
            let containers = fixtures(count: count)
            let stats = statistics(for: containers)
            let cache = WorkloadInventoryCache()
            let items = cache.items(
                containers: containers, machines: [], containerStats: stats, machineStats: [:],
                sampledAt: now, runtimeAvailable: true, metadataRevision: 0, metricsRevision: 0)
            var checksum = 0
            try benchmark("inventory-pure", count: count, iterations: 20) {
                checksum +=
                    WorkloadInventory.items(
                        containers: containers, machines: [], containerStats: stats,
                        machineStats: [:], sampledAt: self.now
                    ).count
            }
            try benchmark("inventory-cache-hit", count: count, iterations: 10000) {
                checksum +=
                    cache.items(
                        containers: containers, machines: [], containerStats: stats, machineStats: [:],
                        sampledAt: self.now, runtimeAvailable: true, metadataRevision: 0, metricsRevision: 0
                    ).count
            }
            var metricRevision: UInt64 = 0
            try benchmark("inventory-metric-overlay", count: count, iterations: 20) {
                metricRevision += 1
                checksum +=
                    cache.items(
                        containers: containers, machines: [], containerStats: stats, machineStats: [:],
                        sampledAt: self.now, runtimeAvailable: true, metadataRevision: 0,
                        metricsRevision: metricRevision
                    ).count
            }
            let grouping = WorkloadGroupingCache()
            _ = grouping.groups(
                items: items, ids: cache.ids, metadataRevision: 0, metricsRevision: 0,
                runtimeAvailable: true, query: "", type: .all, state: .all, sort: .name, ascending: true)
            try benchmark("grouping-pure", count: count, iterations: 20) {
                checksum += WorkloadInventory.groups(items: items).count
            }
            try benchmark("grouping-cache-hit", count: count, iterations: 10000) {
                checksum +=
                    grouping.groups(
                        items: items, ids: cache.ids, metadataRevision: 0, metricsRevision: 0,
                        runtimeAvailable: true, query: "", type: .all, state: .all, sort: .name, ascending: true
                    ).count
            }
            XCTAssertGreaterThan(checksum, 0)
        }
    }

    private func benchmark(_ scenario: String, count: Int, iterations: Int, body: () -> Void) throws {
        let start = Date.timeIntervalSinceReferenceDate
        for _ in 0..<iterations { body() }
        let elapsed = (Date.timeIntervalSinceReferenceDate - start) * 1000 / Double(iterations)
        let record: [String: Any] = [
            "scenario": scenario, "workloads": count, "iterations": iterations,
            "millisecondsPerIteration": elapsed,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("MICROPOD_PERF_JSON \(String(decoding: data, as: UTF8.self))")
    }

    private func fixtures(count: Int) -> [Micropod_V1_Container] {
        (0..<count).map { index in
            var container = Micropod_V1_Container()
            container.id = "workload-\(index)"
            container.image = "registry.example/project/service-\(index):development"
            container.state = index % 5 == 0 ? "stopped" : "running"
            container.runtime = index % 3 == 0 ? "docker" : "apple"
            container.labels = ["com.docker.compose.project": "project-\(index % 12)", "owner": "team-\(index % 20)"]
            return container
        }
    }

    private func statistics(for containers: [Micropod_V1_Container]) -> [String: Micropod_V1_ContainerStats] {
        Dictionary(
            uniqueKeysWithValues: containers.enumerated().map { index, container in
                var stats = Micropod_V1_ContainerStats()
                stats.id = container.id
                stats.cpuPercent = Double(index % 100)
                stats.memoryUsedBytes = UInt64(index + 1) * 1024
                return (container.id, stats)
            })
    }
}
