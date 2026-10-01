import MicropodCore
import SwiftUI

/// Human-readable view of a container's configuration (curated proto model).
struct ContainerConfigView: View {
    let container: Micropod_V1_Container

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                configSection("Identity") {
                    InspectorFieldRow(label: "ID", value: container.id)
                    InspectorFieldRow(label: "Image", value: container.image)
                    InspectorFieldRow(label: "Created", value: container.createdAt)
                    InspectorFieldRow(label: "Runtime", value: container.runtimeHandler)
                }
                configSection("Resources") {
                    InspectorFieldRow(
                        label: "CPUs", value: container.resources.cpus > 0 ? "\(container.resources.cpus)" : "default")
                    InspectorFieldRow(
                        label: "Memory",
                        value: container.resources.memoryBytes > 0
                            ? ByteFormat.string(container.resources.memoryBytes) : "default")
                }
                configSection("Networking") {
                    InspectorFieldRow(
                        label: "Networks",
                        value: container.networks.isEmpty ? "—" : container.networks.joined(separator: ", ")
                    )
                    InspectorFieldRow(label: "IPv4", value: container.ipv4Address.isEmpty ? "—" : container.ipv4Address)
                    if !container.publishedPorts.isEmpty {
                        ForEach(Array(container.publishedPorts.enumerated()), id: \.offset) { _, port in
                            InspectorFieldRow(
                                label: "Published", value: "\(port.hostPort):\(port.containerPort)/\(port.protocol)")
                        }
                    }
                }
                configSection("Flags") {
                    InspectorFieldRow(label: "Rosetta", value: container.rosetta ? "on" : "off")
                    InspectorFieldRow(label: "Read-only", value: container.readOnly ? "on" : "off")
                    InspectorFieldRow(label: "Init", value: container.useInit ? "on" : "off")
                    InspectorFieldRow(label: "SSH forward", value: container.ssh ? "on" : "off")
                    InspectorFieldRow(label: "Virtualization", value: container.virtualization ? "on" : "off")
                }
                if !container.env.isEmpty {
                    configSection("Environment") {
                        ForEach(Array(container.env.enumerated()), id: \.offset) { _, line in
                            InspectorFieldRow(label: "Variable", value: line)
                        }
                    }
                }
                if !container.mounts.isEmpty {
                    configSection("Mounts") {
                        ForEach(Array(container.mounts.enumerated()), id: \.offset) { _, mount in
                            InspectorFieldRow(
                                label: "\(mount.destination)",
                                value: mount.source.isEmpty
                                    ? mount.type : "\(mount.source) (\(mount.type))\(mount.readOnly ? " ro" : "")")
                        }
                    }
                }
                if !container.labels.isEmpty {
                    configSection("Labels") {
                        ForEach(Array(container.labels.keys.sorted()), id: \.self) { key in
                            InspectorFieldRow(label: key, value: container.labels[key] ?? "")
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func configSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Tokens.Typography.section).foregroundStyle(Tokens.Palette.secondary)
            VStack(alignment: .leading, spacing: 6, content: content)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        }
    }
}

/// Inspector fields use a horizontal row only when the complete label and value fit.
/// The compact layout wraps long paths and identifiers, without hiding their copy action.
struct InspectorFieldRow: View {
    let label: String
    let value: String
    var primaryAction: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                labelText.frame(width: 90, alignment: .leading)
                valueText.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                actions
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 3) {
                labelText
                HStack(alignment: .top, spacing: 8) {
                    valueText.frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelText: some View {
        Text(label).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var valueText: some View {
        Text(value.isEmpty ? "—" : value)
            .font(.subheadline.monospaced())
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let primaryAction {
                Button(action: primaryAction) { Image(systemName: "safari") }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
                    .accessibilityLabel("Open in browser")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(label)")
            .accessibilityLabel("Copy \(label)")
        }
        .fixedSize()
    }
}
