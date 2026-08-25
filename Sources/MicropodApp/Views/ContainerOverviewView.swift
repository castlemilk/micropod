import MicropodCore
import SwiftUI

/// Overview inspector pane: state, identity, networking (with smart
/// open-in-browser ports), resources, env, labels, mounts — every row
/// copyable, live stats when available.
struct ContainerOverviewView: View {
    @Bindable var store: AppStore
    let containerID: String

    private var container: Micropod_V1_Container? {
        store.containers.first { $0.id == containerID }
    }

    private var stats: Micropod_V1_ContainerStats? {
        store.statsByID[containerID]
    }

    var body: some View {
        ScrollView {
            if let container {
                VStack(alignment: .leading, spacing: 16) {
                    identitySection(container)
                    if !container.publishedPorts.isEmpty || !container.networks.isEmpty {
                        networkingSection(container)
                    }
                    resourcesSection(container)
                    if !container.env.isEmpty { envSection(container) }
                    if !container.labels.isEmpty { labelsSection(container) }
                    if !container.mounts.isEmpty { mountsSection(container) }
                }
                .padding(14)
            } else {
                ContentUnavailableView("Container Deleted", systemImage: "shippingbox")
            }
        }
    }

    // MARK: - Sections

    private func identitySection(_ container: Micropod_V1_Container) -> some View {
        section("Identity") {
            HStack(spacing: 6) {
                Circle().fill(stateColor(container.state)).frame(width: 8, height: 8)
                Text(container.state.capitalized)
                    .font(.callout.weight(.medium))
                Spacer()
                copyButton(container.state)
            }
            copyRow("ID", container.id)
            copyRow("Image", container.image)
            if !container.createdAt.isEmpty {
                copyRow("Created", relativeCreated(container))
            }
            if !container.platform.isEmpty { copyRow("Platform", container.platform) }
            if !container.runtimeHandler.isEmpty { copyRow("Runtime", container.runtimeHandler) }
            if !container.exitCode.isEmpty { copyRow("Exit code", container.exitCode) }
        }
    }

    private func networkingSection(_ container: Micropod_V1_Container) -> some View {
        section("Networking") {
            if !container.ipv4Address.isEmpty {
                copyRow("IP", container.ipv4Address)
            }
            if !container.networks.isEmpty {
                copyRow("Networks", container.networks.joined(separator: ", "))
            }
            if !container.publishedPorts.isEmpty {
                ForEach(Array(container.publishedPorts.enumerated()), id: \.offset) { _, port in
                    let text = "\(port.hostPort):\(port.containerPort)/\(port.protocol)"
                    smartRow(
                        label: "Port",
                        value: text,
                        primaryAction: openPort(container, port.hostPort)
                    )
                }
            }
        }
    }

    private func resourcesSection(_ container: Micropod_V1_Container) -> some View {
        section("Resources") {
            if let stats {
                HStack(spacing: 16) {
                    metricTile("CPU", "\(Int(stats.cpuPercent))%")
                    metricTile("Memory", ByteFormat.string(stats.memoryUsedBytes))
                    metricTile("PIDs", "\(stats.pids)")
                }
            }
            if container.resources.cpus > 0 {
                copyRow("CPUs", "\(container.resources.cpus)")
            }
            if container.resources.memoryBytes > 0 {
                copyRow("Memory limit", ByteFormat.string(container.resources.memoryBytes))
            }
            if container.rosetta { copyRow("Rosetta", "on") }
            if container.readOnly { copyRow("Read-only", "on") }
            if container.useInit { copyRow("Init", "on") }
            if container.ssh { copyRow("SSH forward", "on") }
            if container.virtualization { copyRow("Virtualization", "on") }
        }
    }

    private func envSection(_ container: Micropod_V1_Container) -> some View {
        section("Environment") {
            ForEach(Array(container.env.enumerated()), id: \.offset) { _, line in
                smartRow(label: "env", value: line, primaryAction: nil)
            }
        }
    }

    private func labelsSection(_ container: Micropod_V1_Container) -> some View {
        section("Labels") {
            ForEach(Array(container.labels.keys.sorted()), id: \.self) { key in
                smartRow(label: key, value: container.labels[key] ?? "", primaryAction: nil)
            }
        }
    }

    private func mountsSection(_ container: Micropod_V1_Container) -> some View {
        section("Mounts") {
            ForEach(Array(container.mounts.enumerated()), id: \.offset) { _, mount in
                let value =
                    mount.source.isEmpty
                    ? mount.type : "\(mount.source) → \(mount.destination)\(mount.readOnly ? " (ro)" : "")"
                smartRow(label: mount.destination, value: value, primaryAction: nil)
            }
        }
    }

    // MARK: - Row building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .padding(8)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// A row with a copy-to-clipboard action.
    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            copyButton(value)
        }
        .padding(.vertical, 2)
    }

    /// A row with an optional primary action (e.g. open port in browser).
    private func smartRow(label: String, value: String, primaryAction: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if let primaryAction {
                Button {
                    primaryAction()
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("Open in browser")
                .accessibilityLabel("Open in browser")
            }
            copyButton(value)
        }
        .padding(.vertical, 2)
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
        .accessibilityLabel("Copy \(value)")
    }

    private func metricTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospaced())
        }
    }

    // MARK: - Helpers

    private func stateColor(_ state: String) -> Color {
        ContainerStateStyle.color(for: state)
    }

    private func relativeCreated(_ container: Micropod_V1_Container) -> String {
        guard let date = parseDate(container.createdAt) else { return container.createdAt }
        return date.formatted(.relative(presentation: .named))
    }

    /// Smart action: open the published port in the default browser.
    private func openPort(_ container: Micropod_V1_Container, _ hostPort: UInt32) -> () -> Void {
        {
            let host = container.ipv4Address.isEmpty ? "localhost" : container.ipv4Address
            let url = URL(string: "http://\(host):\(hostPort)")!
            NSWorkspace.shared.open(url)
        }
    }
}
