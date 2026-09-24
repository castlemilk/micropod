import MicropodCore
import SwiftUI

/// Human-readable view of a container's configuration (curated proto model).
struct ContainerConfigView: View {
    let container: Micropod_V1_Container

    var body: some View {
        ScrollView {
            Form {
                Section("Identity") {
                    LabeledContent("ID", value: container.id)
                    LabeledContent("Image", value: container.image)
                    LabeledContent("Created", value: container.createdAt)
                    LabeledContent("Runtime", value: container.runtimeHandler)
                }
                Section("Resources") {
                    LabeledContent(
                        "CPUs", value: container.resources.cpus > 0 ? "\(container.resources.cpus)" : "default")
                    LabeledContent(
                        "Memory",
                        value: container.resources.memoryBytes > 0
                            ? ByteFormat.string(container.resources.memoryBytes) : "default")
                }
                Section("Networking") {
                    LabeledContent(
                        "Networks", value: container.networks.isEmpty ? "—" : container.networks.joined(separator: ", ")
                    )
                    LabeledContent("IPv4", value: container.ipv4Address.isEmpty ? "—" : container.ipv4Address)
                    if !container.publishedPorts.isEmpty {
                        ForEach(Array(container.publishedPorts.enumerated()), id: \.offset) { _, port in
                            LabeledContent(
                                "Published", value: "\(port.hostPort):\(port.containerPort)/\(port.protocol)")
                        }
                    }
                }
                Section("Flags") {
                    LabeledContent("Rosetta", value: container.rosetta ? "on" : "off")
                    LabeledContent("Read-only", value: container.readOnly ? "on" : "off")
                    LabeledContent("Init", value: container.useInit ? "on" : "off")
                    LabeledContent("SSH forward", value: container.ssh ? "on" : "off")
                    LabeledContent("Virtualization", value: container.virtualization ? "on" : "off")
                }
                if !container.env.isEmpty {
                    Section("Environment") {
                        ForEach(Array(container.env.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.subheadline.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                if !container.mounts.isEmpty {
                    Section("Mounts") {
                        ForEach(Array(container.mounts.enumerated()), id: \.offset) { _, mount in
                            LabeledContent(
                                "\(mount.destination)",
                                value: mount.source.isEmpty
                                    ? mount.type : "\(mount.source) (\(mount.type))\(mount.readOnly ? " ro" : "")")
                        }
                    }
                }
                if !container.labels.isEmpty {
                    Section("Labels") {
                        ForEach(Array(container.labels.keys.sorted()), id: \.self) { key in
                            LabeledContent(key, value: container.labels[key] ?? "")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}
