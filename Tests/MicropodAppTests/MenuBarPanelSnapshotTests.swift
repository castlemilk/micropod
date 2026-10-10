import AppKit
import MicropodCore
import MicropodSharedFS
import SwiftUI
import Vision
import XCTest

@testable import MicropodApp

/// Hosting-view snapshots check panel sizing and appearance. The status-item
/// bridge needs a separate native MenuBarExtra smoke check; it ignores shapes
/// that render normally here. PNGs are review artifacts, not golden images.
final class MenuBarPanelSnapshotTests: XCTestCase {
    @MainActor
    func testPanelFittingSizeAndLightDarkPreviews() throws {
        for variant in ["populated", "empty", "unsupported", "unavailable", "retained-error", "stale-local"] {
            for scheme in [ColorScheme.light, .dark] {
                let store = makeRunningStore(client: AppTestCLI.makeFailing())
                if ["populated", "retained-error", "stale-local"].contains(variant) { populatePanel(store) }
                if variant == "stale-local", let snapshot = store.cacheStore.snapshot {
                    store.cacheStore.applyForPreview(
                        CacheSnapshot(
                            measuredAt: Date().addingTimeInterval(-3600), buildRoot: snapshot.buildRoot,
                            buildEntries: snapshot.buildEntries, buildStats: snapshot.buildStats,
                            buildDisabled: snapshot.buildDisabled, buildError: snapshot.buildError,
                            package: snapshot.package, packageError: snapshot.packageError))
                }
                if variant == "empty" || variant == "unsupported" {
                    store.ciCacheStore.applyForPreview(
                        CICacheInventorySnapshot(
                            read: CICacheRead(volumes: [], containers: [], truncated: false),
                            sourceID: "apple", measuredAt: Date()))
                }
                if variant == "retained-error" {
                    store.ciCacheStore.applyForPreview(
                        store.ciCacheStore.inventory, telemetry: store.ciCacheStore.telemetry,
                        error: "Named-volume inventory unavailable.",
                        telemetryError: "Local runner counters unavailable.")
                }
                if variant == "unavailable" {
                    store.clientAvailable = false
                    store.systemStatus = nil
                    store.machineError = "Runtime unavailable"
                    store.ciCacheStore.applyForPreview(nil, error: "Named-volume inventory unavailable.")
                }
                let name = "micropod-tray-\(variant)-\(scheme == .dark ? "dark" : "light")"
                let size = try render(
                    MenuBarPanelView(store: store, activateRuntimeObservation: false),
                    scheme: scheme, name: name)
                XCTAssertLessThanOrEqual(size.width, 360.5, name)
                XCTAssertGreaterThanOrEqual(size.width, 359.5, name)
                XCTAssertGreaterThan(size.height, 250, name)
                XCTAssertLessThanOrEqual(size.height, 640, name)
                let text = try recognizedText(name)
                // Vision can confuse i/l and f/t in 10-point metadata. These
                // bounded patterns still require the label to be rendered.
                for label in [
                    "Largest file allocation", "Host requests", "SharedFS packages", #"bene[ft]it unknown"#,
                    variant == "unavailable" ? "Last seen compute" : "Running compute", "Active jobs", "Unknown",
                ] {
                    XCTAssertNotNil(
                        text.range(of: label, options: .regularExpression),
                        "Cache scope must remain visible at tray dimensions: \(text)")
                }
                if variant == "populated" {
                    XCTAssertNotNil(text.range(of: #"\b124\s*/\s*9\b"#, options: .regularExpression), text)
                    XCTAssertNotNil(
                        text.range(of: #"\b0\s*B\s*/"#, options: .regularExpression),
                        "Zero SharedFS must remain separately scoped: \(text)")
                    XCTAssertFalse(text.contains("300 GB"), "Capacity must not masquerade as allocation: \(text)")
                }
                if variant == "empty" { XCTAssertTrue(text.contains("None observed"), text) }
                if variant == "unsupported" { XCTAssertTrue(text.contains("proxy counters unknown"), text) }
                if variant == "retained-error" {
                    XCTAssertNotNil(text.range(of: #"\breta[iIl]ned\b"#, options: .regularExpression), text)
                }
                if variant == "stale-local" {
                    XCTAssertTrue(text.contains("proxy recent"), text)
                    XCTAssertTrue(text.contains("local stale"), text)
                }
                if variant == "unavailable" {
                    XCTAssertNotNil(text.range(of: #"C[I1l] unava[iIl]lable"#, options: .regularExpression), text)
                }
            }
        }
    }

    @MainActor
    func testRunnerCapacityDoesNotMasqueradeAsActiveJobs() throws {
        // A listening persistent runner is running compute even at zero
        // CPU. A noisy runner is equally insufficient evidence of a job.
        // Names and labels supplied by users cannot become busy evidence.
        for cpu in [0.0, 250.0] {
            let store = makeRunningStore(client: AppTestCLI.makeFailing())
            var runner = Micropod_V1_Container()
            runner.id = "persistent-runner-busy-pretend"
            runner.runtime = "apple"
            runner.state = "running"
            runner.labels = ["cuttle.kind": "attempt", "busy": "true", "active_jobs": "42"]
            store.containers = [runner]
            var stats = Micropod_V1_ContainerStats()
            stats.id = runner.id
            stats.cpuPercent = cpu
            stats.memoryUsedBytes = 1024
            var snapshot = Micropod_V1_StatsSnapshot()
            snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())
            snapshot.containers = [stats]
            store.applyForPreview(stats: snapshot)
            XCTAssertEqual(store.workloadItems.count(where: \.isRunning), 1)
            let name = "micropod-runner-capacity-\(Int(cpu))"
            _ = try render(
                MenuBarPanelView(store: store, activateRuntimeObservation: false), scheme: .light, name: name)
            let text = try recognizedText(name)
            XCTAssertTrue(text.contains("Running compute"), text)
            XCTAssertTrue(text.contains("Active jobs"), text)
            XCTAssertTrue(text.contains("Unknown"), text)
            XCTAssertFalse(text.contains("42"), "Unverified metadata cannot supply a job count: \(text)")
        }
    }

    @MainActor
    func testMenuBarLabelSnapshot() throws {
        for scheme in [ColorScheme.light, .dark] {
            let store = makeRunningStore(client: AppTestCLI.makeFailing())
            populatePanel(store)
            let size = try render(
                MenuBarLabel(store: store, activateRuntimeObservation: false).padding(8),
                scheme: scheme, name: "micropod-tray-label-\(scheme == .dark ? "dark" : "light")")
            XCTAssertLessThanOrEqual(size.width, 150)
            XCTAssertLessThanOrEqual(size.height, 40)
        }
    }

    @MainActor
    func testMenuBarLogoIsCachedVisibleTemplateAtStandardAndRetinaScale() throws {
        let image = MenuBarImages.brandMark
        XCTAssertTrue(image === MenuBarImages.brandMark)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 24, height: 16))
        for scale in [1, 2] {
            let width = 24 * scale
            let height = 16 * scale
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            let visiblePixels = (0..<height).reduce(0) { total, y in
                total
                    + (0..<width).count { x in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                    }
            }
            XCTAssertGreaterThan(visiblePixels, width * height / 10, "Logo must not be blank at \(scale)x")
            XCTAssertLessThan(visiblePixels, width * height * 3 / 4, "Template must retain transparent space")
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
        }
    }

    @MainActor
    func testMenuBarLogoRemainsVisibleWithoutWorkloadCount() throws {
        let suite = "micropod-menu-bar-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for showCount in [true, false] {
            defaults.set(showCount, forKey: UserDefaultsKeys.showMenuBarCount)
            for populated in [false, true] {
                let store = makeRunningStore(client: AppTestCLI.makeFailing())
                if populated { populatePanel(store) }
                let size = try render(
                    MenuBarLabel(store: store, activateRuntimeObservation: false)
                        .defaultAppStorage(defaults),
                    scheme: .light, name: "micropod-tray-count-\(showCount)-populated-\(populated)")
                XCTAssertGreaterThanOrEqual(size.width, 24)
                XCTAssertGreaterThanOrEqual(size.height, 16)
            }
        }
    }

    func testGuestMetricsPreserveMissingAndPartialSamples() {
        let now = Date()
        let measured = workload(name: "api", cpu: 1.25, memory: 268_435_456, sampledAt: now)
        let missing = workload(name: "vm", cpu: nil, memory: nil, sampledAt: nil)
        let partial = MenuBarGuestMetrics(workloads: [measured, missing], at: now)
        XCTAssertEqual(partial.cpuText, "≥ 1.25")
        XCTAssertEqual(partial.memoryText, "≥ \(ByteFormat.string(268_435_456 as UInt64))")
        XCTAssertTrue(partial.detail.hasPrefix("1 of 2 sampled"))

        let absent = MenuBarGuestMetrics(workloads: [missing], at: now)
        XCTAssertEqual(absent.cpuText, "—")
        XCTAssertEqual(absent.memoryText, "—")
        let unavailable = MenuBarGuestMetrics(workloads: [measured], available: false, at: now)
        XCTAssertEqual(unavailable.cpuText, "—")
        XCTAssertEqual(unavailable.memoryText, "—")
        let stale = workload(name: "old", cpu: 2, memory: 1_000, sampledAt: now.addingTimeInterval(-60))
        XCTAssertEqual(MenuBarGuestMetrics(workloads: [stale], at: now).cpuText, "—")
        XCTAssertEqual(MenuBarGuestMetrics(workloads: [stale], at: now).memoryText, "—")
    }

    @MainActor
    func testGuestMetricsIncludePersistentVMAndUseConsumedCores() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        var container = Micropod_V1_Container()
        container.id = "api"
        container.state = "running"
        store.containers = [container]
        store.machines = [MachineEntry(name: "linux-dev", state: "running")]
        var stats = Micropod_V1_ContainerStats()
        stats.id = "api"
        stats.cpuPercent = 250
        stats.memoryUsedBytes = 268_435_456
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())
        snapshot.containers = [stats]
        store.applyForPreview(stats: snapshot)
        XCTAssertEqual(store.workloadItems.count(where: \.isRunning), 2)
        XCTAssertEqual(MenuBarGuestMetrics(workloads: store.workloadItems).cpuText, "≥ 2.50")
    }

    private func workload(name: String, cpu: Double?, memory: UInt64?, sampledAt: Date?) -> WorkloadItem {
        WorkloadItem(
            route: .container(name), name: name, project: "Standalone", kind: .container,
            engineLabel: "Apple", state: "running", image: "nginx:latest",
            cpuCores: cpu, memoryBytes: memory, ports: [], sampledAt: sampledAt, searchTerms: name)
    }

    @MainActor
    private func populatePanel(_ store: AppStore) {
        let specifications = [
            ("api-gateway", "docker.io/library/nginx:latest", "running"),
            ("postgres-main", "docker.io/library/postgres:17-alpine", "running"),
            ("zz-background-jobs-with-a-very-long-workload-name", "ghcr.io/example/runner:dev", "running"),
            ("archived-worker", "ghcr.io/example/runner:previous", "exited"),
        ]
        store.containers = specifications.map { name, image, state in
            var container = Micropod_V1_Container()
            container.id = name
            container.image = image
            container.state = state
            return container
        }
        store.machines = [MachineEntry(name: "linux-workbench", cpus: 4, memoryBytes: 8_589_934_592, state: "running")]
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())
        snapshot.containers = [
            ("api-gateway", 124.0, UInt64(268_435_456)), ("postgres-main", 31.0, UInt64(134_217_728)),
        ].map { id, cpu, memory in
            var stats = Micropod_V1_ContainerStats()
            stats.id = id
            stats.cpuPercent = cpu
            stats.memoryUsedBytes = memory
            return stats
        }
        store.applyForPreview(stats: snapshot)
        let measuredAt = Date()
        store.cacheStore.applyForPreview(
            CacheSnapshot(
                measuredAt: measuredAt, buildRoot: URL(fileURLWithPath: "/tmp/micropod-test-cache"),
                buildEntries: [],
                buildStats: BuildCacheStats(
                    entries: 3, contentBytes: 1_288_490_188, sharedBytes: 268_435_456, capBytes: 5_368_709_120),
                buildDisabled: false, buildError: nil,
                package: SharedCacheSnapshot(
                    cacheRoot: "/tmp/micropod-test-package-cache", measuredAt: measuredAt,
                    storedBytes: 0, capBytes: 10_737_418_240, chunkCount: 0,
                    activeMounts: [], keepEnabled: true, overCap: false),
                packageError: nil))
        var golden = Micropod_V1_Volume()
        golden.id = "cf-cache-tray-fixture"
        golden.format = "ext4"
        golden.sizeBytes = 300 << 30
        golden.allocatedBytes = 51 << 30
        let sampled = ISO8601DateFormatter().string(from: measuredAt)
        store.ciCacheStore.applyForPreview(
            CICacheInventorySnapshot(
                read: CICacheRead(volumes: [golden], containers: [], truncated: false),
                sourceID: "apple", measuredAt: measuredAt),
            telemetry: CICacheTelemetry(
                receivedAt: measuredAt,
                counters: [
                    CICacheCounter(
                        name: "depcache_requests_total", type: "counter", value: 124, capturedAt: sampled,
                        attributes: ["tier": "local"]),
                    CICacheCounter(
                        name: "depcache_requests_total", type: "counter", value: 9, capturedAt: sampled,
                        attributes: ["tier": "upstream"]),
                ]))
        store.recordActivity("runtime", "Runtime started", level: .success)
        store.recordActivity("containers", "Started api-gateway", level: .info)
        store.recordActivity("images", "Pull failed for ghcr.io/private/very-long-image-name", level: .error)
    }

    private func recognizedText(_ name: String) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: URL(fileURLWithPath: "/tmp/\(name).png"), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    @MainActor
    private func render<Content: View>(_ view: Content, scheme: ColorScheme, name: String) throws -> NSSize {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 640)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        window.setContentSize(fitting)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "PanelSnapshot", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PanelSnapshot", code: 2)
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return fitting
    }

    /// Same trick for the main-window dashboard — rasterizes the card layout
    /// so the GroupBox → PanelCard uplift can be eyeballed.
    @MainActor
    func testRenderDashboardToPNG() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)

        var web = Micropod_V1_Container()
        web.id = "web-frontend"
        web.image = "docker.io/library/nginx:latest"
        web.state = "running"
        web.createdAt = "2026-09-20T10:00:00Z"
        var db = Micropod_V1_Container()
        db.id = "postgres-main"
        db.image = "docker.io/library/postgres:17-alpine"
        db.state = "running"
        db.createdAt = "2026-09-19T08:30:00Z"
        var worker = Micropod_V1_Container()
        worker.id = "job-runner-3f2a"
        worker.image = "ghcr.io/skunkworq/runner:dev"
        worker.state = "exited"
        store.containers = [web, db, worker]

        var usage = Micropod_V1_DiskUsage()
        var cat = Micropod_V1_DiskCategory()
        cat.sizeBytes = 8_589_934_592
        cat.reclaimableBytes = 2_147_483_648
        usage.containers = cat
        usage.images = cat
        usage.volumes = cat
        usage.totalReclaimableBytes = 6_442_450_944
        store.diskUsage = usage

        store.recordActivity("runtime", "Runtime started", level: .success)
        store.recordActivity("containers", "Started web-frontend", level: .info)
        store.recordActivity("images", "Pull failed for ghcr.io/private/img", level: .error)

        let hosting = NSHostingView(
            rootView: DashboardView(store: store)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en")))
        hosting.frame = NSRect(x: 0, y: 0, width: 860, height: 720)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else {
            XCTFail("no bitmap rep")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard
            let png = rep.representation(
                using: NSBitmapImageRep.FileType.png, properties: [:])
        else {
            XCTFail("no png")
            return
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/dashboard.png"))
    }
}
