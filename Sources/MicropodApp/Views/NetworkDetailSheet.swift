import MicropodCore
import SwiftUI

/// Network detail sheet: subnet/gateway/plugin/mode + attached containers
/// (with IPs) + delete with in-use warning.
struct NetworkDetailSheet: View {
    @Bindable var store: AppStore
    let network: Micropod_V1_Network

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "network").foregroundStyle(Color.accentColor)
                Text(network.id).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if network.builtin { Text(String(localized: "builtin")).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                if !network.builtin {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                    .controlSize(.small)
                }
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metaSection
                    attachedSection
                }
                .padding(4)
            }

            if attachedRunning {
                Text(String(localized: "Containers are attached to this network. Deleting it will disconnect them."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
        .confirmationDialog(
            attachedRunning ? String(localized: "Delete in-use network?") : String(localized: "Delete network?"),
            isPresented: $confirmDelete
        ) {
            Button(String(localized: "Delete Network"), role: .destructive) {
                Task { await store.deleteNetwork(network.id) }
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                attachedRunning
                    ? String(
                        localized: "\(attachedContainers.count) container(s) are attached. Deleting disconnects them.")
                    : String(localized: "This cannot be undone."))
        }
    }

    private var metaSection: some View {
        section(String(localized: "Details")) {
            copyRow(String(localized: "Mode"), network.mode.isEmpty ? "—" : network.mode)
            copyRow(String(localized: "Plugin"), network.plugin.isEmpty ? "—" : network.plugin)
            copyRow(String(localized: "Subnet"), network.ipv4Subnet.isEmpty ? "—" : network.ipv4Subnet)
            copyRow(String(localized: "Gateway"), network.ipv4Gateway.isEmpty ? "—" : network.ipv4Gateway)
            copyRow(String(localized: "IPv6 subnet"), network.ipv6Subnet.isEmpty ? "—" : network.ipv6Subnet)
            if !network.labels.isEmpty {
                ForEach(Array(network.labels.keys.sorted()), id: \.self) { key in
                    copyRow(String(localized: "Label \(key)"), network.labels[key] ?? "")
                }
            }
        }
    }

    private var attachedSection: some View {
        section(String(localized: "Attached containers")) {
            if attachedContainers.isEmpty {
                Text(String(localized: "No containers attached"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(attachedContainers, id: \.id) { container in
                    HStack(spacing: 6) {
                        Circle().fill(ContainerStateStyle.color(for: container.state)).frame(
                            width: 6, height: 6)
                        Text(container.id).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        if !container.ipv4Address.isEmpty {
                            Text(container.ipv4Address)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(container.state).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private var attachedContainers: [Micropod_V1_Container] {
        store.containers.filter { $0.networks.contains(network.id) }
    }

    private var attachedRunning: Bool {
        attachedContainers.contains { $0.state == "running" }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).font(.subheadline.monospaced()).lineLimit(1).textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Copy"))
        }
        .padding(.vertical, 2)
    }
}
