import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

final class CICacheInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_417_600)

    func testByteLabelsDoNotOverflowOrInventUnknownMeasurements() {
        XCTAssertEqual(CICacheByteFormat.string(nil), "Unknown")
        XCTAssertEqual(CICacheByteFormat.string(51 << 30), ByteFormat.string(UInt64(51 << 30)))
        XCTAssertTrue(CICacheByteFormat.string(UInt64.max).hasSuffix("bytes"))
    }

    func testSparseCapacityAndAllocationStaySeparateAndZeroIsUnknown() {
        let measured = volume("cf-cache-a", capacity: 300 << 30, allocated: 51 << 30)
        let unknown = volume("cf-cache-b", capacity: 300 << 30, allocated: 0)
        let snapshot = inventory([measured, unknown], containers: [])
        XCTAssertEqual(snapshot.volumes.first?.capacityBytes, 300 << 30)
        XCTAssertEqual(snapshot.volumes.first?.allocatedBytes, 51 << 30)
        XCTAssertNil(snapshot.volumes.last?.allocatedBytes)
        XCTAssertEqual(snapshot.volumes.last?.activityLabel, "No active reference observed")
        XCTAssertFalse(snapshot.isStale(at: now.addingTimeInterval(90)))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(91)))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(-10)))
    }

    func testRunningClonesAndDirectMountsReferenceGoldenWithoutSubstringAliases() {
        let golden = volume("cf-cache-a")
        let clone = container("job-a", "running", "/local/volume-clones/job-a/cf-cache-a.img")
        let direct = container("job-b", "stopping", golden.source)
        let alias = container("job-c", "running", "/local/volume-clones/job-c/cf-cache-a-extra.img")
        let stopped = container("job-d", "stopped", golden.id)
        let snapshot = inventory([golden], containers: [clone, direct, alias, stopped])
        XCTAssertEqual(snapshot.volumes.first?.activeContainers, ["job-a", "job-b"])
        XCTAssertEqual(snapshot.volumes.first?.activityLabel, "Active in 2 container(s)")
    }

    func testUnavailableReferencesAreUnknownAndNonCIVolumesAreExcluded() {
        var workspace = volume("cf-ws-a")
        workspace.labels = [:]
        var wrongFormat = volume("cf-cache-other")
        wrongFormat.format = "xfs"
        let snapshot = inventory([volume("cf-cache-a"), workspace, wrongFormat], containers: nil)
        XCTAssertEqual(snapshot.volumes.count, 1)
        XCTAssertFalse(snapshot.referencesAvailable)
        XCTAssertNil(snapshot.volumes.first?.activeContainers)
        XCTAssertEqual(snapshot.volumes.first?.activityLabel, "Active use unknown")
        XCTAssertTrue(inventory([], containers: []).volumes.isEmpty)
    }

    func testProjectAndOwnerSelectionUseExactIdentity() {
        let snapshot = inventory(
            [
                volume("cf-cache-a", project: "alpha", owner: "rig-a:/state"),
                volume("cf-cache-b", project: "alpha-extra", owner: "rig-a:/state"),
                volume("cf-cache-c", project: "alpha", owner: "rig-b:/state"),
            ], containers: [])
        let selected = snapshot.selected(CICacheSelection(project: "alpha", owner: "rig-a:/state"))
        XCTAssertEqual(selected.map(\.id), ["cf-cache-a"])
        XCTAssertTrue(snapshot.selected(CICacheSelection(project: "foreign", owner: "")).isEmpty)
    }

    func testBoundedInventoryNeverClaimsNoActiveUseFromPartialReferences() {
        let read = RuntimeCICacheReader.bounded(
            volumes: Array(repeating: volume("cf-cache-a"), count: 513), containers: [])
        XCTAssertEqual(read.volumes.count, 512)
        XCTAssertTrue(read.truncated)
        XCTAssertNil(read.containers)
        let snapshot = CICacheInventorySnapshot(read: read, sourceID: "local/native", measuredAt: now)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertNil(snapshot.volumes.first?.activeContainers)
        let excessReferences = RuntimeCICacheReader.bounded(
            volumes: [volume("cf-cache-a")],
            containers: Array(repeating: container("job", "running", "cf-cache-a"), count: 513))
        XCTAssertNil(excessReferences.containers)
    }

    func testCounterScopeExcludesOtherProjectsAndUnattributedOwner() throws {
        let telemetry = try counters([
            metric("cache_volume_total", 7, ["project": "alpha", "outcome": "hit"]),
            metric("cache_volume_total", 100, ["project": "alpha-extra", "outcome": "hit"]),
            metric("cache_store_total", 300, ["outcome": "hit"]),
            metric("depcache_requests_total", 10, ["tier": "local"]),
        ])
        let project = telemetry.observations(for: CICacheSelection(project: "alpha"))
        XCTAssertEqual(project.map(\.value), [7])
        XCTAssertEqual(project.first?.freshness(at: now), "Recent sample")
        XCTAssertEqual(project.first?.freshness(at: now.addingTimeInterval(100)), "Stale sample")
        XCTAssertEqual(project.first?.freshness(at: now.addingTimeInterval(-10)), "Sample time invalid")
        XCTAssertTrue(telemetry.observations(for: CICacheSelection(project: "foreign")).isEmpty)
        XCTAssertTrue(telemetry.observations(for: CICacheSelection(owner: "rig-a:/state")).isEmpty)
        XCTAssertEqual(telemetry.observations(for: CICacheSelection()).map(\.value), [107, 300, 10])
    }

    func testMissingZeroStaleAndInvalidCountersAreDistinct() throws {
        XCTAssertTrue(try counters([]).observations(for: CICacheSelection()).isEmpty)
        let zero = try counters([metric("cache_volume_total", 0, ["outcome": "hit"], sampled: false)])
        XCTAssertEqual(zero.observations(for: CICacheSelection()).first?.value, 0)
        XCTAssertEqual(zero.observations(for: CICacheSelection()).first?.freshness(at: now), "Sample time unknown")
        XCTAssertThrowsError(try counters([metric("cache_volume_total", -1, ["outcome": "hit"])]))
        XCTAssertThrowsError(try CICacheTelemetry.decode(Data(repeating: 32, count: 131_073), receivedAt: now))
        XCTAssertThrowsError(try CICacheTelemetry.decode(Data("{}".utf8), receivedAt: now))
    }

    @MainActor
    func testReadErrorRetainsPreviousObservationButSourceSwitchDoesNot() async throws {
        let store = CICacheStore()
        let reader = FixtureCIReader(
            snapshot: CICacheRead(volumes: [volume("cf-cache-a")], containers: [], truncated: false))
        let telemetry = FixtureCounterReader(value: try counters([metric("cache_volume_total", 5, ["outcome": "hit"])]))
        await store.refresh(reader: reader, sourceID: "local/native-a", telemetryReader: telemetry)
        let previous = store.inventory?.measuredAt
        await store.refresh(
            reader: FailingCIReader(), sourceID: "local/native-a", telemetryReader: FailingCounterReader())
        XCTAssertEqual(store.inventory?.measuredAt, previous)
        XCTAssertEqual(store.inventory?.volumes.count, 1)
        XCTAssertNotNil(store.inventoryError)
        XCTAssertNotNil(store.telemetryError)
        await store.refresh(
            reader: FailingCIReader(), sourceID: "local/native-b", telemetryReader: FailingCounterReader())
        XCTAssertNil(store.inventory, "Never carry an old rig/backend inventory into a new source")
        XCTAssertNil(store.telemetry)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testPreviewCannotReadRealServicesOrReplaceItsSnapshot() async {
        let store = CICacheStore()
        let snapshot = inventory([volume("cf-cache-preview")], containers: nil)
        store.applyForPreview(snapshot)
        await store.refresh(reader: FailingCIReader(), sourceID: "other", telemetryReader: FailingCounterReader())
        XCTAssertEqual(store.inventory?.sourceID, "local/native")
        XCTAssertEqual(store.inventory?.volumes.first?.id, "cf-cache-preview")
        XCTAssertNil(store.inventoryError)
    }

    @MainActor
    func testLateReadCannotReplaceChangedSource() async {
        let gate = GatedCIReader()
        let store = CICacheStore()
        let older = Task {
            await store.refresh(reader: gate, sourceID: "rig-a", telemetryReader: FailingCounterReader())
        }
        await gate.waitUntilReading()
        await store.refresh(
            reader: FixtureCIReader(
                snapshot: CICacheRead(volumes: [volume("cf-cache-new")], containers: [], truncated: false)),
            sourceID: "rig-b", telemetryReader: FailingCounterReader())
        await gate.release()
        await older.value
        XCTAssertEqual(store.inventory?.sourceID, "rig-b")
        XCTAssertEqual(store.inventory?.volumes.first?.id, "cf-cache-new")
    }

    private func inventory(_ volumes: [Micropod_V1_Volume], containers: [Micropod_V1_Container]?)
        -> CICacheInventorySnapshot
    {
        CICacheInventorySnapshot(
            read: CICacheRead(volumes: volumes, containers: containers, truncated: false), sourceID: "local/native",
            measuredAt: now)
    }

    private func volume(
        _ id: String, capacity: UInt64 = 300 << 30, allocated: UInt64 = 51 << 30,
        project: String = "alpha", owner: String = "rig-a:/state"
    ) -> Micropod_V1_Volume {
        .with {
            $0.id = id
            $0.format = "ext4"
            $0.sizeBytes = capacity
            $0.allocatedBytes = allocated
            $0.source = "/local/volumes/\(id)/volume.img"
            $0.labels = ["cuttle.project": project, "cuttle.owner": owner]
        }
    }

    private func container(_ id: String, _ state: String, _ source: String) -> Micropod_V1_Container {
        .with {
            $0.id = id
            $0.state = state
            $0.mounts = [.with { $0.source = source }]
        }
    }

    private func metric(_ name: String, _ value: Double, _ attributes: [String: String], sampled: Bool = true)
        -> [String: Any]
    {
        var metric: [String: Any] = ["name": name, "type": "counter", "value": value, "attributes": attributes]
        if sampled { metric["capturedAt"] = ISO8601DateFormatter().string(from: now) }
        return metric
    }

    private func counters(_ metrics: [[String: Any]]) throws -> CICacheTelemetry {
        try CICacheTelemetry.decode(
            JSONSerialization.data(withJSONObject: ["ok": true, "metrics": metrics]), receivedAt: now)
    }
}

private struct FixtureCIReader: CICacheInventoryReading {
    let snapshot: CICacheRead
    func read() async throws -> CICacheRead { snapshot }
}
private struct FailingCIReader: CICacheInventoryReading {
    func read() async throws -> CICacheRead { throw CICacheReadError.unavailable }
}
private struct FixtureCounterReader: CICacheTelemetryReading {
    let value: CICacheTelemetry
    func read() async throws -> CICacheTelemetry { value }
}
private struct FailingCounterReader: CICacheTelemetryReading {
    func read() async throws -> CICacheTelemetry { throw CICacheReadError.unavailable }
}
private actor GatedCIReader: CICacheInventoryReading {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var reading = false
    func read() async throws -> CICacheRead {
        reading = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { continuation = $0 }
        return CICacheRead(volumes: [], containers: [], truncated: false)
    }
    func waitUntilReading() async {
        if reading { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
