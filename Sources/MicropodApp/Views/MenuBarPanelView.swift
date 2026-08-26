import AppKit
import MicropodCore
import SwiftUI

/// Menu bar panel: runtime status, quick actions, running containers,
/// recent activity, and deep links into the main window.
///
/// Rendering rules (learned from feedback):
/// - The ROOT must stay a plain VStack — a ScrollView root breaks the
///   MenuBarExtra popover window. Variable sections are internally bounded.
/// - Quick actions live in a 2×2 grid so labels never clip.
/// - Values use `.fixedSize(horizontal:)` + monospaced digits so stats never
///   truncate; only the container image names middle-truncate.
/// - The panel stays 320 pt wide, so compact stats must not rely on truncation.
struct MenuBarPanelView: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            quickActions
            Divider()
            statsRow
            Divider()
            containerList
            if !store.activity.isEmpty {
                Divider()
                recentActivity
            }
            Divider()
            footer
        }
        .padding(10)
        .frame(width: 340)
        .task { store.bootstrap() }
        // Keep the pollers running while the panel is open — otherwise tray
        // data could be up to 30s stale (pollers sleep when the main window
        // is hidden). Independent of the main window's own visibility flag.
        .onAppear { store.setPanelVisible(true) }
        .onDisappear { store.setPanelVisible(false) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            EmptyStateView.brandMark(EmptyStateArtwork.dashboardHero, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Micropod")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .padding(.bottom, 8)
    }

    // MARK: - Quick actions (2×2 grid — no clipped labels)

    private var quickActions: some View {
        // Text-only buttons: the custom icon glyphs cost too much width in the
        // 320 pt popover and pushed the labels into truncation.
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            quickActionButton("Run", icon: "start", fallback: "play.fill") {
                openAndSet {
                    store.activeTab = .containers
                    store.pendingRunSheet = true
                }
            }
            quickActionButton("Pull", icon: "pull", fallback: "arrow.down.circle") {
                openAndSet {
                    store.activeTab = .images
                    store.pendingPullSheet = true
                }
            }
            quickActionButton("Palette", icon: "dashboard", fallback: "command") {
                openAndSet { store.showCommandPalette = true }
            }
            if store.isRuntimeRunning {
                quickActionButton("Stop", icon: "stop", fallback: "stop.fill") {
                    Task { await store.stopRuntime() }
                }
                .help("Stop the container runtime")
            } else if store.clientAvailable {
                quickActionButton("Start", icon: "start", fallback: "play.fill") {
                    Task { await store.startRuntime() }
                }
                .buttonStyle(.borderedProminent)
                .help("Start the container runtime")
            } else {
                quickActionButton("Retry", icon: "refresh", fallback: "arrow.clockwise") {
                    Task { await store.refreshSystemStatus() }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func quickActionButton(
        _ title: String, icon: String, fallback: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: AppIcon.sfName(for: icon))
                    .font(.system(size: 11))
                    .frame(width: 11, height: 11)
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func openAndSet(_ configure: @escaping () -> Void) {
        configure()
        openWindow(id: "main-window")
        dismiss()
    }

    // MARK: - Stats (fixed-size values, never truncated)

    private var statsRow: some View {
        HStack(spacing: 0) {
            statBlock(value: "\(store.runningCount)", label: "running", icon: "containers")
            Spacer(minLength: 4)
            statBlock(value: aggregateCPU ?? "—", label: "cpu", icon: "stats")
            Spacer(minLength: 4)
            statBlock(value: totalMemory, label: "in use", icon: "storage")
            Spacer(minLength: 4)
            statBlock(value: reclaimable, label: "reclaim", icon: "prune")
        }
        .padding(.vertical, 8)
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

    private var containerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Containers")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            if store.containers.isEmpty {
                Text("No containers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.containers.prefix(6)) { container in
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
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
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

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Activity")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.recentActivity(limit: 4)) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: activityIcon(entry))
                                .font(.system(size: 9))
                                .foregroundStyle(activityColor(entry))
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
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 120)
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
        .padding(.top, 8)
    }

    private func shortAPIServerVersion(_ version: String) -> String {
        // "container-apiserver version 1.2.2 (build: release…)" → "1.2.2"
        let parts = version.split(separator: " ")
        return parts.first { $0.hasPrefix("1.") }?.description ?? version
    }

    private var statusLine: String {
        if !store.clientAvailable { return "container CLI not found" }
        if store.isRuntimeRunning {
            return store.runningCount == 1 ? "Running · 1 container" : "Running · \(store.runningCount) containers"
        }
        return "Runtime stopped"
    }

    private func statBlock(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: AppIcon.sfName(for: icon))
                    .font(.system(size: 10))
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
/// click opens the container, the trailing button stops it.
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
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop \(container.id)")
                .accessibilityLabel("Stop \(container.id)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(stateColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
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
