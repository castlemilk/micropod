import MicropodCore
import SwiftUI

/// Volumes tab: list + create/delete/prune.
struct VolumesView: View {
    @Bindable var store: AppStore

    @State private var showCreateSheet = false
    @State private var confirmPrune = false
    @State private var confirmDelete: String?
    @State private var detail: VolumeDetailSelection?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.volumes.count) volumes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            if store.volumes.isEmpty {
                EmptyStateView(
                    title: String(localized: "No Volumes"),
                    description: String(localized: "Named volumes persist data between container runs."),
                    imageName: EmptyStateArtwork.volumes,
                    symbol: "externaldrive",
                    actionTitle: String(localized: "Create volume"),
                    action: { showCreateSheet = true })
            } else {
                List {
                    ForEach(store.volumes) { volume in
                        VolumeRowView(volume: volume)
                            .contextMenu {
                                Button {
                                    detail = VolumeDetailSelection(volume: volume)
                                } label: {
                                    MenuItemIconLabel(title: "Details…", icon: "details", fallback: "info.circle")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    confirmDelete = volume.id
                                } label: {
                                    MenuItemIconLabel(title: "Delete", icon: "delete", fallback: "trash")
                                }
                            }
                            .onTapGesture(count: 2) {
                                detail = VolumeDetailSelection(volume: volume)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            if store.volumes.isEmpty { await store.refreshVolumes() }
        }
        .confirmationDialog(
            "Prune Unused Volumes?",
            isPresented: $confirmPrune
        ) {
            Button("Prune", role: .destructive) {
                Task { await store.pruneVolumes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes volumes not referenced by any container. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete volume?",
            isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { name in
            Button("Delete", role: .destructive) {
                Task { await store.deleteVolume(name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeSheet(store: store)
        }
        .sheet(item: $detail) { selection in
            VolumeDetailSheet(store: store, volume: selection.volume)
        }
    }
}

struct VolumeRowView: View, @MainActor Equatable {
    let volume: Micropod_V1_Volume

    static func == (lhs: VolumeRowView, rhs: VolumeRowView) -> Bool {
        lhs.volume == rhs.volume
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.id).font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    if !volume.driver.isEmpty {
                        Text(volume.driver).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !volume.format.isEmpty {
                        Text(volume.format).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if volume.sizeBytes > 0 {
                    Text(ByteFormat.string(volume.sizeBytes))
                        .font(.caption.monospacedDigit())
                }
                Text(volume.createdAt).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CreateVolumeSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var size = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Volume").font(.title3.weight(.semibold))
            TextField("Volume name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Size (optional, e.g. 2G)", text: $size).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await store.createVolume(name: name, size: size.isEmpty ? nil : size) }
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
