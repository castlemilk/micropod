import AppKit
import Foundation
import MicropodCore
import MicropodSharedFS
import SwiftUI
import XCTest

@testable import MicropodApp

/// Native visual verification artifacts, deliberately backed by an isolated
/// CLI fixture and CacheStore's preview seam. These are not pixel baselines.
@MainActor
final class WorkspaceSnapshotTests: XCTestCase {
    func testRenderDesignSystemComponents() throws {
        for scheme in [ColorScheme.light, .dark] {
            try rasterize(
                VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                    WorkspacePageHeader(
                        title: "Micropod components", subtitle: "Native preview · illustrative values",
                        icon: "workloads"
                    ) {
                        Button("Run…") {}.buttonStyle(.borderedProminent).tint(Tokens.Palette.action)
                    }
                    PanelCard(title: "Workload states", icon: "activity") {
                        HStack(spacing: Tokens.Spacing.md) {
                            WorkspaceStatusBadge(title: "Running", color: Tokens.Palette.success)
                            WorkspaceStatusBadge(title: "Stopped", color: Tokens.Palette.tertiary)
                            WorkspaceStatusBadge(title: "Starting", color: Tokens.Palette.warning)
                            WorkspaceStatusBadge(title: "Failed", color: Tokens.Palette.danger)
                        }
                    }
                    HStack(spacing: Tokens.Spacing.md) {
                        WorkspaceMetric(title: "CPU cores", value: "1.25", icon: "cpu", color: Tokens.Chart.cpu)
                        WorkspaceMetric(
                            title: "Workload memory", value: "384 MiB", icon: "memory", color: Tokens.Chart.memory)
                        WorkspaceMetric(title: "CPU cores", value: "—", icon: "cpu", detail: "Sample unavailable")
                    }
                    PanelCard(title: "Cache budgets", icon: "cache") {
                        HStack {
                            Text("Package chunks")
                            Spacer()
                            Text("320 MiB / 1 GiB").monospacedDigit()
                            WorkspaceStatusBadge(title: "In use", color: Tokens.Palette.success)
                        }
                        WorkspaceBudgetMeter(used: 320 << 20, cap: 1 << 30, label: "Package chunks budget")
                        HStack {
                            Text("Over-cap state")
                            Spacer()
                            Text("1.2 GiB / 1 GiB").monospacedDigit()
                        }
                        WorkspaceBudgetMeter(used: 1_288_490_188, cap: 1 << 30, label: "Over-cap preview")
                        HStack {
                            Text("Empty cache")
                            Spacer()
                            Text("0 bytes / 1 GiB").monospacedDigit()
                        }
                        WorkspaceBudgetMeter(used: 0, cap: 1 << 30, label: "Empty cache preview")
                    }
                    PanelCard(title: "Operational pictograms", icon: "images") {
                        HStack(spacing: Tokens.Spacing.xl) {
                            ForEach(
                                ["container", "microvm", "images", "cache", "storage", "network", "terminal", "logs"],
                                id: \.self
                            ) {
                                WorkspaceIconTile(name: $0)
                            }
                        }
                    }
                }
                .font(Tokens.Typography.body)
                .padding(Tokens.Spacing.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                scheme: scheme, size: NSSize(width: 780, height: 640),
                name: "micropod-components-\(schemeName(scheme))")
        }
    }

    func testRenderWorkloadsLightAndDark() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        for scheme in [ColorScheme.light, .dark] {
            let store = try makeWorkspaceStore(fixture)
            defer { store.stopPollers() }
            try rasterize(
                WorkloadsView(store: store), scheme: scheme, size: NSSize(width: 1280, height: 820),
                name: "micropod-native-workloads-\(schemeName(scheme))")
            XCTAssertEqual(store.selectedWorkloadID, "container:api-dev")
        }
    }

    func testRenderCacheLightAndDark() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        for scheme in [ColorScheme.light, .dark] {
            let store = try makeWorkspaceStore(fixture)
            defer { store.stopPollers() }
            store.activeTab = .cache
            try rasterize(
                CacheView(store: store), scheme: scheme, size: NSSize(width: 1280, height: 820),
                name: "micropod-native-cache-\(schemeName(scheme))")
            XCTAssertEqual(store.cacheStore.snapshot?.buildStats.entries, 3)
            XCTAssertEqual(store.cacheStore.snapshot?.package?.activeMounts.count, 2)
        }
    }

    func testRenderMainWindowLightAndDark() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        for scheme in [ColorScheme.light, .dark] {
            let store = try makeWorkspaceStore(fixture)
            defer { store.stopPollers() }
            try rasterize(
                MainPanelView(store: store), scheme: scheme, size: NSSize(width: 1280, height: 820),
                name: "micropod-native-main-\(schemeName(scheme))")
            XCTAssertEqual(store.activeTab, .workloads)
        }
    }

    func testRenderNarrowWorkloadInspector() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        for scheme in [ColorScheme.light, .dark] {
            let store = try makeWorkspaceStore(fixture)
            defer { store.stopPollers() }
            try rasterize(
                WorkloadsView(store: store), scheme: scheme, size: NSSize(width: 720, height: 760),
                name: "micropod-native-workloads-narrow-\(schemeName(scheme))")
            XCTAssertEqual(store.selectedContainerID, "api-dev")
            XCTAssertEqual(store.selectedWorkloadID, "container:api-dev")
        }
    }

    func testRenderMinimumWindowSize() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        for scheme in [ColorScheme.light, .dark] {
            let store = try makeWorkspaceStore(fixture)
            defer { store.stopPollers() }
            try rasterize(
                MainPanelView(store: store), scheme: scheme, size: NSSize(width: 720, height: 460),
                name: "micropod-native-main-minimum-\(schemeName(scheme))")
            XCTAssertEqual(store.activeTab, .workloads)
        }
    }

    func testResponsiveWorkspaceMatrix() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        for tab in AppStore.ActiveTab.allCases {
            let store = try makeWorkspaceStore(fixture)
            defer { store.stopPollers() }
            addInventoryFixtures(to: store)
            store.activeTab = tab
            store.selectedWorkloadID = nil
            store.selectedContainerID = nil
            for size in [
                NSSize(width: 720, height: 460), NSSize(width: 1040, height: 700), NSSize(width: 1920, height: 1080),
            ] {
                try rasterize(
                    MainPanelView(store: store), scheme: .light, size: size,
                    name: "micropod-responsive-\(tab.rawValue)-\(Int(size.width))")
            }
            try rasterize(
                MainPanelView(store: store), scheme: .dark, size: NSSize(width: 720, height: 460),
                name: "micropod-responsive-\(tab.rawValue)-720-dark")
            XCTAssertEqual(store.activeTab, tab, "Resizing must retain the selected workspace")
        }
    }

    func testResponsiveInspectorMatrix() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = try makeWorkspaceStore(fixture)
        defer { store.stopPollers() }
        store.containers[0].image =
            "ghcr.io/example/a-very-long-project-name/services/development/api:feature-branch-2026-10-01"
        store.containers[0].labels["com.micropod.owner"] = String(repeating: "long-owner-name-", count: 5)
        for pane in ContainerDetailView.Pane.allCases {
            for size in [
                NSSize(width: 320, height: 460), NSSize(width: 360, height: 600), NSSize(width: 600, height: 700),
            ] {
                try rasterize(
                    ContainerDetailView(store: store, containerID: "api-dev", initialPane: pane),
                    scheme: .light, size: size,
                    name: "micropod-responsive-inspector-\(pane.rawValue)-\(Int(size.width))")
            }
        }
        for pane in MachineDetailView.Pane.allCases {
            for width in [CGFloat(320), 600] {
                try rasterize(
                    MachineDetailView(store: store, machineID: store.machines[0].name, initialPane: pane),
                    scheme: .light, size: NSSize(width: width, height: 460),
                    name: "micropod-responsive-machine-\(pane.rawValue)-\(Int(width))")
            }
        }
        XCTAssertEqual(store.selectedContainerID, "api-dev")
    }

    func testResponsiveSheetsAndOverlays() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = try makeWorkspaceStore(fixture)
        defer { store.stopPollers() }
        addInventoryFixtures(to: store)
        var spec = Micropod_V1_ComposeSpec()
        spec.name = "a-long-environment-name-for-a-local-development-project"
        let environment = EnvironmentsView.SavedEnvironment(
            id: "preview", spec: spec, yamlURL: nil,
            binURL: fixture.directory.appendingPathComponent("environment.pb"))
        let sheets: [(String, AnyView, NSSize)] = [
            ("run", AnyView(RunContainerSheet(store: store)), NSSize(width: 420, height: 320)),
            ("machine", AnyView(CreateMachineSheet(store: store)), NSSize(width: 320, height: 300)),
            (
                "compose-editor",
                AnyView(
                    ComposeEditorSheet(
                        store: store, environment: environment,
                        initialYAML: "services:\n  api:\n    image: nginx:alpine\n")), NSSize(width: 420, height: 320)
            ),
            ("onboarding", AnyView(OnboardingTourView(store: store)), NSSize(width: 420, height: 320)),
            ("pull", AnyView(PullImageSheet(store: store, onPull: { _ in })), NSSize(width: 320, height: 280)),
            ("tag", AnyView(TagImageSheet(store: store, image: store.images[0])), NSSize(width: 320, height: 300)),
            (
                "image-detail", AnyView(ImageDetailSheet(store: store, image: store.images[0])),
                NSSize(width: 320, height: 260)
            ),
            (
                "network-detail", AnyView(NetworkDetailSheet(store: store, network: store.networks[0])),
                NSSize(width: 320, height: 260)
            ),
            (
                "volume-detail", AnyView(VolumeDetailSheet(store: store, volume: store.volumes[0])),
                NSSize(width: 320, height: 260)
            ),
            ("registry", AnyView(RegistryLoginSheet(store: store)), NSSize(width: 320, height: 250)),
            ("volume-create", AnyView(CreateVolumeSheet(store: store)), NSSize(width: 320, height: 280)),
            ("network-create", AnyView(CreateNetworkSheet(store: store)), NSSize(width: 320, height: 300)),
            (
                "pull-progress",
                AnyView(
                    PullProgressSheet(
                        store: store, reference: "registry.example.com/long-project/api:dev", opID: UUID())),
                NSSize(width: 320, height: 300)
            ),
        ]
        for (name, content, size) in sheets {
            try rasterize(content, scheme: .light, size: size, name: "micropod-responsive-sheet-\(name)-minimum")
            try rasterize(
                content, scheme: .dark, size: NSSize(width: 600, height: 480),
                name: "micropod-responsive-sheet-\(name)-wide")
        }
        for reason in [String?.none, String(repeating: "Active package mount protects this cache. ", count: 12)] {
            let json: [String: Any] = [
                "id": "preview-review", "createdAt": Date().timeIntervalSinceReferenceDate,
                "chunkCount": 64, "storedBytes": 256 << 20, "protectedChunkCount": 12,
                "blockedReason": reason.map { $0 as Any } ?? NSNull(),
            ]
            let review = try JSONDecoder().decode(
                SharedCacheCleanupReview.self, from: JSONSerialization.data(withJSONObject: json))
            store.cacheStore.applyForPreview(try cacheSnapshot(in: fixture.directory, at: Date()), review: review)
            try rasterize(
                CacheCleanupSheet(cache: store.cacheStore, onDismiss: {}), scheme: .light,
                size: NSSize(width: 360, height: 280),
                name: "micropod-responsive-sheet-cleanup-\(reason == nil ? "ready" : "blocked")-minimum")
        }
        try rasterize(
            CommandPaletteView(store: store), scheme: .light, size: NSSize(width: 320, height: 300),
            name: "micropod-responsive-palette-compact")
        try rasterize(
            EmptyStateView(
                title: "No environments",
                description: "Import an environment to run the services in your local project.",
                symbol: "folder", actionTitle: "Import…", action: {}), scheme: .light,
            size: NSSize(width: 320, height: 180),
            name: "micropod-responsive-empty-short")
        try rasterize(
            SelectionActionBar(
                count: 15,
                actions: {
                    Button("Start") {}
                    Button("Stop") {}
                    Button("Restart") {}
                    Button("Delete") {}
                    Button("Export") {}
                }, onDone: {}), scheme: .light, size: NSSize(width: 360, height: 64),
            name: "micropod-responsive-batch-actions")
    }

    func testResponsiveTopologyAndPopulatedProjects() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = try makeWorkspaceStore(fixture)
        defer { store.stopPollers() }
        addInventoryFixtures(to: store)
        for index in store.containers.indices { store.containers[index].networks = [store.networks[0].id] }
        for width in [CGFloat(320), 660, 1200] {
            try rasterize(
                NetworkTopologyView(store: store), scheme: .light, size: NSSize(width: width, height: 460),
                name: "micropod-responsive-topology-\(Int(width))")
        }
        var spec = Micropod_V1_ComposeSpec()
        spec.name = "Local development workspace with a long project name"
        spec.services = (1...24).map { index in
            var service = Micropod_V1_ComposeServiceSpec()
            service.name = "service-\(index)-with-a-long-name"
            service.image = "ghcr.io/example/platform/service-\(index):feature-development"
            return service
        }
        let environments = (1...6).map { index in
            var copy = spec
            copy.name = "Project \(index) · local development with a long name"
            return EnvironmentsView.SavedEnvironment(
                id: "preview-\(index)", spec: copy, yamlURL: nil,
                binURL: fixture.directory.appendingPathComponent("environment-\(index).pb"))
        }
        for size in [NSSize(width: 660, height: 400), NSSize(width: 1200, height: 820)] {
            try rasterize(
                ComposeView(store: store, initialSpec: spec), scheme: .light, size: size,
                name: "micropod-responsive-project-compose-\(Int(size.width))")
            try rasterize(
                EnvironmentsView(store: store, initialEnvironments: environments), scheme: .light, size: size,
                name: "micropod-responsive-project-environments-\(Int(size.width))")
        }
    }

    private func addInventoryFixtures(to store: AppStore) {
        let longName = "local-development-workspace-with-a-long-name-for-resource-layout-checks"
        var image = Micropod_V1_Image()
        image.id = String(repeating: "a", count: 64)
        image.digest = "sha256:\(image.id)"
        image.names = ["ghcr.io/example/\(longName)/api:latest"]
        image.sizeBytes = 456 << 20
        store.images = [image]
        var volume = Micropod_V1_Volume()
        volume.id = longName
        volume.driver = "local"
        volume.sizeBytes = 2 << 30
        volume.labels = ["com.example.project": longName]
        store.volumes = [volume]
        var network = Micropod_V1_Network()
        network.id = longName
        network.mode = "bridge"
        network.plugin = "bridge"
        network.ipv4Subnet = "192.168.64.0/24"
        network.ipv4Gateway = "192.168.64.1"
        store.networks = [network]
        var registry = Micropod_V1_RegistryLogin()
        registry.server = "registry.\(longName).example.com"
        registry.username = longName
        store.registries = [registry]
        var usage = Micropod_V1_DiskUsage()
        usage.containers.sizeBytes = 4 << 30
        usage.containers.reclaimableBytes = 1 << 30
        usage.images.sizeBytes = 12 << 30
        usage.images.reclaimableBytes = 3 << 30
        usage.volumes.sizeBytes = 2 << 30
        usage.volumes.reclaimableBytes = 256 << 20
        usage.totalReclaimableBytes = (4 << 30) + (256 << 20)
        store.diskUsage = usage
    }

    private func makeWorkspaceStore(_ fixture: AppTestCLI.Fixture) throws -> AppStore {
        let store = makeRunningStore(client: fixture.client)
        let now = Date()
        store.activeTab = .workloads
        store.appearance = .system
        store.containers = [
            container("api-dev", image: "ghcr.io/studio/api:dev", project: "Shop", port: 8080),
            container("postgres", image: "postgres:17-alpine", project: "Shop", port: 5432),
            container("redis", image: "redis:8-alpine", project: "Shop", runtime: "docker", port: 6379),
            container("docs", image: "nginx:alpine", project: "Studio", state: "stopped", port: 3000),
            container("build-sandbox", image: "golang:1.25-alpine", project: "CI", runtime: "sandbox", state: "exited"),
        ]
        store.machines = [
            MachineEntry(
                name: "ci-runner", created: "2026-09-20T10:00:00Z", ip: "192.168.64.4", cpus: 4,
                memoryBytes: 2 << 30, diskBytes: 20 << 30, state: "running")
        ]
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.sampledAt = ISO8601DateFormatter().string(from: now)
        snapshot.containers = [
            stats("api-dev", cpu: 18, memory: 256 << 20),
            stats("postgres", cpu: 3, memory: 384 << 20),
            stats("redis", cpu: 1, memory: 64 << 20),
        ]
        store.applyForPreview(stats: snapshot)
        store.selectWorkload(store.workloadItems.first { $0.name == "api-dev" }!)
        store.cacheStore.applyForPreview(try cacheSnapshot(in: fixture.directory, at: now))
        store.recordActivity("containers", "Started api-dev", level: .success)
        return store
    }

    private func cacheSnapshot(in directory: URL, at date: Date) throws -> CacheSnapshot {
        let dockerfileHash = String(repeating: "d", count: 64)
        let sharedHash = String(repeating: "a", count: 64)
        let seedBytes: UInt64 = 16 << 20
        let resourceBytes: UInt64 = 32 << 20
        let tarBytes: Int = 48 << 20
        let entries: [BuildManifest] = (1...3).map { (index: Int) -> BuildManifest in
            let hash = String(repeating: String(index), count: 64)
            let storedAtDate = date.addingTimeInterval(-Double(index) * 300)
            let files: [BuildFileEntry] = [
                BuildFileEntry(path: "Dockerfile", sha256: dockerfileHash, size: 408),
                BuildFileEntry(path: "assets/dev-seed.bin", sha256: sharedHash, size: seedBytes),
                BuildFileEntry(path: "src/resources.bin", sha256: hash, size: resourceBytes),
            ]
            return BuildManifest(treeHash: hash, files: files, tarBytes: tarBytes, storedAt: storedAtDate)
        }
        // Public MountInfo is decoded through its wire contract; its memberwise
        // initializer is intentionally internal to MicropodSharedFS.
        let mountsJSON: [[String: Any]] = ["go-build", "npm"].map { name in
            [
                "id": ["value": "preview-\(name)"],
                "src": directory.appendingPathComponent("project/.cache/\(name)").path,
                "viewPath": directory.appendingPathComponent("package-cache/views/\(name)").path,
                "sizeBytes": 128 << 20, "readonly": false,
                "createdAt": date.timeIntervalSinceReferenceDate,
            ]
        }
        let mounts = try JSONDecoder().decode(
            [MountInfo].self, from: JSONSerialization.data(withJSONObject: mountsJSON))
        return CacheSnapshot(
            measuredAt: date, buildRoot: directory.appendingPathComponent("build-cache"),
            buildEntries: entries,
            buildStats: BuildCacheStats(
                entries: entries.count, contentBytes: entries.reduce(0) { $0 + $1.contentBytes },
                sharedBytes: BuildCacheStore.sharedBytes(manifests: entries), capBytes: 5 << 30),
            buildDisabled: false, buildError: nil,
            package: SharedCacheSnapshot(
                cacheRoot: directory.appendingPathComponent("package-cache").path, measuredAt: date,
                storedBytes: 3_435_973_836, capBytes: 10 << 30, chunkCount: 1536,
                activeMounts: mounts, keepEnabled: false, overCap: false), packageError: nil)
    }

    private func container(
        _ name: String, image: String, project: String, runtime: String = "apple",
        state: String = "running", port: UInt32? = nil
    ) -> Micropod_V1_Container {
        var value = Micropod_V1_Container()
        value.id = name
        value.image = image
        value.runtime = runtime
        value.state = state
        value.platform = "linux/arm64"
        value.labels = ["com.micropod.project": project]
        value.resources.cpus = 2
        value.resources.memoryBytes = 1 << 30
        if let port {
            var mapping = Micropod_V1_PortMapping()
            mapping.hostPort = port
            mapping.containerPort = port
            mapping.protocol = "tcp"
            value.publishedPorts = [mapping]
        }
        return value
    }

    private func stats(_ name: String, cpu: Double, memory: UInt64) -> Micropod_V1_ContainerStats {
        var value = Micropod_V1_ContainerStats()
        value.id = name
        value.cpuPercent = cpu
        value.memoryUsedBytes = memory
        value.memoryLimitBytes = 1 << 30
        return value
    }

    private func schemeName(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    private func rasterize<Content: View>(
        _ content: Content, scheme: ColorScheme, size: NSSize, name: String
    ) throws {
        let hosting = NSHostingView(
            rootView:
                content
                .background(Tokens.Palette.canvas)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en")))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        // A second layout lets an onAppear-driven compact inspector settle.
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SnapshotError.bitmapUnavailable
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let rendered = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.bitmapUnavailable
        }
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        XCTAssertGreaterThan(
            rendered.count, min(10_000, max(1_500, Int(size.width * size.height / 30))),
            "Expected rasterized content rather than an empty surface")
        try rendered.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }

    private enum SnapshotError: Error { case bitmapUnavailable }
}
