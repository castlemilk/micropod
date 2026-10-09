import MicropodCore
import SwiftUI

/// The tray shows separate storage and activity observations, never a sum of
/// clone-backed file allocations or a capacity-as-usage budget.
struct MenuBarCacheView: View {
    @Bindable var cache: CacheStore
    @Bindable var ci: CICacheStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let summary = MenuBarCacheSummary(cache: cache, ci: ci, now: context.date)
            VStack(alignment: .leading, spacing: 5) {
                row("CI volumes · \(summary.source)", summary.volumeCount)
                    .help(
                        "Named CI volumes in the selected runtime backend. Open Cache for project, owner and backing paths."
                    )
                row("Largest file allocation", summary.allocation)
                    .help(
                        "Largest reported host allocation among observed CI backing files. Missing samples or a partial inventory can hide a larger file. APFS clones may share extents; this is neither guest use nor unique or reclaimable disk space."
                    )
                row("Host requests · local / upstream", summary.requests)
                    .help(
                        "Measured dependency-proxy requests on this host. Local means served by the proxy cache; upstream means fetched upstream. These counters are not attributed to the selected runtime, rig or owner."
                    )
                Text(summary.status)
                    .font(.system(size: 10)).foregroundStyle(
                        summary.hasWarning ? Tokens.Palette.warning : Tokens.Palette.tertiary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                row("Build contexts", summary.build)
                    .help(
                        "Logical retained build-context bytes and their configured cap; separate from CI volume storage."
                    )
                row("SharedFS packages", summary.packages)
                    .help(
                        "SharedFS chunk storage and its configured cap. Zero here does not mean CI volumes or the host dependency proxy are unused."
                    )
                Text("Guest use, reclaimable space and benefit unknown")
                    .font(.system(size: 10)).foregroundStyle(Tokens.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Tokens.Typography.metadata)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Tokens.Palette.secondary).lineLimit(1)
            Spacer(minLength: 2)
            Text(value).monospacedDigit().foregroundStyle(Tokens.Palette.primary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MenuBarCacheSummary {
    let source: String
    let volumeCount: String
    let allocation: String
    let requests: String
    let status: String
    let hasWarning: Bool
    let build: String
    let packages: String

    @MainActor init(cache: CacheStore, ci: CICacheStore, now: Date) {
        source = ci.inventory?.sourceID ?? "selected runtime"
        let stale = ci.inventory.map { $0.isStale(at: now) } == true || ci.inventoryError != nil
        if let inventory = ci.inventory {
            volumeCount = "\(inventory.volumes.count)\(inventory.truncated ? " · partial" : "")"
            if inventory.volumes.isEmpty {
                allocation = inventory.truncated ? "Unknown" : "None observed"
            } else {
                allocation = CICacheByteFormat.string(inventory.volumes.compactMap(\.allocatedBytes).max())
            }
        } else {
            volumeCount = ci.inventoryError == nil ? "Not measured" : "Unavailable"
            allocation = "Unknown"
        }
        let observations = ci.telemetry?.observations(for: CICacheSelection()) ?? []
        let local = observations.first { $0.label == "Proxy local requests" }
        let upstream = observations.first { $0.label == "Proxy upstream requests" }
        requests = "\(local?.formatted ?? "Unknown") / \(upstream?.formatted ?? "Unknown")"
        let proxyRecent = [local, upstream].allSatisfy { $0?.freshness(at: now) == "Recent sample" }
        let inventoryStatus: String
        if ci.inventoryError != nil {
            inventoryStatus = ci.inventory == nil ? "CI unavailable" : "CI unavailable · retained"
        } else if ci.inventory == nil {
            inventoryStatus = "CI not measured"
        } else {
            inventoryStatus = stale ? "CI stale" : "CI recent"
        }
        let proxyStatus: String
        if ci.telemetryError != nil {
            proxyStatus = ci.telemetry == nil ? "proxy unavailable" : "proxy unavailable · retained"
        } else if local == nil || upstream == nil {
            proxyStatus = "proxy counters unknown"
        } else {
            proxyStatus = proxyRecent ? "proxy recent" : "proxy stale/time unknown"
        }
        let localStatus: String
        if let snapshot = cache.snapshot {
            let dates = [snapshot.measuredAt] + (snapshot.package.map { [$0.measuredAt] } ?? [])
            let ages = dates.map { now.timeIntervalSince($0) }
            if ages.contains(where: { !$0.isFinite }) {
                localStatus = "local time unknown"
            } else if ages.contains(where: { $0 < -5 }) {
                localStatus = "local time invalid"
            } else if ages.contains(where: { $0 > 90 }) {
                localStatus = "local stale"
            } else if snapshot.buildError != nil || snapshot.package == nil {
                localStatus = "local partial"
            } else {
                localStatus = "local recent"
            }
        } else {
            localStatus = "local not measured"
        }
        status =
            "\(ci.isRefreshing || cache.isRefreshing ? "Refreshing… · " : "")\(inventoryStatus) · \(proxyStatus) · \(localStatus)"
        hasWarning =
            stale || ci.telemetryError != nil || (ci.telemetry != nil && !proxyRecent)
            || (localStatus != "local recent" && localStatus != "local not measured")
        if let snapshot = cache.snapshot {
            build =
                snapshot.buildError == nil
                ? "\(ByteFormat.string(snapshot.buildStats.contentBytes)) / \(ByteFormat.string(snapshot.buildStats.capBytes))"
                : "Unavailable"
            packages =
                snapshot.package.map {
                    "\(CICacheByteFormat.string($0.storedBytes)) / \(ByteFormat.string($0.capBytes))"
                } ?? "Unavailable"
        } else {
            build = "Not measured"
            packages = "Not measured"
        }
    }
}
