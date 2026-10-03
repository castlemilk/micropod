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
            VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                WorkspacePageHeader(
                    title: "Overview", subtitle: "Containers, microVMs and local resources",
                    icon: "activity", fallback: "waveform.path.ecg")
                runtimeCard
                workloadsCard
                liveResourcesCard
                resourcesGrid
                diskUsageCard
                if !store.activity.isEmpty {
                    activityCard
                }
            }
            .padding(Tokens.Spacing.contentInset)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
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
        PanelCard(title: "Recent Activity", icon: "activity") {
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
        case .success: Tokens.Palette.success
        case .error: Tokens.Palette.danger
        case .info: Tokens.Palette.secondary
        }
    }

    // MARK: - Runtime card

    private var runtimeCard: some View {
        PanelCard(title: "Runtime", icon: "workloads") {
            ResponsiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        StatusDot(
                            color: runtimeStatusColor, size: 9,
                            active: store.isStartingRuntime || store.isRestartingRuntime
                                || store.isHealingRuntime)
                        Text(runtimeStatusTitle)
                            .font(Tokens.Typography.metric)
                            .foregroundStyle(store.isRuntimeRunning ? Color.primary : Color.secondary)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                if !store.isRuntimeRunning && store.clientAvailable {
                    Button {
                        Task { await store.startRuntime() }
                    } label: {
                        HStack(spacing: 6) {
                            WorkspaceIcon(name: "play", size: 14, fallback: "play.fill")
                            Text(
                                store.isStartingRuntime
                                    ? String(localized: "Starting…") : String(localized: "Start Runtime"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isStartingRuntime)
                } else if store.isRuntimeRunning {
                    HStack(spacing: 8) {
                        Button {
                            Task { await store.restartRuntime() }
                        } label: {
                            HStack(spacing: 6) {
                                WorkspaceIcon(name: "restart", size: 14, fallback: "arrow.clockwise")
                                Text(
                                    store.isRestartingRuntime
                                        ? String(localized: "Restarting…") : String(localized: "Restart"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isRestartingRuntime || store.isHealingRuntime)
                        Button {
                            store.requestRuntimeStop()
                        } label: {
                            HStack(spacing: 6) {
                                WorkspaceIcon(name: "stop", size: 14, fallback: "stop.fill")
                                Text(String(localized: "Stop"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isRestartingRuntime || store.isHealingRuntime)
                    }
                }
            }

            HStack(spacing: Tokens.Spacing.sm) {
                Button {
                    store.activeTab = .workloads
                    store.pendingRunSheet = true
                } label: {
                    HStack(spacing: 6) {
                        WorkspaceIcon(name: "play", size: 14, fallback: "play.fill")
                        Text(String(localized: "Run Container…"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Palette.action)
                Button {
                    store.activeTab = .images
                    store.pendingPullSheet = true
                } label: {
                    HStack(spacing: 6) {
                        WorkspaceIcon(name: "download", size: 14, fallback: "arrow.down.circle")
                        Text(String(localized: "Pull Image…"))
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .controlSize(.regular)
            .padding(.top, Tokens.Spacing.sm)

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

    /// Blue animated bar + download indicator while the kernel downloads.
    private var kernelInstallProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                Text(String(localized: "Downloading the recommended kernel…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            kernelProgressBar(progress: store.kernelInstallFraction ?? 0.15, color: .blue, animated: true)
            DisclosureGroup(String(localized: "Details")) {
                ScrollView {
                    Text(store.kernelInstallProgress.joined(separator: "\n"))
                        .font(.footnote.monospaced())
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
        if !store.clientAvailable { return Tokens.Palette.danger }
        if store.isStartingRuntime || store.isHealingRuntime || store.isRestartingRuntime {
            return Tokens.Palette.warning
        }
        if store.runtimeHealth == .wedged { return Tokens.Palette.warning }
        return store.isRuntimeRunning ? Tokens.Palette.success : Tokens.Palette.tertiary
    }

    private var runtimeStatusTitle: String {
        if store.isRuntimeRunning {
            if store.isHealingRuntime { return String(localized: "Recovering…") }
            return store.runtimeHealth == .wedged
                ? String(localized: "Unresponsive") : String(localized: "Running")
        }
        return String(localized: "Stopped")
    }

    /// `system status` reports verbose strings like
    /// "container-apiserver version 1.3.1 (build: release, commit: abc123)"
    /// — the dashboard needs just the semver.
    private static func shortVersion(_ raw: String) -> String {
        for token in raw.split(whereSeparator: { $0 == " " || $0 == "(" }) {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ",)"))
            if t.first?.isNumber == true, t.contains(".") { return t }
        }
        return raw
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
        if !status.apiServerVersion.isEmpty {
            parts.append("apiserver \(Self.shortVersion(status.apiServerVersion))")
        }
        if !status.cliVersion.isEmpty { parts.append("CLI \(Self.shortVersion(status.cliVersion))") }
        if parts.isEmpty { return "Runtime status unavailable" }
        return parts.joined(separator: " · ")
    }

    // MARK: - Live resources

    /// Rolling system-wide CPU + memory charts across all running containers.
    private var liveResourcesCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: Tokens.Spacing.sm) {
                        WorkspaceIcon(name: "activity", size: 16, fallback: "waveform.path.ecg")
                            .foregroundStyle(Tokens.Palette.secondary)
                        Text(String(localized: "Live Resources")).font(Tokens.Typography.section)
                    }
                    Spacer()
                    ChartTimeWindowPicker(window: $resourceWindow)
                }
                chartBody
                    .task(id: ResourceHistoryRequest(window: resourceWindow, visible: store.mainWindowVisible)) {
                        while !Task.isCancelled && resourceWindow.needsStore && store.mainWindowVisible {
                            await loadStoredSamples(window: resourceWindow)
                            try? await Task.sleep(for: .seconds(60))
                        }
                    }
            }
        }
    }

    /// Windows past 3 h: the rolled-up history, reloaded each minute.
    @State private var storedSamples: [ResourceSample] = []

    private struct ResourceHistoryRequest: Equatable {
        let window: ChartTimeWindow
        let visible: Bool
    }

    private func loadStoredSamples(window: ChartTimeWindow) async {
        guard window.needsStore, store.metrics != nil, let metricsStore = MetricsStore.shared else { return }
        let points = await Task.detached(priority: .utility) {
            metricsStore.history(.system, "all", range: window.duration).points
        }.value
        guard !Task.isCancelled, resourceWindow == window, store.mainWindowVisible else { return }
        storedSamples = points.map(ResourceSample.init)
    }

    @ViewBuilder
    private var chartBody: some View {
        let samples = resourceWindow.needsStore ? storedSamples : store.statsHistory.within(resourceWindow)
        let chartSamples = downsample(samples, maxPoints: 360)
        let cpu = cpuSummary(samples)
        let memory = memorySummary(samples)
        let network = netSummary(samples)
        if samples.count < 2 {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
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
                            value: cpu,
                            icon: "cpu",
                            color: Tokens.Chart.cpu)
                        metricSummary(
                            label: "Memory",
                            value: memory,
                            icon: "memorychip",
                            color: Tokens.Chart.memory)
                        metricSummary(
                            label: "Network",
                            value: network,
                            icon: "arrow.left.arrow.right",
                            color: Tokens.Chart.networkRx)
                        Spacer()
                        Text("last \(samples.count) samples · \(spanText(samples)) of data")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) {
                            metricSummary(
                                label: "CPU",
                                value: cpu,
                                icon: "cpu",
                                color: Tokens.Chart.cpu)
                            metricSummary(
                                label: "Memory",
                                value: memory,
                                icon: "memorychip",
                                color: Tokens.Chart.memory)
                            metricSummary(
                                label: "Network",
                                value: network,
                                icon: "arrow.left.arrow.right",
                                color: Tokens.Chart.networkRx)
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
                        .foregroundStyle(Tokens.Chart.cpu)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYScale(domain: 0...max(100, (chartSamples.lazy.map(\.cpuPercent).max() ?? 0) + 10))
                .frame(height: 80)
                Chart {
                    ForEach(chartSamples, id: \.timestamp) { sample in
                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Memory", Double(sample.memoryUsedBytes))
                        )
                        .foregroundStyle(Tokens.Chart.memory.opacity(0.2))
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Memory", Double(sample.memoryUsedBytes))
                        )
                        .foregroundStyle(Tokens.Chart.memory)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                // ByteCountFormatter renders 0 as "Zero KB".
                                Text(bytes <= 0 ? "0" : ByteFormat.string(Int64(bytes)))
                            }
                        }
                    }
                }
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
            WorkspaceIcon(
                name: icon == "memorychip" ? "memory" : icon == "cpu" ? "cpu" : "network", size: 16, fallback: icon
            )
            .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
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

    /// Average network rates (B/s) over the window; "idle" when traffic is
    /// effectively zero so a quiet box reads healthy.
    private func netSummary(_ samples: [ResourceSample]) -> String {
        guard !samples.isEmpty else { return "—" }
        let totals = samples.reduce(into: (rx: 0.0, tx: 0.0)) { totals, sample in
            totals.rx += sample.networkRxRate
            totals.tx += sample.networkTxRate
        }
        let rx = totals.rx / Double(samples.count)
        let tx = totals.tx / Double(samples.count)
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
            columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
            spacing: 10
        ) {
            resourceTile(
                title: "Containers",
                value: "\(store.runningCount)/\(store.containers.count) running",
                icon: "container", fallback: "shippingbox",
                color: store.runningCount > 0 ? Tokens.Palette.success : Tokens.Palette.secondary,
                tab: .containers)
            resourceTile(
                title: "Local Images",
                value: "\(store.localImageCount) · \(localImageSize)",
                icon: "images", fallback: "photo.stack",
                color: Tokens.Palette.secondary,
                tab: .images)
            resourceTile(
                title: "Volumes",
                value: "\(store.volumes.count)",
                icon: "storage", fallback: "externaldrive",
                color: Tokens.Palette.secondary,
                tab: .volumes)
            resourceTile(
                title: "Networks",
                value: "\(store.networks.count)",
                icon: "network", fallback: "network",
                color: Tokens.Palette.secondary,
                tab: .networks)
            resourceTile(
                title: "Registries",
                value: "\(store.registries.count)",
                icon: "network", fallback: "globe",
                color: Tokens.Palette.secondary,
                tab: .registries)
            resourceTile(
                title: "Reclaimable",
                value: store.diskUsage.map { ByteFormat.string($0.totalReclaimableBytes) } ?? "—",
                icon: "cache-clean", fallback: "externaldrive.badge.xmark",
                color: Tokens.Palette.warning,
                tab: .dashboard)
        }
    }

    private var localImageSize: String {
        guard store.localImageBytes <= UInt64(Int64.max) else {
            return "≥\(ByteFormat.string(Int64.max))"
        }
        return ByteFormat.string(store.localImageBytes)
    }

    private func resourceTile(
        title: String, value: String, icon: String, fallback: String, color: Color, tab: AppStore.ActiveTab
    )
        -> some View
    {
        Button {
            store.activeTab = tab
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: Tokens.Spacing.sm) {
                    WorkspaceIconTile(name: icon, size: 28, iconSize: 16, color: color, fallback: fallback)
                    Text(title)
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(Tokens.Typography.body.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(value)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Spacing.md)
            .cardSurface(cornerRadius: Tokens.Radius.lg, fillOpacity: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Disk usage card

    private var diskUsageCard: some View {
        PanelCard(title: "Disk Usage", icon: "storage", subtitle: "Bars show the reclaimable share of each category.") {
            if let usage = store.diskUsage {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Total reclaimable")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(ByteFormat.string(usage.totalReclaimableBytes))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Tokens.Palette.warning)
                    }
                    categoryRow(name: "Containers", category: usage.containers)
                    categoryRow(name: "Images", category: usage.images)
                    categoryRow(name: "Volumes", category: usage.volumes)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading,
                        spacing: 8
                    ) {
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
            WorkspaceBudgetMeter(
                used: category.reclaimableBytes, cap: category.sizeBytes,
                label: "\(name) reclaimable storage", color: Tokens.Palette.warning)
            Text(ByteFormat.string(category.sizeBytes))
                .font(.caption2.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            if category.reclaimableBytes > 0 {
                Text("\(ByteFormat.string(category.reclaimableBytes)) reclaimable")
                    .font(.caption2)
                    .foregroundStyle(Tokens.Palette.warning)
            }
        }
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
        PanelCard(title: "Workloads", icon: "workloads") {
            let running = store.containers.lazy.filter { $0.state == "running" }
            let visible = Array(running.prefix(8))
            if running.isEmpty {
                Text("No running workloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, container in
                        if index > 0 {
                            Divider().padding(.leading, 42)
                        }
                        DashboardContainerRow(
                            container: container,
                            stats: store.statsByID[container.id])
                    }
                    if running.count > visible.count {
                        Divider()
                        Button("View all \(running.count) running workloads") {
                            store.activeTab = .workloads
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct DashboardContainerRow: View {
    let container: Micropod_V1_Container
    let stats: Micropod_V1_ContainerStats?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metadata: WorkloadMetadata {
        WorkloadMetadata(labels: container.labels)
    }

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceIconTile(name: "container", size: 32, iconSize: 18, fallback: "shippingbox")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(container.id)
                        .font(Tokens.Typography.body.weight(.semibold))
                        .lineLimit(1)
                    Text(container.image)
                        .font(Tokens.Typography.metadata)
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
        .padding(.vertical, Tokens.Spacing.sm)
    }

    private var workloadMetadata: some View {
        HStack(spacing: 8) {
            WorkspaceStatusBadge(title: "Running", color: Tokens.Palette.success, compact: true)
            // Provenance is a fact, not an action — no arrow glyph for direct
            // launches (it read as a link). Compose keeps its stack icon.
            if metadata.source == .compose {
                Label("Compose", systemImage: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Text("Direct")
                    .foregroundStyle(.secondary)
            }
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
            WorkspaceIcon(name: icon == "cpu" ? "cpu" : "memory", size: 12, fallback: icon)
                .foregroundStyle(Tokens.Palette.secondary)
            Text(text)
                .font(.caption2.monospacedDigit())
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: text)
        }
    }
}
