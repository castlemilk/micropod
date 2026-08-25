import MicropodCore
import SwiftUI

/// Volume detail sheet: size bar, driver/format/source, labels, and a
/// mounted-by list derived from the live container list (no extra CLI calls).
struct VolumeDetailSheet: View {
    @Bindable var store: AppStore
    let volume: Micropod_V1_Volume

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                Text(volume.id).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if mountedByRunning {
                    Label(String(localized: "in use"), systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
                .controlSize(.small)
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sizeSection
                    metaSection
                    mountedBySection
                }
                .padding(4)
            }

            if mountedByRunning {
                Text(
                    String(
                        localized:
                            "This volume is mounted by a running container. Deleting it may cause that container to fail on next I/O."
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .confirmationDialog(
            mountedByRunning ? String(localized: "Delete in-use volume?") : String(localized: "Delete volume?"),
            isPresented: $confirmDelete
        ) {
            Button(String(localized: "Delete Volume"), role: .destructive) {
                Task { await store.deleteVolume(volume.id) }
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                mountedByRunning
                    ? String(
                        localized:
                            "\(volume.id) is mounted by \(mountedByNames.count) container(s). Deleting it is irreversible."
                    )
                    : String(localized: "This cannot be undone.")
            )
        }
    }

    private var sizeSection: some View {
        section(String(localized: "Size")) {
            if volume.sizeBytes > 0 {
                let fraction = volume.sizeBytes == 0 ? 0 : Double(volume.sizeBytes) / Double(maxSizeBytes)
                ProgressView(value: fraction)
                HStack {
                    Text(ByteFormat.string(volume.sizeBytes))
                        .font(.callout.weight(.semibold).monospaced())
                    Text(String(localized: "of \(ByteFormat.string(maxSizeBytes)) (largest volume)"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                Text(String(localized: "Unknown size"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var metaSection: some View {
        section(String(localized: "Details")) {
            copyRow(String(localized: "Driver"), volume.driver.isEmpty ? "—" : volume.driver)
            copyRow(String(localized: "Format"), volume.format.isEmpty ? "—" : volume.format)
            copyRow(String(localized: "Source"), volume.source.isEmpty ? "—" : volume.source)
            if !volume.createdAt.isEmpty {
                copyRow(String(localized: "Created"), volume.createdAt)
            }
            if !volume.labels.isEmpty {
                ForEach(Array(volume.labels.keys.sorted()), id: \.self) { key in
                    copyRow(String(localized: "Label \(key)"), volume.labels[key] ?? "")
                }
            }
        }
    }

    private var mountedBySection: some View {
        section(String(localized: "Mounted by")) {
            if mountedBy.isEmpty {
                Text(String(localized: "Not mounted by any container"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(mountedBy, id: \.id) { container in
                    HStack(spacing: 6) {
                        Circle().fill(ContainerStateStyle.color(for: container.state)).frame(
                            width: 6, height: 6)
                        Text(container.id).font(.caption.monospaced())
                        Spacer()
                        Text(container.state).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Helpers

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
            Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1).textSelection(.enabled)
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

    /// Largest volume size across the store, for the relative size bar.
    private var maxSizeBytes: UInt64 {
        max(store.volumes.map(\.sizeBytes).max() ?? 0, 1)
    }

    /// Containers whose mounts reference this volume (by source path or name).
    private var mountedBy: [Micropod_V1_Container] {
        containersMounted(to: volume, in: store.containers)
    }

    private var mountedByNames: [String] {
        mountedBy.map(\.id)
    }

    private var mountedByRunning: Bool {
        mountedBy.contains { $0.state == "running" }
    }
}

/// Identifiable wrapper for presenting a volume in a sheet.
struct VolumeDetailSelection: Identifiable {
    let id: String
    let volume: Micropod_V1_Volume
    init(volume: Micropod_V1_Volume) {
        self.id = volume.id
        self.volume = volume
    }
}
