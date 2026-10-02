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
            HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                WorkspaceIconTile(name: "storage", fallback: "externaldrive")
                Text(volume.id)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.middle)
                    .help(volume.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sizeSection
                    metaSection
                    mountedBySection
                    if mountedByRunning {
                        Label(String(localized: "In use by a running container"), systemImage: "lock.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Tokens.Palette.warning)
                        Text(
                            String(
                                localized:
                                    "This volume is mounted by a running container. Deleting it may cause that container to fail on next I/O."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(Tokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }

            HStack {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .background(Tokens.Palette.canvas)
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 780, minHeight: 260, idealHeight: 460, maxHeight: 760)
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
                WorkspaceBudgetMeter(
                    used: volume.sizeBytes, cap: maxSizeBytes,
                    label: "Volume size relative to the largest volume", color: Tokens.Palette.accent)
                HStack {
                    Text(ByteFormat.string(volume.sizeBytes))
                        .font(.callout.weight(.semibold).monospaced())
                    Text(String(localized: "of \(ByteFormat.string(maxSizeBytes)) (largest volume)"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
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
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(container.id)
                        Spacer()
                        Text(container.state).font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        PanelCard(title: title) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        InspectorFieldRow(label: label, value: value)
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
