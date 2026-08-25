import MicropodCore
import SwiftUI

/// Storage tab: the runtime's real on-disk footprint (measured, not
/// estimated), reclaimable-by-category, and safe one-click cleanup.
struct StorageView: View {
    @Bindable var store: AppStore

    @State private var pendingPrune: PendingPrune?

    private enum PendingPrune: Identifiable {
        case containers, imagesDangling, imagesAll, volumes
        var id: String { String(describing: self) }
        var title: String {
            switch self {
            case .containers: "Prune Stopped Containers?"
            case .imagesDangling: "Prune Dangling Images?"
            case .imagesAll: "Prune All Unused Images?"
            case .volumes: "Prune Unused Volumes?"
            }
        }
        var confirmLabel: String {
            switch self {
            case .containers: "Prune Containers"
            case .imagesDangling: "Prune Dangling Images"
            case .imagesAll: "Prune All Unused Images"
            case .volumes: "Prune Volumes"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                totalCard
                dfCard
                bucketsCard
                tipsCard
            }
            .padding(16)
        }
        .task { await store.refreshStorage() }
        .confirmationDialog(
            pendingPrune?.title ?? "",
            isPresented: Binding(
                get: { pendingPrune != nil },
                set: { if !$0 { pendingPrune = nil } })
        ) {
            Button(pendingPrune?.confirmLabel ?? "", role: .destructive) {
                guard let pendingPrune else { return }
                self.pendingPrune = nil
                Task {
                    switch pendingPrune {
                    case .containers: await store.pruneContainers()
                    case .imagesDangling: await store.pruneImages(all: false)
                    case .imagesAll: await store.pruneImages(all: true)
                    case .volumes: await store.pruneVolumes()
                    }
                    await store.refreshStorage()
                    await store.refreshDiskUsage()
                }
            }
            Button("Cancel", role: .cancel) { pendingPrune = nil }
        } message: {
            Text(pruneMessage)
        }
    }

    private var totalCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteFormat.string(UInt64(store.storageTotalBytes))) on disk")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("Runtime data under \\(store.storageRoot.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    Task {
                        await store.refreshStorage()
                        await store.refreshDiskUsage()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-measure storage")
            }
            .padding(4)
        }
    }

    /// Reclaimable per category from `container system df` + confirmed prunes.
    private var dfCard: some View {
        GroupBox("Reclaimable") {
            if let usage = store.diskUsage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Total reclaimable")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(ByteFormat.string(usage.totalReclaimableBytes))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    reclaimRow(
                        label: "Containers",
                        category: usage.containers,
                        action: { pendingPrune = .containers })
                    reclaimRow(
                        label: "Images",
                        category: usage.images,
                        action: { pendingPrune = .imagesDangling })
                    reclaimRow(
                        label: "Volumes",
                        category: usage.volumes,
                        action: { pendingPrune = .volumes })
                }
                .padding(4)
            } else {
                Text("Disk usage unavailable — run the runtime to measure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reclaimRow(
        label: String, category: Micropod_V1_DiskCategory, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 90, alignment: .leading)
            Text(ByteFormat.string(category.sizeBytes))
                .font(.caption2.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            if category.reclaimableBytes > 0 {
                Text("\(ByteFormat.string(category.reclaimableBytes)) reclaimable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("nothing reclaimable")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                action()
            } label: {
                IconLabel(title: "Prune…", icon: "prune", fallback: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// The measured bucket breakdown with size bars and copyable paths.
    private var bucketsCard: some View {
        GroupBox("Where the space goes") {
            if store.storageBuckets.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.storageBuckets) { bucket in
                        bucketRow(bucket)
                    }
                }
                .padding(4)
            }
        }
    }

    private func bucketRow(_ bucket: StorageBucket) -> some View {
        let fraction =
            store.storageTotalBytes > 0
            ? min(1.0, Double(bucket.sizeBytes) / Double(store.storageTotalBytes)) : 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(bucket.name)
                    .font(.callout.weight(.medium))
                    .frame(width: 110, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
                Text(ByteFormat.string(UInt64(bucket.sizeBytes)))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 80, alignment: .trailing)
                Text(bucket.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Button(bucket.path) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bucket.path, forType: .string)
            }
            .buttonStyle(.plain)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .help("Copy path")
        }
        .padding(.vertical, 3)
    }

    private var tipsCard: some View {
        GroupBox("macOS storage tips") {
            VStack(alignment: .leading, spacing: 6) {
                tip(
                    "Snapshots dominate: image layers and container writable layers live in `snapshots/`. `Prune All Unused Images` reclaims the most."
                )
                tip(
                    "Container VM disks live in `containers/` — deleting a container frees its full disk, not just its snapshot."
                )
                tip(
                    "Reclaimable figures come from the runtime itself (`container system df`) and are always safe to apply — unused resources only."
                )
            }
            .padding(4)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .padding(.top, 1)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pruneMessage: String {
        switch pendingPrune {
        case .containers: "Removes every stopped container and its VM disk."
        case .imagesDangling: "Removes images not referenced by any tag or container."
        case .imagesAll: "Removes every image not referenced by a running container — the snapshots are freed."
        case .volumes: "Removes volumes not referenced by any container."
        case nil: ""
        }
    }
}
