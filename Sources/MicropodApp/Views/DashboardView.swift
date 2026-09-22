import Charts
import MicropodCore
import SwiftUI

struct DashboardView: View {
    @Bindable var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOnboarding = false
    @State private var pendingPrune: PendingPrune?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    EmptyStateView.brandMark(EmptyStateArtwork.dashboardHero, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Micropod").font(.title3.weight(.semibold))
                        Text(String(localized: "macOS container manager"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 2)
                runtimeCard
                workloadsCard
                liveResourcesCard
                resourcesGrid
                diskUsageCard
                if !store.activity.isEmpty {
                    activityCard
                }
            }
            .padding(16)
        }
        .task { await store.refreshDiskUsage() }

        .sheet(isPresented: $showOnboarding) {
            OnboardingTourView(store: store)
        }
        .confirmationDialog(
            pendingPrune?.title ?? "",
            isPresented: Binding(
                get: { pendingPrune != nil },
                set: { if !$0 { pendingPrune = nil } })
        ) {
            Button(pendingPrune?.confirmLabel ?? "", role: .destructive) {
                guard let pendingPrune else { return }
                self.pendingPrune = nil
                Task {
                    switch pendingPrune {
                    case .containers: await store.pruneContainers()
                    case .imagesDangling: await store.pruneImages(all: false)
                    case .imagesAll: await store.pruneImages(all: true)
                    case .volumes: await store.pruneVolumes()
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingPrune = nil }
        } message: {
            Text(pendingPrune?.message ?? "")
        }
    }

    // MARK: - Activity feed

    private var activityCard: some View {
        PanelCard(title: "Recent Activity") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.recentActivity(limit: 12).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, 24)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: entry))
                            .font(.system(size: 11))
                            .foregroundStyle(color(for: entry))
                            .frame(width: 16)
                        Text(entry.message)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(entry.timestamp.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func icon(for entry: ActivityEntry) -> String {
        switch entry.level {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "clock"
        }
    }

    private func color(for entry: ActivityEntry) -> Color {
        switch entry.level {
        case .success: .green
        case .error: .red
        case .info: .secondary
        }
    }

    // MARK: - Runtime card

    private var runtimeCard: some View {
        PanelCard(title: "Runtime") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(runtimeStatusColor)
                            .frame(width: 9, height: 9)
                        Text(runtimeStatusTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(store.isRuntimeRunning ? Color.primary : Color.secondary)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.isRuntimeRunning && store.clientAvailable {
                    Button {
                        Task { await store.startRuntime() }
                    } label: {
                        IconLabel(
                            title: store.isStartingRuntime
                                ? String(localized: "Starting…") : String(localized: "Start Runtime"),
                            icon: "start", fallback: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isStartingRuntime)
                } else if store.isRuntimeRunning {
                    HStack(spacing: 8) {
                        Button {
                            Task { await store.restartRuntime() }
                        } label: {
                            IconLabel(
                                title: store.isRestartingRuntime
                                    ? String(localized: "Restarting…") : String(localized: "Restart"),
                                icon: "restart", fallback: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isRestartingRuntime || store.isHealingRuntime)
                        Button {
                            Task { await store.stopRuntime() }
                        } label: {
                            IconLabel(title: String(localized: "Stop"), icon: "stop", fallback: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isRestartingRuntime || store.isHealingRuntime)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    TileButton(title: String(localized: "Run Container…"), icon: "create") {
                        store.activeTab = .containers
                        store.pendingRunSheet = true
                    }
                    TileButton(title: String(localized: "Pull Image…"), icon: "pull") {
                        store.activeTab = .images
                        store.pendingPullSheet = true
                    }
                    TileButton(title: String(localized: "Command Palette"), icon: "palette") {
                        store.showCommandPalette = true
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TileButton(title: String(localized: "Run Container…"), icon: "create") {
                            store.activeTab = .containers
                            store.pendingRunSheet = true
                        }
                        TileButton(title: String(localized: "Pull Image…"), icon: "pull") {
                            store.activeTab = .images
                            store.pendingPullSheet = true
                        }
                    }
                    TileButton(title: String(localized: "Command Palette"), icon: "palette") {
                        store.showCommandPalette = true
                    }
                }
            }
            .padding(.top, 10)

            if !store.onboardingComplete && store.isRuntimeRunning {
                Divider().padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(String(localized: "First run"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Open tour")) { showOnboarding = true }
                            .controlSize(.small)
                    }
                    if store.isInstallingKernel {
                        kernelInstallProgress
                    } else if store.kernelInstallComplete {
                        kernelInstallCompleteView
                    } else {
                        Text(
                            String(
                                localized:
                                    "The container kernel is not installed yet — containers can't run without it.")
                        )
                        .font(.caption)
                        Button {
                            Task { await store.installRecommendedKernel() }
                        } label: {
                            IconLabel(
                                title: String(localized: "Install Recommended Kernel"), icon: "pull",
                                fallback: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isInstallingKernel)
                    }
                    if let error = store.kernelInstallError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// Blue animated bar + spinner while the kernel downloads.
    private var kernelInstallProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.blue)
                Text(String(localized: "Downloading the recommended kernel…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            kernelProgressBar(progress: store.kernelInstallFraction ?? 0.15, color: .blue, animated: true)
            DisclosureGroup(String(localized: "Details")) {
                ScrollView {
                    Text(store.kernelInstallProgress.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// Green full bar + checkmark once the kernel is in place.
    private var kernelInstallCompleteView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                Text(String(localized: "Kernel installed"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                Spacer()
            }
            kernelProgressBar(progress: 1.0, color: .green, animated: false)
        }
    }

    private func kernelProgressBar(progress: Double, color: Color, animated: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: max(6, geo.size.width * min(1, max(0, progress))))
                    .overlay {
                        if animated {
                            // Sweep highlight so an indeterminate install still reads as "moving".
                            LinearGradient(
                                colors: [.white.opacity(0.0), .white.opacity(0.35), .white.opacity(0.0)],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .clipShape(Capsule())
                        }
                    }
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? .default : (animated ? .easeOut(duration: 0.35) : .default), value: progress)
    }

    private var runtimeStatusColor: Color {
        if !store.clientAvailable { return .red }
        if store.isStartingRuntime || store.isHealingRuntime || store.isRestartingRuntime {
            return .orange
        }
        if store.runtimeHealth == .wedged { return .orange }
        return store.isRuntimeRunning ? .green : .gray
    }

    private var runtimeStatusTitle: String {
        if store.isRuntimeRunning {
            if store.isHealingRuntime { return String(localized: "Recovering…") }
            return store.runtimeHealth == .wedged
                ? String(localized: "Unresponsive") : String(localized: "Running")
        }
        return String(localized: "Stopped")
    }

    private var subtitle: String {
        if !store.clientAvailable {
            return "The container CLI was not found at \(store.dependencies.client.executableURL.path)"
        }
        if store.runtimeHealth == .wedged {
            return store.isHealingRuntime
                ? "Runtime is unresponsive — restarting the system service…"
                : "Runtime is unresponsive — self-healing is scheduled; use Recover in Settings to retry now."
        }
        guard let status = store.systemStatus else {
            return store.systemStatusError ?? "Checking runtime status…"
        }
        var parts: [String] = []
        if !status.apiServerVersion.isEmpty { parts.append("apiserver \(status.apiServerVersion)") }
        if !status.cliVersion.isEmpty { parts.append("cli \(status.cliVersion)") }
        if parts.isEmpty { return "Runtime status unavailable" }
        return parts.joined(separator: " · ")
    }

    // MARK: - Live resources

    /// Rolling system-wide CPU + memory charts across all running containers.
    private var liveResourcesCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(localized: "Live Resources")).font(.headline)
                    Spacer()
                    ChartTimeWindowPicker(window: $resourceWindow)
                }
                chartBody
            }
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        let samples = store.statsHistory.within(resourceWindow)
        let chartSamples = downsample(samples, maxPoints: 360)
        if samples.count < 2 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Sampling…")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        metricSummary(
                            label: "CPU",
                            value: cpuSummary(samples),
                            icon: "cpu",
                            color: .blue)
                        metricSummary(
                            label: "Memory",
                            value: memorySummary(samples),
                            icon: "memorychip",
                            color: .purple)
                        metricSummary(
                            label: "Network",
                            value: netSummary(samples),
                            icon: "arrow.left.arrow.right",
                            color: .teal)
                        Spacer()
                        Text("last \(samples.count) samples · \(spanText(samples)) of data")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) {
                            metricSummary(
                                label: "CPU",
                                value: cpuSummary(samples),
                                icon: "cpu",
                                color: .blue)
                            metricSummary(
                                label: "Memory",
                                value: memorySummary(samples),
                                icon: "memorychip",
                                color: .purple)
                            metricSummary(
                                label: "Network",
                                value: netSummary(samples),
                                icon: "arrow.left.arrow.right",
                                color: .teal)
                        }
                        Text("last \(samples.count) samples · \(spanText(samples)) of data")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Chart {
                    ForEach(chartSamples, id: \.timestamp) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("CPU %", sample.cpuPercent)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYScale(domain: 0...max(100, (chartSamples.map(\.cpuPercent).max() ?? 0) + 10))
                .frame(height: 80)
                Chart {
                    ForEach(chartSamples, id: \.timestamp) { sample in
                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Memory", Double(sample.memoryUsedBytes))
                        )
                        .foregroundStyle(.purple.opacity(0.25))
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Memory", Double(sample.memoryUsedBytes))
                        )
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYAxisLabel("bytes")
                .frame(height: 80)
            }
        }
    }

    @State private var resourceWindow: ChartTimeWindow = .fifteenMinutes

    private func spanText(_ samples: [ResourceSample]) -> String {
        guard let first = samples.first, let last = samples.last else { return "—" }
        let seconds = max(1, Int(last.timestamp.timeIntervalSince(first.timestamp)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return String(format: "%.1fh", Double(seconds) / 3600)
    }

    private func metricSummary(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func memorySummary(_ samples: [ResourceSample]) -> String {
        guard let last = samples.last else { return "—" }
        return "\(ByteFormat.string(last.memoryUsedBytes)) / \(ByteFormat.string(last.memoryLimitBytes))"
    }

    private func cpuSummary(_ samples: [ResourceSample]) -> String {
        let cpu = samples.last?.cpuPercent ?? 0
        return String(format: "%.1f%%", cpu) + (cpu < 0.05 ? " · idle" : "")
    }

    /// Live network rates (B/s) derived from counter deltas over the window;
    /// "idle" when traffic is effectively zero so a quiet box reads healthy.
    private func netSummary(_ samples: [ResourceSample]) -> String {
        guard let first = samples.first, let last = samples.last,
            last.timestamp > first.timestamp
        else { return "—" }
        let seconds = last.timestamp.timeIntervalSince(first.timestamp)
        let rx =
            Double(last.networkRxBytes > first.networkRxBytes ? last.networkRxBytes - first.networkRxBytes : 0)
            / seconds
        let tx =
            Double(last.networkTxBytes > first.networkTxBytes ? last.networkTxBytes - first.networkTxBytes : 0)
            / seconds
        if rx < 0.05 && tx < 0.05 { return "idle" }
        return "↓\(rate(rx)) ↑\(rate(tx))"
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.1f B/s", bytesPerSecond)
    }

    // MARK: - Resources grid

    /// One glance at every resource class; each tile jumps to its tab.
    private var resourcesGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
            spacing: 10
        ) {
            resourceTile(
                title: "Containers",
                value: "\(store.runningCount)/\(store.containers.count) running",
                icon: "shippingbox",
                color: store.runningCount > 0 ? .green : .secondary,
                tab: .containers)
            resourceTile(
                title: "Local Images",
                value: "\(store.localImageCount) · \(localImageSize)",
                icon: "photo.stack",
                color: .secondary,
                tab: .images)
            resourceTile(
                title: "Volumes",
                value: "\(store.volumes.count)",
                icon: "externaldrive",
                color: .secondary,
                tab: .volumes)
            resourceTile(
                title: "Networks",
                value: "\(store.networks.count)",
                icon: "network",
                color: .secondary,
                tab: .networks)
            resourceTile(
                title: "Registries",
                value: "\(store.registries.count)",
                icon: "globe",
                color: .secondary,
                tab: .registries)
            resourceTile(
                title: "Reclaimable",
                value: store.diskUsage.map { ByteFormat.string($0.totalReclaimableBytes) } ?? "—",
                icon: "externaldrive.badge.xmark",
                color: .orange,
                tab: .dashboard)
        }
    }

    private var localImageSize: String {
        guard store.localImageBytes <= UInt64(Int64.max) else {
            return "≥\(ByteFormat.string(Int64.max))"
        }
        return ByteFormat.string(store.localImageBytes)
    }

    private func resourceTile(title: String, value: String, icon: String, color: Color, tab: AppStore.ActiveTab)
        -> some View
    {
        Button {
            store.activeTab = tab
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(color.opacity(0.16))
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(color)
                    }
                    .frame(width: 18, height: 18)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .cardSurface(cornerRadius: 8, fillOpacity: 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Disk usage card

    private var diskUsageCard: some View {
        PanelCard(title: "Disk Usage") {
            if let usage = store.diskUsage {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Total reclaimable")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(ByteFormat.string(usage.totalReclaimableBytes))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    categoryRow(name: "Containers", category: usage.containers)
                    categoryRow(name: "Images", category: usage.images)
                    categoryRow(name: "Volumes", category: usage.volumes)
                    HStack(spacing: 8) {
                        pruneButton("Prune Containers", destructive: false) { pendingPrune = .containers }
                        pruneButton("Prune Dangling Images", destructive: false) { pendingPrune = .imagesDangling }
                        pruneButton("Prune All Unused Images", destructive: true) { pendingPrune = .imagesAll }
                        pruneButton("Prune Volumes", destructive: false) { pendingPrune = .volumes }
                    }
                }
            } else {
                Text("Disk usage unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryRow(name: String, category: Micropod_V1_DiskCategory) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: max(
                                4, geo.size.width * fraction(used: category.sizeBytes, total: category.sizeBytes)))
                }
            }
            .frame(height: 6)
            Text(ByteFormat.string(category.sizeBytes))
                .font(.caption2.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            if category.reclaimableBytes > 0 {
                Text("\(ByteFormat.string(category.reclaimableBytes)) reclaimable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func fraction(used: UInt64, total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(used) / Double(total))
    }

    private func pruneButton(_ title: String, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconLabel(title: title, icon: "prune", fallback: destructive ? "trash.fill" : "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(destructive ? .red : nil)
    }

    /// What the prune confirmation is asking about.
    private enum PendingPrune: Identifiable {
        case containers, imagesDangling, imagesAll, volumes
        var id: String { String(describing: self) }
        var title: String {
            switch self {
            case .containers: "Prune Stopped Containers?"
            case .imagesDangling: "Prune Dangling Images?"
            case .imagesAll: "Prune All Unused Images?"
            case .volumes: "Prune Unused Volumes?"
            }
        }
        var message: String {
            switch self {
            case .containers: "Removes every stopped container and its writable layer."
            case .imagesDangling: "Removes images not referenced by any tag or container."
            case .imagesAll: "Removes every image not referenced by a running container."
            case .volumes: "Removes volumes not referenced by any container."
            }
        }
        var confirmLabel: String {
            switch self {
            case .containers: "Prune Containers"
            case .imagesDangling: "Prune Dangling Images"
            case .imagesAll: "Prune All Unused Images"
            case .volumes: "Prune Volumes"
            }
        }
    }

    // MARK: - Workloads

    private var workloadsCard: some View {
        PanelCard(title: "Workloads") {
            let running = store.containers.filter { $0.state == "running" }
            if running.isEmpty {
                Text("No running workloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(running.enumerated()), id: \.element.id) { index, container in
                        if index > 0 {
                            Divider().padding(.leading, 17)
                        }
                        DashboardContainerRow(
                            container: container,
                            stats: store.statsByID[container.id])
                    }
                }
            }
        }
    }
}

struct DashboardContainerRow: View {
    let container: Micropod_V1_Container
    let stats: Micropod_V1_ContainerStats?

    private var metadata: WorkloadMetadata {
        WorkloadMetadata(labels: container.labels)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.green).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(container.id)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(container.image)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                workloadMetadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let stats {
                HStack(spacing: 10) {
                    metric("\(Int(stats.cpuPercent))%", icon: "cpu")
                    metric(ByteFormat.string(stats.memoryUsedBytes), icon: "memorychip")
                    if !container.ipv4Address.isEmpty {
                        Text(container.ipv4Address)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var workloadMetadata: some View {
        HStack(spacing: 8) {
            Label(
                metadata.source.rawValue,
                systemImage: metadata.source == .compose
                    ? "square.stack.3d.up" : "arrow.right"
            )
            .foregroundStyle(.secondary)
            .fixedSize()
            if metadata.isAgent {
                Label("Agent", systemImage: "terminal")
                    .foregroundStyle(.blue)
                    .fixedSize()
            }
            if let jobID = metadata.jobID {
                Text("Job \(jobID)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let owner = metadata.owner {
                Text("Owner \(owner)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func metric(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(text).font(.caption2.monospacedDigit())
        }
    }
}
