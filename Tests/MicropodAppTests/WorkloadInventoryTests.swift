import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

@MainActor
final class WorkloadInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNamespacedRoutesAndCompatibleMachineMetrics() {
        let container = makeContainer("same", runtime: "apple")
        let machine = MachineEntry(name: "same", state: "running")
        var machineStats = Micropod_V1_MachineStats()
        machineStats.id = "same"
        machineStats.containerID = "same-a1b2c3"
        machineStats.cpuPercent = 220
        machineStats.memoryUsedBytes = 1024
        let items = inventory(
            [container], machines: [machine], stats: ["same": makeStats("same", cpu: 25, memory: 256)],
            machineStats: ["same": machineStats])

        XCTAssertEqual(items.map(\.id), ["container:same", "machine:same"])
        XCTAssertEqual(items.map(\.kindLabel), ["Container", "MicroVM"])
        XCTAssertEqual(items[0].cpuCores, 0.25)
        XCTAssertEqual(items[1].cpuCores, 2.2)
        let summary = WorkloadInventory.summary(items: items, at: now)
        XCTAssertEqual(summary.runningCount, 2)
        XCTAssertEqual(summary.cpuCores ?? -1, 2.45, accuracy: 0.000001)
        XCTAssertEqual(summary.memoryBytes, 1280)
        XCTAssertFalse(summary.isPartial)
    }

    func testMachineBackingEntryIsNotCountedTwice() {
        let backing = makeContainer("runner-a1b2c3")
        let machine = MachineEntry(name: "runner", state: "running")
        var sampled = Micropod_V1_MachineStats()
        sampled.id = "runner"
        sampled.containerID = backing.id
        sampled.cpuPercent = 100
        sampled.memoryUsedBytes = 1000
        let items = inventory(
            [backing, makeContainer("runner-unrelated")], machines: [machine],
            machineStats: ["runner": sampled])

        XCTAssertEqual(Set(items.map(\.id)), ["container:runner-unrelated", "machine:runner"])
        XCTAssertEqual(WorkloadInventory.summary(items: items, at: now).cpuCores, 1)
        XCTAssertEqual(WorkloadInventory.summary(items: items, at: now).runningCount, 2)
    }

    func testOrphanMachineSampleDoesNotHideAnUnrelatedContainer() {
        var orphan = Micropod_V1_MachineStats()
        orphan.containerID = "real-container"
        let items = inventory([makeContainer("real-container")], machineStats: ["removed-machine": orphan])
        XCTAssertEqual(items.map(\.id), ["container:real-container"])
    }

    func testStoppedAndUnsampledRowsDoNotReportConfiguredAllocationAsUsage() {
        var stopped = makeContainer("stopped", state: "stopped")
        stopped.resources.memoryBytes = 8 << 30
        stopped.resources.cpus = 8
        let missing = makeContainer("unsampled")
        let items = inventory(
            [stopped, missing], machines: [MachineEntry(name: "stopped-vm", memoryBytes: 8 << 30, state: "stopped")],
            stats: ["stopped": makeStats("stopped", cpu: 400, memory: 2 << 30)])

        XCTAssertTrue(items.allSatisfy { $0.cpuCores == nil && $0.memoryBytes == nil })
        let summary = WorkloadInventory.summary(items: items, at: now)
        XCTAssertNil(summary.cpuCores)
        XCTAssertNil(summary.memoryBytes)
        XCTAssertTrue(summary.isPartial)
        XCTAssertEqual(summary.runningCount, 1)
    }

    func testInvalidCPUStaysUnavailableAndRealZeroRemainsMeasured() {
        let items = inventory(
            [makeContainer("invalid"), makeContainer("idle")],
            stats: [
                "invalid": makeStats("invalid", cpu: .nan, memory: 1), "idle": makeStats("idle", cpu: 0, memory: 0),
            ])
        XCTAssertNil(items[0].cpuCores)
        XCTAssertEqual(items[1].cpuCores, 0)
        XCTAssertEqual(items[1].memoryBytes, 0)
        let summary = WorkloadInventory.summary(items: items, at: now)
        XCTAssertEqual(summary.cpuSampleCount, 1)
        XCTAssertEqual(summary.memorySampleCount, 2)
        XCTAssertTrue(summary.isPartial)
    }

    func testMetadataProjectGroupingAndSearchDoNotInferNames() {
        var compose = makeContainer("api", runtime: "docker")
        compose.image = "ghcr.io/example/api:dev"
        compose.labels = ["com.docker.compose.project": "shop", "owner": "Bene"]
        var native = makeContainer("native")
        native.labels = ["com.skunkworq.micropod.compose": "  studio  ", "com.docker.compose.project": "wrong"]
        let items = inventory([compose, native, makeContainer("shop-worker")])
        XCTAssertEqual(items.map(\.project), ["shop", "studio", "Standalone"])
        XCTAssertEqual(WorkloadInventory.groups(items: items).map(\.project), ["shop", "studio", "Standalone"])
        XCTAssertEqual(
            WorkloadInventory.groups(items: items, query: " BENE docker ").flatMap(\.items).map(\.name), ["api"])
    }

    func testEphemeralWorkloadsHaveTheirOwnTypeFilterAndPortsAreReal() {
        var ephemeral = makeContainer("job", runtime: "sandbox")
        var port = Micropod_V1_PortMapping()
        port.hostPort = 8080
        ephemeral.publishedPorts = [port, port, Micropod_V1_PortMapping()]
        let items = inventory(
            [ephemeral, makeContainer("api")], machines: [MachineEntry(name: "runner", state: "running")])
        XCTAssertEqual(items[0].kindLabel, "Ephemeral VM")
        XCTAssertEqual(items[0].ports, [8080])
        XCTAssertEqual(
            WorkloadInventory.groups(items: items, query: "8080", type: .sandboxes).flatMap(\.items).map(\.name),
            ["job"])
        XCTAssertEqual(WorkloadInventory.groups(items: items, type: .machines).flatMap(\.items).map(\.name), ["runner"])
        XCTAssertEqual(WorkloadInventory.groups(items: items, type: .containers).flatMap(\.items).map(\.name), ["api"])
    }

    func testNumericSortKeepsUnavailableLastInBothDirections() {
        let items = inventory(
            [makeContainer("missing"), makeContainer("high"), makeContainer("low")],
            stats: ["high": makeStats("high", cpu: 180, memory: 900), "low": makeStats("low", cpu: 2, memory: 1)])
        XCTAssertEqual(
            WorkloadInventory.groups(items: items, sort: .cpu).flatMap(\.items).map(\.name), ["low", "high", "missing"])
        XCTAssertEqual(
            WorkloadInventory.groups(items: items, sort: .cpu, ascending: false).flatMap(\.items).map(\.name),
            ["high", "low", "missing"])
        XCTAssertEqual(
            WorkloadInventory.groups(items: items, sort: .memory, ascending: false).flatMap(\.items).map(\.name),
            ["high", "low", "missing"])
    }

    func testSampleAgeRemainsVisibleAndAggregationDoesNotClaimFreshness() {
        let old = now.addingTimeInterval(-45)
        let items = inventory(
            [makeContainer("old")], stats: ["old": makeStats("old", cpu: 50, memory: 100)], sampledAt: old)
        XCTAssertTrue(items[0].metricsAreStale(at: now))
        XCTAssertEqual(items[0].cpuCores, 0.5)
        XCTAssertEqual(WorkloadInventory.summary(items: items, at: now).staleSampleCount, 1)
        XCTAssertFalse(items[0].metricsAreStale(at: old))
    }

    func testSelectionSurvivesFilteringButClearsWhenTheRouteIsRemoved() {
        let items = inventory([makeContainer("same")], machines: [MachineEntry(name: "same", state: "running")])
        XCTAssertEqual(
            WorkloadInventory.resolvedSelection(
                currentID: "machine:same", selectedContainerID: "same", selectedMachineID: "same", items: items),
            "machine:same")
        XCTAssertEqual(
            WorkloadInventory.resolvedSelection(
                currentID: nil, selectedContainerID: nil, selectedMachineID: "same", items: items), "machine:same")
        XCTAssertNil(
            WorkloadInventory.resolvedSelection(
                currentID: "machine:same", selectedContainerID: "same", selectedMachineID: "same", items: [items[0]]))
        // Selection resolution uses the inventory, not the currently filtered rows.
        XCTAssertTrue(WorkloadInventory.groups(items: items, query: "not present").isEmpty)
        XCTAssertEqual(
            WorkloadInventory.resolvedSelection(
                currentID: "container:same", selectedContainerID: "same", selectedMachineID: nil, items: items),
            "container:same")
    }

    func testOpenWorkloadPreservesExistingTypeSpecificSelections() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.containers = [makeContainer("api")]
        store.machines = [MachineEntry(name: "runner", state: "running")]
        store.selectedContainerID = "api"
        let vm = store.workloadItems.first { $0.kind == .machine }!
        store.openWorkload(vm)
        XCTAssertEqual(store.selectedWorkloadID, "machine:runner")
        XCTAssertEqual(store.selectedMachineID, "runner")
        XCTAssertEqual(store.selectedContainerID, "api")
        XCTAssertEqual(store.activeTab, .workloads)
        store.openWorkload(store.workloadItems.first { $0.kind == .container }!)
        XCTAssertEqual(store.selectedWorkloadID, "container:api")
        XCTAssertEqual(store.selectedMachineID, "runner")
    }

    func testRepeatedOpenOfTheSameWorkloadRequestsInspectionAgain() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.containers = [makeContainer("api")]
        let item = store.workloadItems[0]
        store.openWorkload(item)
        let firstRequest = store.workloadInspectionRequest
        let selectedID = store.selectedWorkloadID
        let selectedTab = store.activeTab

        // Back navigation leaves the route selected. Reopening it from the
        // tray or palette must still emit an observable inspection request.
        store.openWorkload(item)
        XCTAssertEqual(store.selectedWorkloadID, selectedID)
        XCTAssertEqual(store.activeTab, selectedTab)
        XCTAssertEqual(store.workloadInspectionRequest, firstRequest + 1)
    }

    func testStoppedRuntimeKeepsLastInventoryButMakesReadingsUnavailable() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.containers = [makeContainer("api")]
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.sampledAt = ISO8601DateFormatter().string(from: now)
        snapshot.containers = [makeStats("api", cpu: 125, memory: 1024)]
        store.applyForPreview(stats: snapshot)
        XCTAssertEqual(store.workloadItems[0].cpuCores, 1.25)

        var stopped = Micropod_V1_SystemStatus()
        stopped.status = "stopped"
        store.systemStatus = stopped
        let items = store.workloadItems
        XCTAssertEqual(items[0].state, "running", "Preserve the last observed inventory state")
        XCTAssertNil(items[0].cpuCores)
        XCTAssertNil(items[0].memoryBytes)
        XCTAssertNil(items[0].sampledAt)
        let summary = WorkloadInventory.summary(items: items, at: now, runtimeAvailable: false)
        XCTAssertEqual(summary.runningCount, 1, "This is a last-known count, labeled as such by the workspace")
        XCTAssertNil(summary.cpuCores)
        XCTAssertNil(summary.memoryBytes)
        XCTAssertEqual(summary.sampledWorkloadCount, 0)
    }

    func testUnavailableRuntimeDoesNotTurnAnEmptyInventoryIntoZeroUsage() {
        let summary = WorkloadInventory.summary(items: [], at: now, runtimeAvailable: false)
        XCTAssertNil(summary.cpuCores)
        XCTAssertNil(summary.memoryBytes)
        XCTAssertEqual(summary.runningCount, 0)
        XCTAssertEqual(summary.sampledWorkloadCount, 0)
    }

    private func inventory(
        _ containers: [Micropod_V1_Container], machines: [MachineEntry] = [],
        stats: [String: Micropod_V1_ContainerStats] = [:],
        machineStats: [String: Micropod_V1_MachineStats] = [:], sampledAt: Date? = nil
    ) -> [WorkloadItem] {
        WorkloadInventory.items(
            containers: containers, machines: machines, containerStats: stats,
            machineStats: machineStats, sampledAt: sampledAt ?? now)
    }

    private func makeContainer(_ name: String, state: String = "running", runtime: String = "apple")
        -> Micropod_V1_Container
    {
        var container = Micropod_V1_Container()
        container.id = name
        container.state = state
        container.runtime = runtime
        return container
    }

    private func makeStats(_ name: String, cpu: Double, memory: UInt64) -> Micropod_V1_ContainerStats {
        var stats = Micropod_V1_ContainerStats()
        stats.id = name
        stats.cpuPercent = cpu
        stats.memoryUsedBytes = memory
        return stats
    }
}
