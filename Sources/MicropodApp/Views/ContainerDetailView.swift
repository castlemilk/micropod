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

    private var container: Micropod_V1_Container? {
        store.containers.first { $0.id == containerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let container {
                header(container)
                Divider()
                Picker("Pane", selection: $pane) {
                    ForEach(Pane.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                switch pane {
                case .overview: ContainerOverviewView(store: store, containerID: containerID)
                case .logs: ContainerLogsView(store: store, containerID: containerID)
                case .stats: ContainerStatsView(store: store, containerID: containerID)
                case .inspect: ContainerInspectView(store: store, containerID: containerID)
                case .config: ContainerConfigView(container: container)
                case .files: ContainerFilesView(store: store, containerID: containerID)
                case .terminal: ContainerTerminalView(store: store, containerID: containerID)
                }
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
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                Text(container.image)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                Spacer()
                actionButtons(container)
            }
            HStack(spacing: 12) {
                infoItem("State", container.state)
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
            .font(.caption)
        }
        .padding(12)
        .background(.background.secondary)
    }

    @State private var confirmDeleteID: String?

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
        } else {
            Button {
                Task { await store.startContainer(container.id) }
            } label: {
                IconLabel(title: "Start", icon: "start", fallback: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        Button(role: .destructive) {
            confirmDeleteID = container.id
        } label: {
            IconLabel(title: "Delete", icon: "delete", fallback: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy container ID")
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.monospaced(.caption)())
        }
    }

    private func stateColor(_ container: Micropod_V1_Container) -> Color {
        ContainerStateStyle.color(for: container.state)
    }
}
