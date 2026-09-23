import AppKit
import MicropodCore
import SwiftUI

/// Menu bar panel: runtime status, quick actions, running containers,
/// recent activity, and deep links into the main window.
///
/// Rendering rules (learned from feedback):
/// - The ROOT must stay a plain VStack — a ScrollView root breaks the
///   MenuBarExtra popover window. Variable sections are internally bounded.
/// - Content is grouped into soft "cards" (Control Center style) instead of
///   edge-to-edge dividers; the popover gets a real margin around everything.
/// - Quick actions live in a 2×2 grid so labels never clip.
/// - Values use `.fixedSize(horizontal:)` + monospaced digits so stats never
///   truncate; only the container image names middle-truncate.
struct MenuBarPanelView: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            quickActions
            statsCard
            containerSection
            if !store.activity.isEmpty {
                activitySection
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 340)
        .task { store.bootstrap() }
        // Keep the pollers running while the panel is open — otherwise tray
        // data could be up to 30s stale (pollers sleep when the main window
        // is hidden). Independent of the main window's own visibility flag.
        .onAppear { store.setPanelVisible(true) }
        .onDisappear { store.setPanelVisible(false) }
    }

    // MARK: - Card container

    /// Soft grouped surface used by every section — the shared cardSurface
    /// treatment (slightly translucent so the popover material shows through).
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: 10, fillOpacity: 0.65)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            EmptyStateView.brandMark(EmptyStateArtwork.dashboardHero, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Micropod")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                openWindow(id: "main-window")
                dismiss()
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 2)
    }

    private var statusDotColor: Color {
        if !store.clientAvailable { return .red }
        if store.isHealingRuntime || store.runtimeHealth == .wedged { return .orange }
        return store.isRuntimeRunning ? .green : .gray
    }

    // MARK: - Quick actions (2×2 grid — no clipped labels)

    private var quickActions: some View {
        // Text-only buttons: the custom icon glyphs cost too much width in the
        // 320 pt popover and pushed the labels into truncation.
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            quickActionButton("Run", icon: "start") {
                openAndSet {
                    store.activeTab = .containers
                    store.pendingRunSheet = true
                }
            }
            quickActionButton("Pull", icon: "pull") {
                openAndSet {
                    store.activeTab = .images
                    store.pendingPullSheet = true
                }
            }
            quickActionButton("Palette", icon: "palette") {
                openAndSet { store.showCommandPalette = true }
            }
            if store.isRuntimeRunning {
                quickActionButton("Stop", icon: "stop") {
                    Task { await store.stopRuntime() }
                }
                .help("Stop the container runtime")
            } else if store.clientAvailable {
                quickActionButton("Start", icon: "start", prominent: true) {
                    Task { await store.startRuntime() }
                }
                .help("Start the container runtime")
            } else {
                quickActionButton("Retry", icon: "refresh") {
                    Task { await store.refreshSystemStatus() }
                }
            }
        }
    }

    /// Control Center-style action tile (shared TileButton in PanelCard.swift).
    private func quickActionButton(
        _ title: String, icon: String, prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        TileButton(title: title, icon: icon, prominent: prominent, action: action)
    }

    private func openAndSet(_ configure: @escaping () -> Void) {
        configure()
        openWindow(id: "main-window")
        dismiss()
    }

    // MARK: - Stats (fixed-size values, never truncated)

    private var statsCard: some View {
        card {
            HStack(spacing: 0) {
                statBlock(value: "\(store.runningCount)", label: "running", icon: "containers")
                statSeparator
                statBlock(value: aggregateCPU ?? "—", label: "cpu", icon: "stats")
                statSeparator
                statBlock(value: totalMemory, label: "in use", icon: "storage")
                statSeparator
                statBlock(value: reclaimable, label: "reclaim", icon: "prune")
            }
        }
    }

    private var statSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 0.5, height: 26)
            .padding(.horizontal, 6)
    }

    /// Total CPU across running containers, e.g. "12%".
    private var aggregateCPU: String? {
        guard store.isRuntimeRunning, let snapshot = store.statsSnapshot else { return nil }
        let total = snapshot.containers.reduce(0.0) { $0 + $1.cpuPercent }
        return String(format: "%.1f%%", total)
    }

    private var totalMemory: String {
        let used = store.statsSnapshot?.containers.reduce(0) { $0 + $1.memoryUsedBytes } ?? 0
        return ByteFormat.string(used)
    }

    private var reclaimable: String {
        guard let usage = store.diskUsage else { return "—" }
        return ByteFormat.string(usage.totalReclaimableBytes)
    }

    // MARK: - Containers

    private var containerSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader("Containers")
                .padding(.horizontal, 2)
            if store.containers.isEmpty {
                card {
                    Text("No containers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                }
            } else {
                card {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(store.containers.prefix(6).enumerated()), id: \.element.id) {
                                index, container in
                                if index > 0 {
                                    Divider().padding(.leading, 18)
                                }
                                MenuBarContainerRow(
                                    container: container,
                                    stats: store.statsByID[container.id]
                                ) {
                                    openContainer(container.id)
                                } onStop: {
                                    Task { await store.stopContainer(container.id) }
                                }
                            }
                            if store.containers.count > 6 {
                                Divider().padding(.leading, 18)
                                Button {
                                    openAndSet { store.activeTab = .containers }
                                } label: {
                                    Label(
                                        "Show all \(store.containers.count) containers…",
                                        systemImage: "square.grid.2x2")
                                }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private func openContainer(_ id: String) {
        store.activeTab = .containers
        store.selectedContainerID = id
        openWindow(id: "main-window")
        dismiss()
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader("Recent Activity")
                .padding(.horizontal, 2)
            card {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.recentActivity(limit: 4).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().padding(.leading, 18)
                            }
                            HStack(spacing: 7) {
                                Image(systemName: activityIcon(entry))
                                    .font(.system(size: 10))
                                    .foregroundStyle(activityColor(entry))
                                    .frame(width: 12)
                                Text(entry.message)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(entry.timestamp.formatted(.relative(presentation: .named)))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let status = store.systemStatus, !status.cliVersion.isEmpty {
                Text("cli \(status.cliVersion)").fixedSize()
            }
            if let status = store.systemStatus, !status.apiServerVersion.isEmpty {
                Text("api \(shortAPIServerVersion(status.apiServerVersion))")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                UpdateController.shared.checkForUpdates()
            } label: {
                IconLabel(title: "Updates", icon: "check", fallback: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            .disabled(!UpdateController.shared.canCheckForUpdates)
            Button {
                openAndSet { store.activeTab = .settings }
            } label: {
                IconLabel(title: "Settings…", icon: "settings", fallback: "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            Button {
                NSApp.terminate(nil)
            } label: {
                IconLabel(title: "Quit", icon: "quit", fallback: "power")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private func shortAPIServerVersion(_ version: String) -> String {
        // "container-apiserver version 1.2.2 (build: release…)" → "1.2.2"
        let parts = version.split(separator: " ")
        return parts.first { $0.hasPrefix("1.") }?.description ?? version
    }

    private var statusLine: String {
        if !store.clientAvailable { return "container CLI not found" }
        if store.isHealingRuntime { return "Recovering runtime…" }
        if store.runtimeHealth == .wedged { return "Runtime unresponsive" }
        if store.isRuntimeRunning {
            return store.runningCount == 1 ? "Running · 1 container" : "Running · \(store.runningCount) containers"
        }
        return "Runtime stopped"
    }

    private func statBlock(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: AppIcon.sfName(for: icon))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .fixedSize(horizontal: true, vertical: false)
                    .lineLimit(1)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func activityIcon(_ entry: ActivityEntry) -> String {
        switch entry.level {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "clock"
        }
    }

    private func activityColor(_ entry: ActivityEntry) -> Color {
        switch entry.level {
        case .success: .green
        case .error: .red
        case .info: .secondary
        }
    }

}

/// One compact row in the menu bar panel: name + live CPU/mem, image below;
/// click opens the container, the trailing button stops it. Rows sit inside
/// a section card separated by inset dividers, so the row itself stays flat.
struct MenuBarContainerRow: View {
    let container: Micropod_V1_Container
    let stats: Micropod_V1_ContainerStats?
    var onOpen: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(container.id)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if container.state == "running" {
                                Text(cpuText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Text(memText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            } else {
                                Text(container.state)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                        }
                        Text(container.image)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(container.id)")

            if container.state == "running" {
                Button(action: onStop) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop \(container.id)")
                .accessibilityLabel("Stop \(container.id)")
            }
        }
        .padding(.vertical, 5)
    }

    private var stateColor: Color { ContainerStateStyle.color(for: container.state) }

    private var cpuText: String {
        guard let stats else { return "—" }
        return String(format: "%.1f%%", stats.cpuPercent)
    }

    private var memText: String {
        guard let stats else { return "—" }
        return ByteFormat.string(stats.memoryUsedBytes)
    }
}
