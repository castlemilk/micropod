import MicropodCore
import SwiftUI

/// Storage tab: the runtime's real on-disk footprint (measured, not
/// estimated), reclaimable-by-category, and safe one-click cleanup.
struct StorageView: View {
    @Bindable var store: AppStore

    @State private var pendingPrune: PendingPrune?
    @State private var refreshTicks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                header
                totalCard
                dfCard
                bucketsCard
                tipsCard
            }
            .padding(Tokens.Spacing.xl)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Tokens.Palette.canvas)
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

    private var header: some View {
        WorkspacePageHeader(
            title: "Storage", subtitle: "Measured runtime data and reclaimable resources.",
            icon: "storage", fallback: "internaldrive"
        ) {
            Button {
                if !reduceMotion { refreshTicks += 1 }
                Task {
                    await store.refreshStorage()
                    await store.refreshDiskUsage()
                }
            } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate.byLayer, value: refreshTicks)
                }
            }
            .help("Re-measure storage")
        }
    }

    private var totalCard: some View {
        PanelCard(title: "Runtime footprint", icon: "storage") {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.sm) {
                Text(ByteFormat.string(UInt64(store.storageTotalBytes)))
                    .font(Tokens.Typography.metric)
                Text("on disk")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
            }
            Text("Runtime data under \(store.storageRoot.path)")
                .font(Tokens.Typography.metadata)
                .foregroundStyle(Tokens.Palette.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(store.storageRoot.path)
        }
    }

    /// Reclaimable per category from `container system df` + confirmed prunes.
    private var dfCard: some View {
        PanelCard(title: "Reclaimable", icon: "cache-clean", subtitle: "Unused resources reported by the runtime.") {
            if let usage = store.diskUsage {
                VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                    ResponsiveRow {
                        Text("Total reclaimable")
                            .font(Tokens.Typography.section)
                    } trailing: {
                        Text(ByteFormat.string(usage.totalReclaimableBytes))
                            .font(Tokens.Typography.metric)
                            .foregroundStyle(Tokens.Palette.warning)
                    }
                    Divider()
                    reclaimRow(
                        label: "Containers", icon: "container", fallback: "shippingbox",
                        category: usage.containers,
                        action: { pendingPrune = .containers })
                    Divider()
                    reclaimRow(
                        label: "Images", icon: "images", fallback: "square.stack",
                        category: usage.images,
                        action: { pendingPrune = .imagesDangling })
                    Divider()
                    reclaimRow(
                        label: "Volumes", icon: "storage", fallback: "internaldrive",
                        category: usage.volumes,
                        action: { pendingPrune = .volumes })
                }
            } else {
                Text("Disk usage unavailable — run the runtime to measure.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
            }
        }
    }

    private func reclaimRow(
        label: String, icon: String, fallback: String,
        category: Micropod_V1_DiskCategory, action: @escaping () -> Void
    ) -> some View {
        ResponsiveRow {
            HStack(spacing: Tokens.Spacing.md) {
                WorkspaceIcon(name: icon, fallback: fallback)
                    .foregroundStyle(Tokens.Palette.accentText)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(label).font(Tokens.Typography.section)
                    Text("\(ByteFormat.string(category.sizeBytes)) used")
                        .font(Tokens.Typography.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Palette.secondary)
                }
            }
        } trailing: {
            HStack(spacing: Tokens.Spacing.md) {
                if category.reclaimableBytes > 0 {
                    Text("\(ByteFormat.string(category.reclaimableBytes)) reclaimable")
                        .font(Tokens.Typography.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Palette.warning)
                } else {
                    Text("Nothing reclaimable")
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.tertiary)
                }
                Button {
                    action()
                } label: {
                    IconLabel(title: "Prune…", icon: "prune", fallback: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
    }

    /// The measured bucket breakdown with size bars and copyable paths.
    private var bucketsCard: some View {
        PanelCard(
            title: "Where the space goes", icon: "storage", subtitle: "Measured directories in the runtime data folder."
        ) {
            if store.storageBuckets.isEmpty {
                HStack(spacing: Tokens.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Tokens.Spacing.md)
            } else {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                    ForEach(store.storageBuckets) { bucket in
                        bucketRow(bucket)
                    }
                }
            }
        }
    }

    private func bucketRow(_ bucket: StorageBucket) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.md) {
                Text(bucket.name)
                    .font(Tokens.Typography.section)
                    .lineLimit(1)
                    .help(bucket.name)
                    .frame(width: 100, alignment: .leading)
                WorkspaceBudgetMeter(
                    used: UInt64(bucket.sizeBytes), cap: UInt64(store.storageTotalBytes),
                    label: "\(bucket.name) share of measured runtime footprint", color: Tokens.Palette.accent)
                Text(ByteFormat.string(UInt64(bucket.sizeBytes)))
                    .font(Tokens.Typography.metadata)
                    .monospacedDigit()
                    .fixedSize()
            }
            Text(bucket.explanation)
                .font(Tokens.Typography.metadata)
                .foregroundStyle(Tokens.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(bucket.path) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bucket.path, forType: .string)
            }
            .buttonStyle(.plain)
            .font(Tokens.Typography.log)
            .foregroundStyle(Tokens.Palette.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Copy path: \(bucket.path)")
        }
        .padding(.vertical, Tokens.Spacing.xs)
    }

    private var tipsCard: some View {
        PanelCard(title: "macOS storage tips") {
            VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                tip(
                    "Image and container filesystem layers live in snapshots/. Removing unused images can reclaim their retained layers."
                )
                tip(
                    "Container VM disks live in containers/. Deleting a stopped container removes its disk data."
                )
                tip(
                    "The runtime reports unused resources with container system df. Review each cleanup before applying it."
                )
            }
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Palette.accentText)
                .padding(.top, 1)
            Text(text)
                .font(Tokens.Typography.metadata)
                .foregroundStyle(Tokens.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
