import MicropodCore
import SwiftUI

/// Networks tab: list + create/delete/prune (macOS 26+).
struct NetworksView: View {
    @Bindable var store: AppStore

    @State private var showCreateSheet = false
    @State private var confirmPrune = false
    @State private var confirmDelete: String?
    @State private var mode: Mode = .list
    @State private var detail: NetworkDetailSelection?

    enum Mode: String, CaseIterable, Identifiable {
        case list, topology
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.networks.count) networks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer()
                Button(role: .destructive) {
                    confirmPrune = true
                } label: {
                    IconLabel(title: "Prune Unused", icon: "prune", fallback: "trash")
                }
                .controlSize(.small)
                Button {
                    showCreateSheet = true
                } label: {
                    IconLabel(title: "Create", icon: "create", fallback: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(8)

            Divider()

            switch mode {
            case .list:
                listMode
            case .topology:
                NetworkTopologyView(store: store)
            }
        }
        .task {
            if store.networks.isEmpty { await store.refreshNetworks() }
        }
        .confirmationDialog(
            "Prune Unused Networks?",
            isPresented: $confirmPrune
        ) {
            Button("Prune", role: .destructive) {
                Task { await store.pruneNetworks() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes networks with no container connections. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete network?",
            isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { name in
            Button("Delete", role: .destructive) {
                Task { await store.deleteNetwork(name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateNetworkSheet(store: store)
        }
        .sheet(item: $detail) { selection in
            NetworkDetailSheet(store: store, network: selection.network)
        }
    }

    @ViewBuilder
    private var listMode: some View {
        if store.networks.isEmpty {
            EmptyStateView(
                title: String(localized: "No Networks"),
                description: String(localized: "User-defined networks let containers talk to each other."),
                imageName: EmptyStateArtwork.networks,
                symbol: "network",
                actionTitle: String(localized: "Create network"),
                action: { showCreateSheet = true })
        } else {
            List {
                ForEach(store.networks) { network in
                    NetworkRowView(network: network)
                        .contextMenu {
                            if !network.builtin {
                                Button(role: .destructive) {
                                    confirmDelete = network.id
                                } label: {
                                    MenuItemIconLabel(title: "Delete", icon: "delete", fallback: "trash")
                                }
                            }
                        }
                        .onTapGesture(count: 2) {
                            detail = NetworkDetailSelection(network: network)
                        }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct NetworkRowView: View, @MainActor Equatable {
    let network: Micropod_V1_Network

    static func == (lhs: NetworkRowView, rhs: NetworkRowView) -> Bool {
        lhs.network == rhs.network
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: network.builtin ? "network.badge.shield.half.filled" : "network")
                .foregroundStyle(network.builtin ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(network.id).font(.callout.weight(.medium))
                    if network.builtin {
                        Text("builtin").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if network.mode == "internal" || network.mode == "hostOnly" {
                        Text("internal").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if !network.ipv4Subnet.isEmpty {
                    Text(network.ipv4Subnet)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(network.plugin).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct CreateNetworkSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var internalNetwork = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Network").font(.title3.weight(.semibold))
            TextField("Network name", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Internal (host-only)", isOn: $internalNetwork).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await store.createNetwork(name: name, internalNetwork: internalNetwork) }
                    dismiss()
                } label: {
                    IconLabel(title: "Create", icon: "create", fallback: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
