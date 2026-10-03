import AppKit
import MicropodCore
import MicropodSharedFS
import SwiftUI

/// Cache telemetry stays local and comes from manifests/the owning
/// daemon. No filesystem enumeration is performed by the view.
struct CacheView: View {
    @Bindable var store: AppStore
    @State private var showCleanup = false
    @State private var expandedContext: String?

    private var cache: CacheStore { store.cacheStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                header
                if let error = cache.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.danger)
                        .textSelection(.enabled)
                }
                if let snapshot = cache.snapshot {
                    cacheSummary(snapshot)
                    buildInventory(snapshot)
                    packageInventory(snapshot)
                } else {
                    HStack(spacing: Tokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Reading local cache state…")
                            .foregroundStyle(Tokens.Palette.secondary)
                    }
                    .padding(.vertical, Tokens.Spacing.xl)
                }
            }
            .padding(Tokens.Spacing.xl)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Tokens.Palette.canvas)
        .task { await cache.refresh() }
        .sheet(
            isPresented: $showCleanup,
            onDismiss: { cache.dismissCleanupReview() },
            content: { CacheCleanupSheet(cache: cache) { showCleanup = false } })
    }

    private var header: some View {
        WorkspacePageHeader(
            title: "Cache", subtitle: "Reuse local work. Keep disk use predictable.",
            icon: "cache", fallback: "externaldrive"
        ) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Button {
                    Task { await cache.refresh(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(cache.isRefreshing || cache.isMutating)
                if let date = cache.snapshot?.measuredAt {
                    Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.tertiary)
                }
            }
        }
    }

    private func cacheSummary(_ snapshot: CacheSnapshot) -> some View {
        CacheSummaryLayout {
            summaryCards(snapshot)
        }
    }

    private func summaryCards(_ snapshot: CacheSnapshot) -> some View {
        Group {
            summaryCard(
                title: "Build contexts", icon: "cache", fallback: "externaldrive",
                value: snapshot.buildError == nil ? bytes(snapshot.buildStats.contentBytes) : "Unavailable",
                detail: "Logical retained content",
                used: snapshot.buildStats.contentBytes, cap: snapshot.buildStats.capBytes,
                color: Tokens.Palette.accent,
                footer:
                    "\(snapshot.buildStats.entries) contexts · \(snapshot.buildDisabled ? "Caching disabled" : "Automatic LRU eviction")"
            )
            if let package = snapshot.package {
                summaryCard(
                    title: "Package cache", icon: "container", fallback: "shippingbox",
                    value: bytes(package.storedBytes), detail: "Stored chunk data",
                    used: package.storedBytes, cap: package.capBytes,
                    color: Tokens.Palette.success,
                    footer: "\(package.chunkCount) chunks · \(package.activeMounts.count) active mounts")
            } else {
                PanelCard {
                    HStack(spacing: Tokens.Spacing.md) {
                        WorkspaceIconTile(name: "container", fallback: "shippingbox")
                        Text("Package cache").font(Tokens.Typography.section)
                    }
                    Text("Agent unavailable").font(Tokens.Typography.metric)
                    Text(snapshot.packageError ?? "The shared cache agent has not reported its state.")
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func summaryCard(
        title: String, icon: String, fallback: String, value: String, detail: String,
        used: UInt64, cap: UInt64, color: Color, footer: String
    ) -> some View {
        PanelCard {
            HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                WorkspaceIconTile(name: icon, color: color, fallback: fallback)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(title).font(Tokens.Typography.section)
                    Text(value).font(Tokens.Typography.metric).monospacedDigit()
                }
            }
            Text(detail).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            WorkspaceBudgetMeter(
                used: used, cap: cap, label: "\(title) configured limit",
                color: used > cap ? Tokens.Palette.warning : color)
            ResponsiveRow(spacing: Tokens.Spacing.sm) {
                Text(footer)
            } trailing: {
                Text("\(bytes(cap)) cap").monospacedDigit().fixedSize()
            }
            .font(Tokens.Typography.metadata)
            .foregroundStyle(Tokens.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func buildInventory(_ snapshot: CacheSnapshot) -> some View {
        PanelCard {
            ResponsiveRow {
                Label {
                    Text("Retained build contexts")
                } icon: {
                    WorkspaceIcon(name: "cache", size: 16, fallback: "externaldrive")
                        .foregroundStyle(Tokens.Palette.accentText)
                }
                .font(Tokens.Typography.section)
            } trailing: {
                Button("Reveal cache folder") { reveal(snapshot.buildRoot.path) }
                    .controlSize(.small)
            }
            if let error = snapshot.buildError {
                Text(error).font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.warning)
            } else if snapshot.buildEntries.isEmpty {
                Text(
                    "Your next Docker build can retain its extracted context here. Identical contexts skip extraction on later builds."
                )
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.secondary)
                .padding(.vertical, Tokens.Spacing.lg)
            } else {
                Text("\(bytes(snapshot.buildStats.sharedBytes)) of content appears in multiple contexts.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
                Text("Content reuse is measured from file digests. It does not represent physical disk savings.")
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.tertiary)
                Divider()
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.buildEntries, id: \.treeHash) { entry in
                        contextRow(entry)
                        Divider()
                    }
                }
            }
            Text(
                "The build agent protects contexts while builds use them. This inventory is read-only; cleanup and Keep controls require coordination with that agent."
            )
            .font(Tokens.Typography.metadata)
            .foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func contextRow(_ entry: BuildManifest) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Button {
                expandedContext = expandedContext == entry.treeHash ? nil : entry.treeHash
            } label: {
                HStack(spacing: Tokens.Spacing.md) {
                    Image(systemName: expandedContext == entry.treeHash ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(String(entry.treeHash.prefix(12)))
                        .font(Tokens.Typography.log)
                    Text(entry.storedAt == .distantPast ? "Legacy manifest" : "\(entry.files.count) files")
                        .foregroundStyle(Tokens.Palette.secondary)
                    Spacer()
                    Text(entry.storedAt == .distantPast ? "Content unknown" : bytes(entry.contentBytes))
                        .monospacedDigit()
                }
                .font(Tokens.Typography.body)
                .padding(.vertical, Tokens.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect context \(entry.treeHash.prefix(12)), \(entry.files.count) files")
            if expandedContext == entry.treeHash {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    ForEach(Array(entry.files.prefix(50).enumerated()), id: \.offset) { _, file in
                        HStack {
                            Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path)
                            Spacer()
                            Text(bytes(file.size)).monospacedDigit().fixedSize()
                        }
                        .font(Tokens.Typography.log)
                        .foregroundStyle(Tokens.Palette.secondary)
                    }
                    if entry.files.count > 50 {
                        Text("Showing the first 50 of \(entry.files.count) files.")
                            .font(Tokens.Typography.metadata)
                    }
                    Text("Tree hash: \(entry.treeHash)")
                        .font(Tokens.Typography.log)
                        .textSelection(.enabled)
                }
                .padding(.leading, Tokens.Spacing.xl)
                .padding(.bottom, Tokens.Spacing.md)
            }
        }
    }

    private func packageInventory(_ snapshot: CacheSnapshot) -> some View {
        Group {
            if let package = snapshot.package {
                PanelCard {
                    ResponsiveRow {
                        Label {
                            Text("Package cache retention")
                        } icon: {
                            WorkspaceIcon(name: "cache-pin", size: 16, fallback: "pin")
                                .foregroundStyle(Tokens.Palette.accentText)
                        }
                        .font(Tokens.Typography.section)
                    } trailing: {
                        Button {
                            showCleanup = true
                            Task { await cache.reviewCleanup() }
                        } label: {
                            Label {
                                Text("Review cleanup…")
                            } icon: {
                                WorkspaceIcon(name: "cache-clean", size: 16, fallback: "trash")
                            }
                        }
                        .disabled(cache.isMutating)
                    }
                    Toggle(
                        "Keep package cache",
                        isOn: Binding(
                            get: { cache.snapshot?.package?.keepEnabled ?? false },
                            set: { enabled in Task { await cache.setKeepEnabled(enabled) } })
                    )
                    .toggleStyle(.switch)
                    .disabled(cache.isMutating)
                    Text(
                        package.keepEnabled
                            ? "All current and future package chunks are kept locally. Automatic eviction is paused while this is enabled."
                            : "Unused package chunks are evicted in order of last use when the configured cap is exceeded."
                    )
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
                    if let warning = package.retentionWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(Tokens.Typography.metadata)
                            .foregroundStyle(Tokens.Palette.warning)
                    }
                    if package.overCap {
                        Label(
                            package.keepEnabled
                                ? "Kept package data exceeds the configured cap. Disable Keep to resume automatic eviction."
                                : "Package data is above the cap. Active data remains protected while eviction catches up.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.warning)
                    }
                    Divider()
                    Text("\(package.activeMounts.count) active cache mounts")
                        .font(Tokens.Typography.section)
                    if package.activeMounts.isEmpty {
                        Text("No active cache mounts are reported by the agent.")
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.secondary)
                    } else {
                        ForEach(package.activeMounts, id: \.id) { mount in
                            HStack(spacing: Tokens.Spacing.sm) {
                                Image(systemName: "lock.fill").foregroundStyle(Tokens.Palette.accent)
                                Text(mount.src)
                                    .font(Tokens.Typography.log)
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(mount.src)
                                Spacer()
                                WorkspaceStatusBadge(title: "In use", color: Tokens.Palette.success, compact: true)
                            }
                            .padding(.vertical, Tokens.Spacing.xs)
                        }
                    }
                    if let result = cache.lastCleanup {
                        Label(
                            "Removed \(result.chunksRemoved) chunks · \(bytes(result.bytesReclaimed)) of stored data",
                            systemImage: "checkmark.circle"
                        )
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.success)
                    }
                    ResponsiveRow {
                        Text("The agent's configured cap is \(bytes(package.capBytes)).")
                            .font(Tokens.Typography.metadata)
                            .foregroundStyle(Tokens.Palette.tertiary)
                    } trailing: {
                        Button("Reveal cache folder") { reveal(package.cacheRoot) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func bytes(_ value: UInt64) -> String { ByteFormat.string(value) }
    private func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

/// A scrolling review with a stable action row, even in a short attached sheet.
struct CacheCleanupSheet: View {
    let cache: CacheStore
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Review package cache cleanup")
                .font(Tokens.Typography.pageTitle)
                .padding(Tokens.Spacing.xl)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                    if cache.isMutating {
                        ProgressView("Checking retained chunks…")
                    } else if let review = cache.cleanupReview {
                        if let reason = review.blockedReason {
                            Label(reason, systemImage: "lock.fill")
                                .foregroundStyle(Tokens.Palette.warning)
                        } else {
                            Text(
                                "Remove \(review.chunkCount) unused chunks containing \(bytes(review.storedBytes)) of stored data?"
                            )
                            Text(
                                "Packages will be downloaded again when needed. The agent checks for active mounts and retained data again before removing the reviewed chunks. Newer chunks are excluded."
                            )
                            .foregroundStyle(Tokens.Palette.secondary)
                            Text("The actual physical space freed can differ on APFS.")
                                .font(Tokens.Typography.metadata)
                                .foregroundStyle(Tokens.Palette.tertiary)
                        }
                        Text("\(review.protectedChunkCount) chunks protected")
                            .font(Tokens.Typography.metadata)
                            .foregroundStyle(Tokens.Palette.secondary)
                    } else {
                        Text(cache.error ?? "No cleanup review is available.")
                            .foregroundStyle(Tokens.Palette.secondary)
                    }
                }
                .font(Tokens.Typography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Spacing.xl)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                if let review = cache.cleanupReview, review.blockedReason == nil, review.chunkCount > 0 {
                    Button("Remove reviewed chunks", role: .destructive) {
                        Task {
                            await cache.cleanReviewedCache()
                            onDismiss()
                        }
                    }
                    .disabled(cache.isMutating)
                }
            }
            .padding(Tokens.Spacing.lg)
        }
        .frame(minWidth: 360, idealWidth: 520, maxWidth: 640, minHeight: 280, idealHeight: 360, maxHeight: 540)
        .background(Tokens.Palette.surface)
    }

    private func bytes(_ value: UInt64) -> String { ByteFormat.string(value) }
}

/// One or two equally sized cards. Width comes from the parent proposal;
/// layout never feeds its own measured content back into view state.
struct CacheSummaryLayout: Layout {
    private let spacing: CGFloat = Tokens.Spacing.lg

    private func columnCount(width: CGFloat, count: Int) -> Int {
        min(count, width >= 576 ? 2 : 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 576
        let columns = columnCount(width: width, count: subviews.count)
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        var height: CGFloat = 0
        for index in stride(from: 0, to: heights.count, by: columns) {
            height += heights[index..<min(index + columns, heights.count)].max() ?? 0
            if index > 0 { height += spacing }
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let columns = columnCount(width: bounds.width, count: subviews.count)
        let width = max(0, (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var y = bounds.minY
        for index in stride(from: 0, to: subviews.count, by: columns) {
            let row = index..<min(index + columns, subviews.count)
            let height =
                row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
            for item in row {
                subviews[item].place(
                    at: CGPoint(x: bounds.minX + CGFloat(item - index) * (width + spacing), y: y),
                    anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + spacing
        }
    }
}
