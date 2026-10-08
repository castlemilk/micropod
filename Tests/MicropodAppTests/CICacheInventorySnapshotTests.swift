import AppKit
import MicropodCore
import MicropodSharedFS
import SwiftUI
import XCTest

@testable import MicropodApp

/// Deterministic native rendering: fixtures only, no live cache/RPC access.
@MainActor
final class CICacheInventorySnapshotTests: XCTestCase {
    func testRenderSparseActiveAndUnknownInventoryAtWindowWidths() throws {
        for width in [720, 1200] {
            for scheme in [ColorScheme.light, .dark] {
                let cache = preview()
                try render(
                    CICacheInventoryView(cache: cache, stats: runtimeStats()), width: width, height: 2400,
                    scheme: scheme,
                    name: "ci-cache-\(width)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testRenderEmptyUnavailableAndStaleInventories() throws {
        let empty = CICacheStore()
        empty.applyForPreview(
            CICacheInventorySnapshot(
                read: CICacheRead(volumes: [], containers: [], truncated: false),
                sourceID: "local/native", measuredAt: Date()))
        try render(CICacheInventoryView(cache: empty), width: 720, height: 500, scheme: .light, name: "ci-cache-empty")
        let unavailable = CICacheStore()
        unavailable.applyForPreview(nil, error: "Named-volume inventory unavailable.")
        try render(
            CICacheInventoryView(cache: unavailable), width: 720, height: 500, scheme: .dark,
            name: "ci-cache-unavailable")
        let stale = preview(stale: true)
        try render(CICacheInventoryView(cache: stale), width: 720, height: 2400, scheme: .dark, name: "ci-cache-stale")
    }

    func testRenderCachePageWithZeroSharedChunksAndActiveCIVolume() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = AppStore(dependencies: AppDependencies(client: fixture.client))
        store.cacheStore.applyForPreview(
            CacheSnapshot(
                measuredAt: Date(), buildRoot: fixture.directory, buildEntries: [], buildStats: .empty,
                buildDisabled: false, buildError: nil,
                package: SharedCacheSnapshot(
                    cacheRoot: "/fixture/packages", measuredAt: Date(), storedBytes: 0, capBytes: 10 << 30,
                    chunkCount: 0, activeMounts: [], keepEnabled: false, overCap: false), packageError: nil))
        let ci = preview()
        store.ciCacheStore.applyForPreview(ci.inventory, telemetry: ci.telemetry)
        store.applyForPreview(stats: runtimeStats())
        try render(CacheView(store: store), width: 720, height: 1100, scheme: .light, name: "ci-cache-page-zero-shared")
        XCTAssertEqual(store.cacheStore.snapshot?.package?.storedBytes, 0)
        XCTAssertEqual(store.ciCacheStore.telemetry?.attempts.last?.report.proxy?.localHits, 75)
        XCTAssertEqual(store.ciCacheStore.inventory?.volumes.first?.allocatedBytes, 51 << 30)
    }

    func testRenderCachePageKeepsCIInventoryWhenOtherCachesAreUnavailable() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = AppStore(dependencies: AppDependencies(client: fixture.client))
        store.cacheStore.applyForPreview(nil, error: "Build context snapshot unavailable.")
        let ci = preview()
        store.ciCacheStore.applyForPreview(ci.inventory, telemetry: ci.telemetry)
        store.applyForPreview(stats: runtimeStats())
        try render(
            CacheView(store: store), width: 720, height: 1100, scheme: .light,
            name: "ci-cache-page-unavailable-shared")
        XCTAssertNil(store.cacheStore.snapshot)
        XCTAssertNotNil(store.cacheStore.error)
        XCTAssertEqual(store.ciCacheStore.inventory?.volumes.first?.allocatedBytes, 51 << 30)
    }

    private func preview(stale: Bool = false) -> CICacheStore {
        let date = Date().addingTimeInterval(stale ? -300 : 0)
        let golden = Micropod_V1_Volume.with {
            $0.id = "cf-cache-trusted-docker-example-volume"
            $0.format = "ext4"
            $0.sizeBytes = 300 << 30
            $0.allocatedBytes = 51 << 30
            $0.source = "/Users/example/Library/Application Support/com.apple.container/volumes/\($0.id)/volume.img"
            $0.labels = [
                "cuttle.project": "example-project",
                "cuttle.owner": "local-rig:/Users/example/.cuttlefish/runner-state",
                "cuttle.ecosystem": "docker",
                "cuttle.key": "example-lock-digest", "cuttle.scope": "project", "cuttle.trust": "trusted",
            ]
        }
        var unknown = golden
        unknown.id = "cf-cache-trusted-build-allocation-not-reported"
        unknown.sizeBytes = 124 << 30
        unknown.allocatedBytes = 0
        unknown.source = "/fixture/volumes/\(unknown.id)/volume.img"
        let job = Micropod_V1_Container.with {
            $0.id = "cf-attempt-01"
            $0.state = "running"
            $0.mounts = [.with { $0.source = "/fixture/volume-clones/cf-attempt-01/\(golden.id).img" }]
        }
        let snapshot = CICacheInventorySnapshot(
            read: CICacheRead(volumes: [golden, unknown], containers: [job], truncated: false),
            sourceID: "local/native", measuredAt: date)
        let time = ISO8601DateFormatter().string(from: date)
        let values: [(String, Double, [String: String])] = [
            ("cache_volume_total", 42, ["outcome": "hit", "project": "example-project"]),
            ("cache_volume_total", 8, ["outcome": "created", "project": "example-project"]),
            ("cache_store_total", 30, ["outcome": "hit"]),
            ("cache_store_total", 7, ["outcome": "cold"]),
            ("cache_store_total", 3, ["outcome": "seeded"]),
            ("depcache_requests_total", 75, ["tier": "local", "eco": "go"]),
            ("depcache_requests_total", 25, ["tier": "upstream", "eco": "go"]),
            ("depcache_requests_total", 2, ["tier": "error", "eco": "go"]),
            ("depcache_bytes_total", Double(128 << 20), ["source": "local", "eco": "go"]),
            ("depcache_bytes_total", Double(32 << 20), ["source": "upstream", "eco": "go"]),
        ]
        let counters = values.map { name, value, attributes in
            CICacheCounter(name: name, type: "counter", value: value, capturedAt: time, attributes: attributes)
        }
        let attempts = try! CICacheTelemetry.decode(
            Data(
                #"{"ok":true,"metrics":[],"attempts":[{"attemptId":"job-without-proxy-report","nodeId":"test","report":{"stores":[{"kind":"build","ecosystem":"go","mountPath":"/cache/go","golden":"cold","commit":"not-committed"}]}},{"attemptId":"warm-install-job","nodeId":"install","report":{"stores":[{"kind":"dep","ecosystem":"npm","mountPath":"/cache/npm","golden":"hit","commit":"queued"}],"proxy":{"requests":100,"localHits":75,"upstreamFetches":25,"upstreamMetadataFetches":0,"upstreamBytes":33554432,"servedBytes":134217728}}}]}"#
                    .utf8), receivedAt: date
        ).attempts
        let cache = CICacheStore()
        cache.applyForPreview(
            snapshot, telemetry: CICacheTelemetry(receivedAt: date, counters: counters, attempts: attempts))
        return cache
    }

    private func runtimeStats() -> Micropod_V1_StatsSnapshot {
        .with {
            $0.sampledAt = ISO8601DateFormatter().string(from: Date())
            $0.containers = [
                .with {
                    $0.id = "cf-attempt-01"
                    $0.blockIoObserved = true
                    $0.blockWriteBytes = 128 << 10
                }
            ]
        }
    }

    func testRenderJobWithUnknownProxyAndColdStore() throws {
        let cache = preview()
        let source = try XCTUnwrap(cache.telemetry)
        cache.applyForPreview(
            cache.inventory,
            telemetry: CICacheTelemetry(
                receivedAt: source.receivedAt, counters: [], attempts: Array(source.attempts.prefix(1))))
        try render(
            CICacheInventoryView(cache: cache), width: 720, height: 2200, scheme: .light,
            name: "ci-cache-job-unknown-cold")
        XCTAssertNil(cache.telemetry?.attempts.first?.report.proxy)
        XCTAssertEqual(cache.telemetry?.attempts.first?.report.stores.first?.golden, "cold")
    }

    private func render<Content: View>(
        _ view: Content, width: Int, height: Int, scheme: ColorScheme, name: String
    ) throws {
        let hosting = NSHostingView(
            rootView: view.padding(24)
                .background(Tokens.Palette.canvas).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en")))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("Native cache inventory did not render")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5000)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, width)
        try png.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}
