import AppKit
import MicropodCore
import SwiftUI

/// Keep this root a plain VStack: MenuBarExtra needs a bounded fitting height.
struct MenuBarPanelView: View {
    @Bindable var store: AppStore
    var activateRuntimeObservation = true
    /// Native lifecycle tests can observe cache reads without bootstrapping a runtime.
    var cacheRefresh: (@MainActor () async -> Void)? = nil
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRuntimeStop = false
    @State private var cacheObservation = MenuBarCacheObservation()

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            resourceSummary
            workloadSection
            cacheSection
            if !store.activity.isEmpty { activitySection }
            bottomActions
        }
        .padding(14)
        .frame(width: Tokens.Layout.trayWidth)
        .background(Tokens.Palette.canvas)
        .onAppear {
            if activateRuntimeObservation {
                store.bootstrap()
                store.setPanelVisible(true)
            }
            if activateRuntimeObservation || cacheRefresh != nil {
                cacheObservation.open(refresh: cacheRefresh ?? { await store.refreshMenuBarCaches() })
            }
        }
        .onDisappear {
            cacheObservation.close()
            if activateRuntimeObservation { store.setPanelVisible(false) }
        }
        .confirmationDialog("Stop the runtime?", isPresented: $confirmRuntimeStop, titleVisibility: .visible) {
            Button("Stop runtime", role: .destructive) { Task { await store.stopRuntime() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This interrupts \(store.runtimeStopAffectedCount) running workloads managed by the Apple runtime. You can start the runtime again from this menu."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Micropod").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    StatusDot(color: healthColor, size: 6, active: runtimeTransitioning)
                    Text(healthLabel).font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 4)
            Button {
                openAndSet { store.activeTab = .settings }
            } label: {
                WorkspaceIcon(name: "settings", size: 18, fallback: "gearshape")
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.Palette.secondary)
            .help("Micropod settings").accessibilityLabel("Open Micropod settings")
            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            if store.isRuntimeRunning {
                Button("Stop runtime…", systemImage: "stop.circle", role: .destructive) { requestRuntimeStop() }
                    .disabled(runtimeTransitioning)
            } else if store.clientAvailable {
                Button("Start runtime", systemImage: "play.circle") { Task { await store.startRuntime() } }
                    .disabled(runtimeTransitioning)
            } else {
                Button("Retry runtime detection", systemImage: "arrow.clockwise") {
                    Task { await store.refreshSystemStatus(force: true) }
                }
            }
            Divider()
            Button("Pull image…", systemImage: "arrow.down.to.line") {
                openAndSet {
                    store.activeTab = .images
                    store.pendingPullSheet = true
                }
            }
            Button("Command palette…", systemImage: "command") {
                openAndSet { store.showCommandPalette = true }
            }
            Divider()
            if let version = UpdateController.shared.stagedVersion {
                Button("Install update \(version)", systemImage: "arrow.down.circle") {
                    Task { await UpdateController.shared.applyStagedUpdate() }
                }
                .disabled(!UpdateController.shared.restartGuard.isAvailable)
            } else {
                Button("Check for updates…", systemImage: "arrow.triangle.2.circlepath") {
                    UpdateController.shared.checkForUpdates()
                }
                .disabled(!UpdateController.shared.canCheckForUpdates)
            }
            Button("Quit Micropod", systemImage: "power") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Runtime and more actions").accessibilityLabel("Runtime and more actions")
    }

    private var resourceSummary: some View {
        let metrics = MenuBarGuestMetrics(workloads: runningWorkloads, available: store.isRuntimeRunning)
        return card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    metric(
                        "\(runningWorkloads.count)",
                        label: store.isRuntimeRunning ? "Running compute" : "Last seen compute")
                    metric(metrics.cpuText, label: "CPU · cores")
                    metric(metrics.memoryText, label: "Guest memory")
                }
                // Runtime state and resource samples describe compute, not
                // runner job activity. Without a fresh, identity-bound job
                // observation we cannot label a running runner busy or idle.
                HStack(spacing: 10) {
                    Text("Active jobs: Unknown").fixedSize()
                    Text(metrics.detail).lineLimit(1)
                        .foregroundStyle(Tokens.Palette.tertiary)
                }
                .font(.system(size: 10)).foregroundStyle(Tokens.Palette.secondary)
                .accessibilityElement(children: .combine)
                .help("Job activity is unavailable. Running compute includes idle runners. \(metrics.detail).")
            }
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Tokens.Typography.metric)
                .foregroundStyle(Tokens.Palette.primary).lineLimit(1).minimumScaleFactor(0.75)
            Text(label).font(.system(size: 10)).foregroundStyle(Tokens.Palette.secondary).lineLimit(1)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(value)")
    }

    private var workloadSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading("Running compute", icon: "workloads") {
                Button("View all") { openAndSet { store.activeTab = .workloads } }
                    .buttonStyle(.plain).foregroundStyle(Tokens.Palette.accentText)
                    .help("Open all containers and microVMs")
                    .accessibilityLabel("View all containers and microVMs")
            }
            card {
                if runningWorkloads.isEmpty {
                    HStack(spacing: 8) {
                        WorkspaceIcon(name: "workloads", size: 18, fallback: "square.stack.3d.up")
                        Text(store.isRuntimeRunning ? "No workloads running" : "Start the runtime to run workloads")
                            .lineLimit(2)
                    }
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary).padding(.vertical, 7)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(runningWorkloads.prefix(3).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            workloadShortcut(item)
                        }
                        if runningWorkloads.count > 3 {
                            Text("+\(runningWorkloads.count - 3) more running · View all to inspect")
                                .font(.system(size: 10)).foregroundStyle(Tokens.Palette.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                        }
                    }
                }
            }
        }
    }

    private func workloadShortcut(_ item: WorkloadItem) -> some View {
        Button {
            openAndSet { store.openWorkload(item) }
        } label: {
            HStack(spacing: 8) {
                WorkspaceIconTile(
                    name: item.kind == .container ? "container" : "microvm", size: 28, iconSize: 16,
                    color: Tokens.Palette.accentText, fallback: item.kind.symbol
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Tokens.Palette.primary).lineLimit(1).truncationMode(.middle)
                    Text("\(item.kindLabel) · \(item.engineLabel)").font(.system(size: 10))
                        .foregroundStyle(Tokens.Palette.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(
                        item.metricsAreStale(at: Date())
                            ? "— cores" : item.cpuCores.map { String(format: "%.2f cores", $0) } ?? "— cores")
                    Text(item.metricsAreStale(at: Date()) ? "—" : item.memoryBytes.map(ByteFormat.string) ?? "—")
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tokens.Palette.secondary)
                .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Tokens.Palette.tertiary)
            }
            .frame(height: 42).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(item.name), \(item.kindLabel), \(item.state)").help("Inspect \(item.name)")
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading("Cache", icon: "cache") {
                Button {
                    cacheObservation.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.Palette.secondary)
                .disabled(store.cacheStore.isRefreshing || store.ciCacheStore.isRefreshing)
                .help("Refresh cache observations").accessibilityLabel("Refresh cache observations")
                Button("Manage") { openAndSet { store.activeTab = .cache } }
                    .buttonStyle(.plain).foregroundStyle(Tokens.Palette.accentText)
                    .accessibilityLabel("Open cache management")
            }
            card {
                MenuBarCacheView(cache: store.cacheStore, ci: store.ciCacheStore)
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Recent activity").font(Tokens.Typography.metadata.weight(.semibold)).foregroundStyle(
                Tokens.Palette.secondary)
            ForEach(store.recentActivity(limit: 2)) { entry in
                HStack(spacing: 7) {
                    Image(systemName: activityIcon(entry)).font(.system(size: 10))
                        .foregroundStyle(entry.level == .error ? Tokens.Palette.danger : Tokens.Palette.tertiary).frame(
                            width: 12)
                    Text(entry.message).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(entry.timestamp.formatted(.relative(presentation: .named)))
                        .foregroundStyle(Tokens.Palette.tertiary).fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: 10)).foregroundStyle(Tokens.Palette.secondary)
                .help(entry.message).accessibilityElement(children: .combine)
            }
        }
    }

    private var bottomActions: some View {
        HStack(spacing: 8) {
            Button {
                openAndSet {
                    store.activeTab = .workloads
                    store.pendingRunSheet = true
                }
            } label: {
                HStack(spacing: 6) {
                    WorkspaceIcon(name: "play", size: 14, fallback: "play")
                    Text("Run…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Tokens.Palette.action)
            .accessibilityLabel("Run a container")
            Button {
                openAndSet {}
            } label: {
                HStack(spacing: 6) {
                    WorkspaceIcon(name: "external-link", size: 14, fallback: "arrow.up.right.square")
                    Text("Open Micropod")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: Tokens.Radius.lg, fillOpacity: 1)
    }

    private func sectionHeading<Action: View>(_ title: String, icon: String, @ViewBuilder action: () -> Action)
        -> some View
    {
        HStack {
            WorkspaceIcon(name: icon, size: 14, fallback: "square.stack.3d.up")
                .foregroundStyle(Tokens.Palette.secondary)
            Text(title).fontWeight(.semibold).foregroundStyle(Tokens.Palette.secondary)
            Spacer(minLength: 4)
            action()
        }
        .font(Tokens.Typography.metadata)
    }

    private var runningWorkloads: [WorkloadItem] {
        store.workloadItems.filter(\.isRunning).sorted {
            let lhs = $0.cpuCores ?? -1, rhs = $1.cpuCores ?? -1
            return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs > rhs
        }
    }
    private var runtimeTransitioning: Bool {
        store.isStartingRuntime || store.isRestartingRuntime || store.isHealingRuntime || store.isInstallingKernel
    }
    private var healthLabel: String {
        if !store.clientAvailable { return "Runtime unavailable" }
        if store.isHealingRuntime { return "Recovering runtime…" }
        if store.isStartingRuntime || store.isRestartingRuntime { return "Starting runtime…" }
        if store.isInstallingKernel { return "Installing Linux kernel…" }
        if store.runtimeHealth == .wedged { return "Runtime unresponsive" }
        if !store.isRuntimeRunning { return "Runtime stopped" }
        if agentsDegraded { return "Runtime running · helper unavailable" }
        return store.runtimeHealth == .healthy ? "Runtime healthy" : "Runtime running · checking health"
    }
    private var healthColor: Color {
        if !store.clientAvailable { return Tokens.Palette.danger }
        if runtimeTransitioning || store.runtimeHealth == .wedged || agentsDegraded { return Tokens.Palette.warning }
        return store.isRuntimeRunning && store.runtimeHealth == .healthy
            ? Tokens.Palette.success : Tokens.Palette.tertiary
    }
    private var agentsDegraded: Bool {
        store.agentStatuses.contains { $0.state == .retryPending || $0.state == .missing }
    }
    private func requestRuntimeStop() {
        if store.runtimeStopAffectedCount == 0 { Task { await store.stopRuntime() } } else { confirmRuntimeStop = true }
    }
    private func openAndSet(_ configure: () -> Void) {
        configure()
        dismiss()
        MainWindowPresenter.shared.show { openWindow(id: MainWindowPresenter.sceneID) }
    }
    private func activityIcon(_ entry: ActivityEntry) -> String {
        switch entry.level {
        case .success: "checkmark.circle"
        case .error: "exclamationmark.circle"
        case .info: "clock"
        }
    }
}

/// Missing/stale samples remain unavailable. Partial guest totals are lower
/// bounds; these values never claim to include host/runtime memory overhead.
struct MenuBarGuestMetrics {
    let cpuText: String
    let memoryText: String
    let detail: String

    init(workloads: [WorkloadItem], available: Bool = true, at date: Date = Date()) {
        let running = workloads.filter(\.isRunning)
        let fresh = available ? running.filter { !$0.metricsAreStale(at: date) } : []
        let cpu = fresh.compactMap(\.cpuCores).filter { $0.isFinite && $0 >= 0 }
        let memory = fresh.compactMap(\.memoryBytes)
        cpuText =
            cpu.isEmpty ? "—" : "\(cpu.count < running.count ? "≥ " : "")\(String(format: "%.2f", cpu.reduce(0, +)))"
        let memorySum = memory.reduce(UInt64(0)) { sum, value in
            let result = sum.addingReportingOverflow(value)
            return result.overflow ? UInt64.max : result.partialValue
        }
        memoryText = memory.isEmpty ? "—" : "\(memory.count < running.count ? "≥ " : "")\(ByteFormat.string(memorySum))"
        let sampled = fresh.count { $0.cpuCores != nil && $0.memoryBytes != nil }
        if !available {
            detail = "Guest measurements unavailable"
        } else if cpu.isEmpty && memory.isEmpty {
            detail = "Waiting for guest measurements"
        } else if sampled < running.count {
            detail = "\(sampled) of \(running.count) sampled · totals are lower bounds"
        } else {
            detail = "Guest usage · host overhead excluded"
        }
    }
}
