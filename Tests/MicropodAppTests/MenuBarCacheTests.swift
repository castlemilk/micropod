import AppKit
import MicropodCore
import MicropodSharedFS
import SwiftUI
import Vision
import XCTest

@testable import MicropodApp

@MainActor
final class MenuBarCacheTests: XCTestCase {
    func testLegacyBuildContextSubtotalIsExplicitlyPartial() {
        let now = Date()
        let cache = CacheStore()
        cache.applyForPreview(
            CacheSnapshot(
                measuredAt: now, buildRoot: URL(fileURLWithPath: "/tmp/tray-fixture"),
                buildEntries: [],
                buildStats: BuildCacheStats(
                    entries: 20, contentBytes: 42_000, sharedBytes: 0, capBytes: 5 << 30,
                    unknownContentEntries: 10),
                buildDisabled: false, buildError: nil,
                package: SharedCacheSnapshot(
                    cacheRoot: "/tmp/tray-fixture", measuredAt: now, storedBytes: 0,
                    capBytes: 100, chunkCount: 0, activeMounts: [], keepEnabled: true, overCap: false),
                packageError: nil))
        let ci = CICacheStore()
        ci.applyForPreview(inventory([]))
        let summary = MenuBarCacheSummary(cache: cache, ci: ci, now: now)
        XCTAssertEqual(summary.build, "\(ByteFormat.string(UInt64(42_000))) known · partial")
        XCTAssertTrue(summary.status.contains("local partial"))
        XCTAssertTrue(summary.hasWarning)
    }

    func testAllocationIsLargestObservedFileAndMissingProxyIsUnknown() {
        let cache = CacheStore()
        cache.applyForPreview(nil)
        let ci = CICacheStore()
        ci.applyForPreview(
            inventory([volume("cf-cache-a", allocated: 51 << 30), volume("cf-cache-b", allocated: 2 << 30)]))
        let summary = MenuBarCacheSummary(cache: cache, ci: ci, now: Date())
        XCTAssertEqual(summary.allocation, CICacheByteFormat.string(51 << 30))
        XCTAssertNotEqual(summary.allocation, CICacheByteFormat.string(300 << 30))
        XCTAssertNotEqual(summary.allocation, CICacheByteFormat.string(53 << 30))
        XCTAssertEqual(summary.volumeCount, "2")
        XCTAssertEqual(summary.requests, "Unknown / Unknown")
        XCTAssertTrue(summary.status.contains("proxy counters unknown"))
    }

    func testGoldenResolutionCannotMasqueradeAsProxyRequestHits() throws {
        let cache = CacheStore()
        cache.applyForPreview(nil)
        let ci = CICacheStore()
        ci.applyForPreview(inventory([]), telemetry: try telemetry(local: nil, upstream: nil, golden: 999))
        XCTAssertEqual(MenuBarCacheSummary(cache: cache, ci: ci, now: Date()).requests, "Unknown / Unknown")
        ci.applyForPreview(inventory([]), telemetry: try telemetry(local: 0, upstream: 12, golden: 999))
        let summary = MenuBarCacheSummary(cache: cache, ci: ci, now: Date())
        XCTAssertEqual(summary.requests, "0 / 12")
        XCTAssertTrue(summary.status.contains("proxy recent"))
    }

    func testLocalSnapshotsCannotBorrowFreshnessFromCIAndProxy() throws {
        let cache = CacheStore()
        let ci = CICacheStore()
        ci.applyForPreview(inventory([]), telemetry: try telemetry(local: 124, upstream: 9))
        let now = Date()
        for (snapshotAge, packageAge, expected) in [
            (3600.0, 0.0, "local stale"), (0.0, 3600.0, "local stale"),
            (-60.0, 0.0, "local time invalid"), (0.0, -60.0, "local time invalid"),
            (0.0, 0.0, "local recent"),
        ] {
            cache.applyForPreview(
                CacheSnapshot(
                    measuredAt: now.addingTimeInterval(-snapshotAge),
                    buildRoot: URL(fileURLWithPath: "/tmp/tray-fixture"),
                    buildEntries: [],
                    buildStats: BuildCacheStats(entries: 0, contentBytes: 0, sharedBytes: 0, capBytes: 100),
                    buildDisabled: false, buildError: nil,
                    package: SharedCacheSnapshot(
                        cacheRoot: "/tmp/tray-fixture", measuredAt: now.addingTimeInterval(-packageAge),
                        storedBytes: 0, capBytes: 100, chunkCount: 0, activeMounts: [], keepEnabled: true,
                        overCap: false),
                    packageError: nil))
            let summary = MenuBarCacheSummary(cache: cache, ci: ci, now: now)
            XCTAssertTrue(summary.status.contains("CI recent · proxy recent"))
            XCTAssertTrue(summary.status.contains(expected), summary.status)
            XCTAssertEqual(summary.hasWarning, expected != "local recent")
        }
        cache.applyForPreview(nil)
        XCTAssertTrue(MenuBarCacheSummary(cache: cache, ci: ci, now: now).status.contains("local not measured"))
    }

    func testEmptyPartialAndUnavailableInventoryStayDistinct() {
        let cache = CacheStore()
        cache.applyForPreview(nil)
        let ci = CICacheStore()
        ci.applyForPreview(inventory([]))
        var summary = MenuBarCacheSummary(cache: cache, ci: ci, now: Date())
        XCTAssertEqual(summary.volumeCount, "0")
        XCTAssertEqual(summary.allocation, "None observed")
        ci.applyForPreview(inventory([], truncated: true))
        summary = MenuBarCacheSummary(cache: cache, ci: ci, now: Date())
        XCTAssertEqual(summary.volumeCount, "0 · partial")
        XCTAssertEqual(summary.allocation, "Unknown")
        ci.applyForPreview(nil, error: "Unsupported inventory")
        summary = MenuBarCacheSummary(cache: cache, ci: ci, now: Date())
        XCTAssertEqual(summary.volumeCount, "Unavailable")
        XCTAssertEqual(summary.allocation, "Unknown")
        XCTAssertTrue(summary.status.contains("CI unavailable"))
    }

    func testRetainedErrorAndOldCountersRemainExplicit() async throws {
        let cache = CacheStore()
        cache.applyForPreview(nil)
        let ci = CICacheStore()
        await ci.refresh(
            reader: MenuBarInventoryReader(
                snapshot: CICacheRead(
                    volumes: [volume("cf-cache-a", allocated: 51 << 30)], containers: [], truncated: false)),
            sourceID: "apple", telemetryReader: MenuBarCounterReader(telemetry: try telemetry(local: 124, upstream: 9)))
        await ci.refresh(
            reader: MenuBarFailingInventoryReader(), sourceID: "apple", telemetryReader: MenuBarFailingCounterReader())
        let retained = MenuBarCacheSummary(cache: cache, ci: ci, now: Date())
        XCTAssertEqual(retained.allocation, CICacheByteFormat.string(51 << 30))
        XCTAssertEqual(retained.requests, "124 / 9")
        XCTAssertTrue(retained.status.contains("CI unavailable · retained"))
        XCTAssertTrue(retained.status.contains("proxy unavailable · retained"))
        XCTAssertTrue(retained.hasWarning)

        let stale = CICacheStore()
        stale.applyForPreview(
            inventory([]), telemetry: try telemetry(local: 124, upstream: 9, sampledAt: Date().addingTimeInterval(-100))
        )
        XCTAssertTrue(
            MenuBarCacheSummary(cache: cache, ci: stale, now: Date()).status.contains("proxy stale/time unknown"))
    }

    func testCloseStopsPollingAndReopenStartsFreshRead() async throws {
        var reads = 0
        let observation = MenuBarCacheObservation(interval: .milliseconds(20))
        observation.open { reads += 1 }
        try await wait { reads == 1 }
        observation.close()
        observation.refreshNow()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(reads, 1, "A closed tray must not poll or manually refresh")
        observation.open { reads += 1 }
        try await wait { reads == 2 }
        observation.close()
    }

    func testRefreshCoalescesAndReopenWaitsThenReadsAfterInflightObservation() async throws {
        let gate = MenuBarReadGate()
        let observation = MenuBarCacheObservation()
        observation.open { await gate.read() }
        try await wait { gate.reads == 1 }
        for _ in 0..<4 { observation.refreshNow() }
        XCTAssertEqual(gate.reads, 1)
        observation.close()
        observation.open { await gate.read() }
        gate.release()
        try await wait { gate.reads == 2 }
        observation.close()
        gate.release()
    }

    func testManualRefreshAfterCompletedReadStartsNewObservation() async throws {
        var reads = 0
        let observation = MenuBarCacheObservation()
        observation.open { reads += 1 }
        try await wait { reads == 1 }
        observation.refreshNow()
        try await wait { reads == 2 }
        observation.close()
    }

    func testRemovingNativeCachePageCannotCancelSharedTrayObservation() async throws {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.cacheStore.applyForPreview(nil)
        let gate = MenuBarInventoryGate(
            snapshot: CICacheRead(
                volumes: [volume("cf-cache-shared", allocated: 51 << 30)], containers: [], truncated: false))
        let counterReader = MenuBarCounterReader(telemetry: try telemetry(local: 124, upstream: 9))
        let first = Task {
            await store.ciCacheStore.refresh(reader: gate, sourceID: "cli", telemetryReader: counterReader)
        }
        try await wait { store.ciCacheStore.isRefreshing }
        // The production CacheView uses the same cli source and coalesces onto
        // this fixture read. No real CLI, cache socket or loopback request runs.
        let hosting = NSHostingView(rootView: AnyView(CacheView(store: store)))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 820)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        let tray = MenuBarCacheObservation()
        tray.open {
            await store.ciCacheStore.refresh(reader: gate, sourceID: "cli", telemetryReader: counterReader)
        }
        try await Task.sleep(for: .milliseconds(30))
        hosting.rootView = AnyView(EmptyView())
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.ciCacheStore.isRefreshing, "Closing the main Cache page cannot cancel a shared tray read")
        tray.close()
        await gate.release()
        await first.value
        window.orderOut(nil)
        XCTAssertEqual(store.ciCacheStore.inventory?.volumes.first?.id, "cf-cache-shared")
        XCTAssertEqual(store.ciCacheStore.telemetry?.observations(for: CICacheSelection()).first?.value, 0)
    }

    func testNativePanelAppearanceRemovalAndReappearanceRefreshesWithoutRuntimeBootstrap() async throws {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.cacheStore.applyForPreview(nil)
        store.ciCacheStore.applyForPreview(inventory([]))
        let samples = [
            inventory([volume("cf-cache-reopen", allocated: 1 << 30)]),
            inventory([volume("cf-cache-reopen", allocated: 2 << 30)]),
        ]
        let counters = [try telemetry(local: 10, upstream: 1), try telemetry(local: 20, upstream: 2)]
        var reads = 0
        func panel() -> AnyView {
            AnyView(
                MenuBarPanelView(
                    store: store, activateRuntimeObservation: false,
                    cacheRefresh: {
                        reads += 1
                        let index = min(reads - 1, samples.count - 1)
                        store.ciCacheStore.applyForPreview(samples[index], telemetry: counters[index])
                    }
                ).environment(\.colorScheme, .dark))
        }
        let hosting = NSHostingView(rootView: panel())
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 640)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderBack(nil)
        defer {
            hosting.rootView = AnyView(EmptyView())
            window.orderOut(nil)
        }
        hosting.layoutSubtreeIfNeeded()
        try await wait { reads == 1 }
        try await Task.sleep(for: .milliseconds(20))
        let opened = try captureLifecycle(hosting, window: window, name: "opened")
        XCTAssertNotNil(opened.range(of: #"\b10\s*/\s*1\b"#, options: .regularExpression), opened)
        XCTAssertTrue(opened.contains(CICacheByteFormat.string(1 << 30)), opened)
        hosting.rootView = AnyView(EmptyView())
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(reads, 1)
        hosting.rootView = panel()
        hosting.layoutSubtreeIfNeeded()
        try await wait { reads == 2 }
        XCTAssertEqual(reads, 2)
        try await Task.sleep(for: .milliseconds(20))
        let reopened = try captureLifecycle(hosting, window: window, name: "reopened")
        XCTAssertNotNil(reopened.range(of: #"\b20\s*/\s*2\b"#, options: .regularExpression), reopened)
        XCTAssertTrue(reopened.contains(CICacheByteFormat.string(2 << 30)), reopened)
        XCTAssertNil(
            reopened.range(of: #"\b10\s*/\s*1\b"#, options: .regularExpression),
            "Reopening must visibly replace the earlier counters: \(reopened)")
    }

    private func captureLifecycle(_ hosting: NSHostingView<AnyView>, window: NSWindow, name: String) throws -> String {
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        XCTAssertEqual(fitting.width, 360, accuracy: 0.5)
        XCTAssertLessThanOrEqual(fitting.height, 640)
        hosting.frame = NSRect(origin: .zero, size: fitting)
        window.setContentSize(fitting)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/tmp/micropod-tray-lifecycle-\(name).png")
        try png.write(to: url)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected native/cache observation event within one second")
    }

    private func volume(_ id: String, allocated: UInt64 = 0) -> Micropod_V1_Volume {
        var result = Micropod_V1_Volume()
        result.id = id
        result.format = "ext4"
        result.sizeBytes = 300 << 30
        result.allocatedBytes = allocated
        return result
    }

    private func inventory(_ volumes: [Micropod_V1_Volume], truncated: Bool = false) -> CICacheInventorySnapshot {
        CICacheInventorySnapshot(
            read: CICacheRead(volumes: volumes, containers: [], truncated: truncated), sourceID: "apple",
            measuredAt: Date())
    }

    private func telemetry(local: Double?, upstream: Double?, golden: Double = 0, sampledAt: Date = Date()) throws
        -> CICacheTelemetry
    {
        let sampled = ISO8601DateFormatter().string(from: sampledAt)
        var metrics: [[String: Any]] = [
            [
                "name": "cache_volume_total", "type": "counter", "value": golden, "capturedAt": sampled,
                "attributes": ["outcome": "hit"],
            ]
        ]
        for (tier, value) in [("local", local), ("upstream", upstream)] {
            if let value {
                metrics.append([
                    "name": "depcache_requests_total", "type": "counter", "value": value, "capturedAt": sampled,
                    "attributes": ["tier": tier],
                ])
            }
        }
        return try CICacheTelemetry.decode(
            JSONSerialization.data(withJSONObject: ["ok": true, "metrics": metrics]), receivedAt: Date())
    }
}

@MainActor
private final class MenuBarReadGate {
    private(set) var reads = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func read() async {
        reads += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct MenuBarInventoryReader: CICacheInventoryReading {
    let snapshot: CICacheRead
    func read() async throws -> CICacheRead { snapshot }
}

private actor MenuBarInventoryGate: CICacheInventoryReading {
    let snapshot: CICacheRead
    private var continuation: CheckedContinuation<CICacheRead, Never>?
    init(snapshot: CICacheRead) { self.snapshot = snapshot }
    func read() async throws -> CICacheRead {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
private struct MenuBarCounterReader: CICacheTelemetryReading {
    let telemetry: CICacheTelemetry
    func read() async throws -> CICacheTelemetry { telemetry }
}
private struct MenuBarFailingInventoryReader: CICacheInventoryReading {
    func read() async throws -> CICacheRead { throw CICacheReadError.unavailable }
}
private struct MenuBarFailingCounterReader: CICacheTelemetryReading {
    func read() async throws -> CICacheTelemetry { throw CICacheReadError.unavailable }
}
