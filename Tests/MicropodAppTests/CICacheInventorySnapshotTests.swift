import AppKit
import MicropodCore
import MicropodSharedFS
import SwiftUI
import Vision
import XCTest

@testable import MicropodApp

/// Deterministic native rendering: fixtures only, no live cache/RPC access.
@MainActor
final class CICacheInventorySnapshotTests: XCTestCase {
    func testVisibleCacheViewportShowsStorageBeforeLegacyJobReports() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = AppStore(dependencies: AppDependencies(client: fixture.client))
        store.cacheStore.applyForPreview(nil, error: "Build context snapshot unavailable.")
        let ci = preview()
        store.ciCacheStore.applyForPreview(ci.inventory, telemetry: ci.telemetry)
        for width in [720, 1280] {
            let name = "ci-cache-visible-viewport-\(width)"
            try render(CacheView(store: store), width: width, height: 820, scheme: .dark, name: name)
            let text = try recognizedText(name)
            // Vision can recognize the narrow capital I as a lowercase l or numeral 1.
            XCTAssertNotNil(
                text.range(of: #"\b2 C[I1l] volumes\b"#, options: .regularExpression),
                "CI inventory count must be visible without scrolling: \(text)")
            XCTAssertTrue(
                text.contains("Host allocated"),
                "Backing-file allocation must be visible before long job reports: \(text)")
        }
        try render(
            CacheView(store: store), width: 720, height: 820, scheme: .dark,
            name: "ci-cache-visible-scrolled", scrollOffset: 700)
        let scrolled = try recognizedText("ci-cache-visible-scrolled")
        XCTAssertTrue(scrolled.contains("cache activity"), "Scrolling must reach the activity panel: \(scrolled)")
        XCTAssertTrue(scrolled.contains("local requests"), "Measured activity must remain readable: \(scrolled)")
    }

    func testUnsupportedHistoryDoesNotHideStorageOrInventUsage() throws {
        let cache = preview()
        cache.applyForPreview(
            cache.inventory,
            history: CICacheHistorySnapshot(
                state: CICacheHistoryState(), error: "Producer history unsupported.",
                persisted: false, traversalLimited: false))
        try render(
            CICacheInventoryView(cache: cache), width: 720, height: 1800, scheme: .light,
            name: "ci-cache-unsupported-history")
        let text = try recognizedText("ci-cache-unsupported-history")
        XCTAssertTrue(text.contains("Host allocated"), text)
        XCTAssertTrue(text.contains("history unsupported"), text)
        XCTAssertTrue(text.contains("Unknown"), "Missing measurements must remain unknown: \(text)")
        XCTAssertFalse(text.contains("No CI named volumes"), text)
    }

    func testInventoryErrorKeepsRetainedAllocationMarkedStale() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = AppStore(dependencies: AppDependencies(client: fixture.client))
        store.cacheStore.applyForPreview(nil, error: "Build context snapshot unavailable.")
        let cache = preview()
        store.ciCacheStore.applyForPreview(cache.inventory, error: "Named-volume inventory unavailable.")
        try render(
            CacheView(store: store), width: 720, height: 820, scheme: .dark,
            name: "ci-cache-visible-stale-error")
        let text = try recognizedText("ci-cache-visible-stale-error")
        XCTAssertTrue(text.contains("inventory unavailable"), text)
        XCTAssertTrue(text.contains("Stale observation"), text)
        XCTAssertTrue(text.contains("Host allocated"), text)
        XCTAssertFalse(text.contains("No CI named volumes"), text)
    }

    func testVisibleCacheViewportDistinguishesEmptyFromUnavailableInventory() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        for unavailable in [false, true] {
            let store = AppStore(dependencies: AppDependencies(client: fixture.client))
            store.cacheStore.applyForPreview(nil, error: "Build context snapshot unavailable.")
            let inventory =
                unavailable
                ? nil
                : CICacheInventorySnapshot(
                    read: CICacheRead(volumes: [], containers: [], truncated: false),
                    sourceID: "local/native", measuredAt: Date())
            store.ciCacheStore.applyForPreview(
                inventory, error: unavailable ? "Named-volume inventory unavailable." : nil)
            let name = "ci-cache-visible-\(unavailable ? "unavailable" : "empty")"
            try render(CacheView(store: store), width: 1280, height: 820, scheme: .light, name: name)
            let text = try recognizedText(name)
            XCTAssertTrue(text.contains("Build contexts"), "Initial viewport must include the page header: \(text)")
            if unavailable {
                XCTAssertTrue(text.contains("inventory unavailable"), text)
                XCTAssertFalse(text.contains("named volumes observed"), "Unavailable must not become empty: \(text)")
            } else {
                XCTAssertTrue(
                    text.contains("named volumes observed"), "Measured empty inventory must be visible: \(text)")
            }
        }
    }

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

    func testRenderAttributedProducerResolutionAndLateSaveOutcomes() throws {
        let cache = preview()
        let identity = String(repeating: "a", count: 64)
        let time = ISO8601DateFormatter().string(from: Date())
        let store: [String: Any] = [
            "cacheId": identity, "volumeName": "cf-cache-example", "resolveMs": 0,
            "ecosystem": "go", "kind": "build", "mountPath": "/cache/go", "golden": "hit", "commit": "queued",
        ]
        let job: [String: Any] = [
            "attemptId": "job-example", "nodeId": "build", "projectId": "example-project",
            "runId": "run-example", "runnerId": "rig-example", "observedAt": time,
            "report": [
                "stores": [store],
                "proxy": [
                    "requests": 100, "localHits": 75,
                    "upstreamFetches": 25, "upstreamMetadataFetches": 0,
                    "upstreamBytes": 33554432, "servedBytes": 134217728,
                ],
            ],
        ]
        func save(_ outcome: String, clone: String) -> [String: Any] {
            [
                "attemptId": "job-example", "nodeId": "build", "projectId": "example-project", "runId": "run-example",
                "runnerId": "rig-example", "observedAt": time,
                "save": [
                    "cacheId": identity, "volumeName": "cf-cache-example", "containerId": clone,
                    "outcome": outcome, "durationMs": 24, "finishedAt": time, "allocatedBytes": 1073741824,
                ],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true, "metrics": [], "attempts": [job],
            "saves": [save("committed", clone: "clone-a"), save("unknown", clone: "clone-b")],
        ])
        let telemetry = try CICacheTelemetry.decode(data, receivedAt: Date())
        cache.applyForPreview(cache.inventory, telemetry: telemetry)
        try render(
            CICacheInventoryView(cache: cache, stats: runtimeStats()), width: 1200, height: 3000,
            scheme: .dark, name: "ci-cache-producer-resolution-saves")
        XCTAssertEqual(telemetry.attempts.first?.report.stores.first?.resolveMs, 0)
        XCTAssertEqual(telemetry.saveReports(for: .init()).count, 2)
        XCTAssertEqual(CICacheRecentActivity.observations(telemetry, selection: .init()).first?.saveCost, 48)
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

    func testRenderDurableHistoryWithRestartLossAndUnavailableProtection() throws {
        let page = try CICacheHistoryPage.decode(
            Data(
                """
                {"schemaVersion":"cache-history-v1","historyId":"00000000-0000-0000-0000-000000000001",
                 "sessionId":"00000000-0000-0000-0000-000000000002","createdAt":"2026-10-08T22:00:00Z",
                 "lastSequence":2,"sessions":2,"evictedRecords":9,"lostRecords":3,"retainedBytes":1024,
                 "retainedRecords":2,"status":"available","complete":false,"leaseCoverage":"unavailable",
                 "coverageReasons":["partial-instrumentation","restart-gap-unmeasured","retention-truncated","no-authoritative-lease-snapshot"],
                 "pendingRecords":2,"unpersistedLoss":1,"oldestSequence":1,"nextAfter":2,"truncatedBefore":true,
                 "events":[{"sequence":1,"sessionId":"00000000-0000-0000-0000-000000000002",
                  "recordedAt":"2026-10-08T22:00:00Z","kind":"attempt",
                  "attempt":{"runnerId":"rig-fixture","projectId":"alpha","runId":"run-fixture",
                   "attemptId":"attempt-fixture","nodeId":"build","observedAt":"2026-10-08T22:00:00Z",
                   "report":{"trust":"trusted","stores":[{"kind":"volume","mountPath":"/cache","golden":"hit",
                    "cacheId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","volumeName":"cf-cache-node-fixture","resolveMs":0}]}}},
                  {"sequence":2,"sessionId":"00000000-0000-0000-0000-000000000002","recordedAt":"2026-10-08T22:00:00Z","kind":"save",
                   "save":{"runnerId":"rig-fixture","projectId":"alpha","runId":"run-fixture","attemptId":"attempt-fixture","nodeId":"build",
                    "save":{"cacheId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","volumeName":"cf-cache-node-fixture",
                     "containerId":"job-fixture","outcome":"unknown","durationMs":2,"finishedAt":"2026-10-08T22:00:00Z"}}}]}
                """.utf8))
        var state = CICacheHistoryState()
        state.historyId = page.historyId
        state.sessionId = page.sessionId
        state.after = 2
        state.events = page.events ?? []
        state.summary = page
        state.sampledAt = Date()
        state.gaps = ["producer-restart-gap", "producer-retention-truncated", "producer-observations-lost"]
        let history = CICacheHistorySnapshot(state: state, error: nil, persisted: true, traversalLimited: true)
        for (width, scheme) in [(720, ColorScheme.light), (1200, .dark)] {
            let cache = CICacheStore()
            cache.applyForPreview(nil, history: history)
            try render(
                CICacheInventoryView(cache: cache), width: width, height: 2300, scheme: scheme,
                name: "ci-cache-durable-history-\(width)")
        }
        XCTAssertEqual(history.retentionBlockers.count, 2)
        XCTAssertNil(history.telemetry.saves.first?.save.acknowledgedAllocation)
    }

    private func recognizedText(_ name: String) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: URL(fileURLWithPath: "/tmp/\(name).png"), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func render<Content: View>(
        _ view: Content, width: Int, height: Int, scheme: ColorScheme, name: String,
        scrollOffset: CGFloat? = nil
    ) throws {
        let hosting = NSHostingView(
            rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
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
        if let scroll = firstScrollView(in: hosting) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        if let scrollOffset {
            let scroll = try XCTUnwrap(firstScrollView(in: hosting))
            let document = try XCTUnwrap(scroll.documentView)
            let maximum = document.bounds.height - scroll.contentView.bounds.height
            XCTAssertGreaterThan(maximum, 0, "Cache content must be scrollable at a narrow window width")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOffset, maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
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

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }
}
