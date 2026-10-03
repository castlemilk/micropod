import MicropodCore
import SwiftUI

/// Container detail: header + tabbed panes (Logs, Stats, Inspect, Config, Files, Terminal).
struct ContainerDetailView: View {
    @Bindable var store: AppStore
    let containerID: String

    enum Pane: String, CaseIterable, Identifiable {
        case overview, logs, stats, inspect, config, files, terminal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .logs: "Logs"
            case .stats: "Stats"
            case .inspect: "Inspect (JSON)"
            case .config: "Config"
            case .files: "Files"
            case .terminal: "Terminal"
            }
        }
    }

    @State private var pane: Pane = .overview

    init(store: AppStore, containerID: String, initialPane: Pane = .overview) {
        self._store = Bindable(store)
        self.containerID = containerID
        self._pane = State(initialValue: initialPane)
    }

    private var container: Micropod_V1_Container? {
        store.containers.first { $0.id == containerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let container {
                header(container)
                Divider()
                ViewThatFits(in: .horizontal) {
                    Picker("Pane", selection: $pane) {
                        ForEach(Pane.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    Picker("Inspector", selection: $pane) {
                        ForEach(Pane.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.menu)
                    .tint(Tokens.Palette.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                Group {
                    switch pane {
                    case .overview: ContainerOverviewView(store: store, containerID: containerID)
                    case .logs: ContainerLogsView(store: store, containerID: containerID)
                    case .stats: ContainerStatsView(store: store, containerID: containerID)
                    case .inspect: ContainerInspectView(store: store, containerID: containerID)
                    case .config: ContainerConfigView(container: container)
                    case .files: ContainerFilesView(store: store, containerID: containerID)
                    case .terminal: ContainerTerminalView(store: store, containerID: containerID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Container Deleted",
                    systemImage: "shippingbox",
                    description: Text("This container no longer exists."))
            }
        }
        .onChange(of: containerID) { _, _ in
            pane = .overview
        }
        .sheet(isPresented: $showRunAgainSheet) {
            RunContainerSheet(store: store, initialImage: container?.image ?? "alpine:latest")
        }
        .confirmationDialog(
            "Delete Container?",
            isPresented: Binding(
                get: { confirmDeleteID != nil },
                set: { if !$0 { confirmDeleteID = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteID {
                    confirmDeleteID = nil
                    Task { await store.deleteContainer(id, force: true) }
                }
            }
            Button("Cancel", role: .cancel) { confirmDeleteID = nil }
        } message: {
            Text("Deleting a container is irreversible. This removes the container and its writable layer.")
        }
    }

    private func header(_ container: Micropod_V1_Container) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor(container))
                    .frame(width: 9, height: 9)
                Text(container.id)
                    .font(Tokens.Typography.section)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(container.id, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy container ID")
                .accessibilityLabel("Copy container ID")
            }
            Text(container.image)
                .font(Tokens.Typography.metadata)
                .foregroundStyle(Tokens.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(container.image)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(ContainerStateStyle.label(for: container.state).localizedCapitalized)
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.secondary)
                Spacer(minLength: 4)
                actionButtons(container)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 4
            ) {
                if !container.ipv4Address.isEmpty {
                    infoItem("IP", container.ipv4Address)
                }
                if !container.platform.isEmpty {
                    infoItem("Platform", container.platform)
                }
                if container.resources.cpus > 0 {
                    infoItem("CPUs", "\(container.resources.cpus)")
                }
                if container.resources.memoryBytes > 0 {
                    infoItem("Memory", ByteFormat.string(container.resources.memoryBytes))
                }
                if container.rosetta { infoItem("Rosetta", "on") }
            }
            .font(Tokens.Typography.metadata)
        }
        .padding(12)
        .background(Tokens.Palette.canvas)
    }

    @State private var confirmDeleteID: String?
    @State private var showRunAgainSheet = false

    @ViewBuilder
    private func actionButtons(_ container: Micropod_V1_Container) -> some View {
        if container.state == "running" {
            Button {
                Task { await store.stopContainer(container.id) }
            } label: {
                IconLabel(title: "Stop", icon: "stop", fallback: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if container.runtime == "sandbox" {
            Button("Run image…") { showRunAgainSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Ephemeral VMs cannot restart. Open the new-container form using this image.")
        } else {
            Button {
                Task { await store.startContainer(container.id) }
            } label: {
                IconLabel(title: "Start", icon: "start", fallback: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        Menu {
            Button("Delete…", role: .destructive) { confirmDeleteID = container.id }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .accessibilityLabel("More container actions")
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                .truncationMode(.middle).help(value)
        }
    }

    private func stateColor(_ container: Micropod_V1_Container) -> Color {
        ContainerStateStyle.color(for: container.state)
    }
}
