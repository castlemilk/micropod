import MicropodCore
import Observation
import XCTest

@testable import MicropodApp

@MainActor
final class AppStorePerformanceTests: XCTestCase {
    func testRepeatedUnchangedRuntimeStatusKeepsWarmWorkloadMetrics() {
        let store = AppStore()
        defer { store.stopPollers() }
        store.clientAvailable = true
        var status = Micropod_V1_SystemStatus()
        status.status = "running"
        store.systemStatus = status
        _ = store.workloadItems
        let revision = store.workloadMetricsRevision
        for _ in 0..<100 {
            store.clientAvailable = true
            store.systemStatus = status
        }
        XCTAssertEqual(store.workloadMetricsRevision, revision)
        status.apiServerVersion = "updated health metadata"
        store.systemStatus = status
        XCTAssertEqual(store.workloadMetricsRevision, revision)
        status.status = "stopped"
        store.systemStatus = status
        XCTAssertGreaterThan(store.workloadMetricsRevision, revision)
    }

    func testCachedWorkloadReadsStillObserveInventoryChanges() {
        let store = AppStore()
        defer { store.stopPollers() }
        _ = store.workloadItems
        let changed = expectation(description: "cached inventory invalidates")
        withObservationTracking {
            _ = store.workloadItems
        } onChange: {
            changed.fulfill()
        }
        var container = Micropod_V1_Container()
        container.id = "new-container"
        store.containers = [container]
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(store.workloadItems.first?.name, "new-container")
    }

    func testCachedReadsObserveNewMetricsAndPreserveMetadataOnUnchangedLists() {
        let store = AppStore()
        defer { store.stopPollers() }
        var container = Micropod_V1_Container()
        container.id = "running-container"
        container.state = "running"
        store.containers = [container]
        var status = Micropod_V1_SystemStatus()
        status.status = "running"
        store.systemStatus = status
        let metadataRevision = store.workloadMetadataRevision
        store.containers = [container]
        XCTAssertEqual(store.workloadMetadataRevision, metadataRevision)
        _ = store.workloadItems
        let changed = expectation(description: "cached metrics invalidate")
        withObservationTracking {
            _ = store.workloadItems
        } onChange: {
            changed.fulfill()
        }
        var stats = Micropod_V1_ContainerStats()
        stats.id = container.id
        stats.cpuPercent = 125
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.containers = [stats]
        store.applyForPreview(stats: snapshot)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(store.workloadItems.first?.cpuCores, 1.25)
    }

    func testVisibilityAggregatesAllMainWindows() {
        let store = AppStore()
        defer { store.stopPollers() }
        let first = UUID()
        let second = UUID()
        store.setMainWindowVisible(true, windowID: first)
        store.setMainWindowVisible(true, windowID: second)
        store.setMainWindowVisible(false, windowID: first)
        XCTAssertTrue(store.mainWindowVisible)
        store.setMainWindowVisible(false, windowID: second)
        XCTAssertFalse(store.mainWindowVisible)
    }

    func testHiddenCadenceHasThirtySecondFloorAndInvalidPreferencesCannotSpin() {
        for configured in [0, -1, Double.nan, Double.infinity, 0.001, 3, 5, 60] {
            let cadence = AppStore.statsPollingCadence(configured: configured)
            XCTAssertGreaterThanOrEqual(cadence.visible, 1)
            XCTAssertLessThanOrEqual(cadence.visible, 5)
            XCTAssertGreaterThanOrEqual(cadence.hidden, 30)
        }
        XCTAssertEqual(AppStore.statsPollingCadence(configured: 5).hidden, 30)
        XCTAssertEqual(AppStore.statsPollingCadence(configured: 60).hidden, 60)
    }
}
