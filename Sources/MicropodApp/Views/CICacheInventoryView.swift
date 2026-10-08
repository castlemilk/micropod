import MicropodCore
import SwiftUI

/// A separate, read-only inventory. It offers no cache lifecycle actions.
struct CICacheInventoryView: View {
    @Bindable var cache: CICacheStore
    var stats: Micropod_V1_StatsSnapshot? = nil
    @State private var selection = CICacheSelection()
    @State private var showAll = false
    @State private var showAllProxyReports = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            PanelCard {
                Label("CI cache activity", systemImage: "chart.bar")
                    .font(Tokens.Typography.section)
                Text("Measured dependency-proxy requests, golden-store resolution and CI image allocation.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let inventory = cache.inventory { filters(inventory) }
                telemetryBody(now: context.date)
                if let inventory = cache.inventory { runtimeIOBody(inventory, now: context.date) }
                Divider()
                Label("CI storage", systemImage: "externaldrive").font(Tokens.Typography.section)
                if let error = cache.inventoryError {
                    Text(error).foregroundStyle(Tokens.Palette.warning)
                        .font(Tokens.Typography.metadata).fixedSize(horizontal: false, vertical: true)
                }
                if let inventory = cache.inventory {
                    inventoryBody(inventory, now: context.date)
                } else {
                    Text(cache.isRefreshing ? "Reading local named-volume metadata…" : "Inventory has not been read.")
                        .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                }
            }
        }
        .onChange(of: cache.inventory?.sourceID) { _, _ in
            selection = CICacheSelection()
            showAll = false
            showAllProxyReports = false
        }
    }

    private func inventoryBody(_ inventory: CICacheInventorySnapshot, now: Date) -> some View {
        let rows = inventory.selected(selection)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            ResponsiveRow {
                Text("\(inventory.volumes.count) CI volumes · Selected runtime · \(inventory.sourceID)")
            } trailing: {
                Text(
                    inventory.isStale(at: now) || cache.inventoryError != nil
                        ? "Stale observation" : "Recent observation"
                )
                .foregroundStyle(
                    inventory.isStale(at: now) || cache.inventoryError != nil
                        ? Tokens.Palette.warning : Tokens.Palette.secondary)
            }
            .font(Tokens.Typography.metadata)
            Text("Read \(inventory.measuredAt.formatted(date: .abbreviated, time: .standard))")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            if inventory.truncated {
                Text(
                    "Partial inventory: at most 512 volumes and container references are considered. Active use is unknown."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
            } else if !inventory.referencesAvailable {
                Text("Container references unavailable. Active use is unknown.")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
            }
            Text(
                "Host allocation is per backing file. APFS clones may share extents; these values are not unique disk use or reclaimable space. Guest filesystem usage is not measured here."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Retention dry run: require 3 measured attempts, 7 days of complete history, 14 idle days and fresh mount/clone/lease protection. Current producer coverage cannot qualify a cache for pruning."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                Text(
                    inventory.volumes.isEmpty
                        ? "No CI named volumes observed in this runtime. Shared package-cache usage does not determine this inventory."
                        : "No CI named volumes match the selected project and owner."
                )
                .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                    ForEach(Array(rows.prefix(showAll ? RuntimeCICacheReader.limit : 5))) { row in
                        volumeRow(
                            row, stale: inventory.isStale(at: now) || cache.inventoryError != nil,
                            review: CICacheRetention.localReview(row, inventory: inventory, now: now))
                        Divider()
                    }
                }
                if rows.count > 5 {
                    Button(showAll ? "Show largest 5" : "Show all \(rows.count) volumes") { showAll.toggle() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func volumeRow(_ volume: CICacheVolume, stale: Bool, review: CICacheRetention.Review) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text(volume.id).font(Tokens.Typography.log).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle).help(volume.id)
            ResponsiveRow {
                Text(
                    "Project: \(volume.project.isEmpty ? "Unknown" : volume.project) · \(volume.ecosystem.isEmpty ? "Cache" : volume.ecosystem)"
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            } trailing: {
                Text(stale ? "Earlier activity: \(volume.activityLabel)" : volume.activityLabel)
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(
                        volume.activeContainers?.isEmpty == false ? Tokens.Palette.success : Tokens.Palette.secondary)
            }
            ResponsiveRow {
                Text("Virtual capacity: \(bytes(volume.capacityBytes))").help(
                    volume.capacityBytes.map { "\($0) bytes" } ?? "Unknown")
            } trailing: {
                Text("Host allocated: \(bytes(volume.allocatedBytes))").help(
                    volume.allocatedBytes.map { "\($0) bytes" } ?? "Unknown")
            }
            .font(Tokens.Typography.body).monospacedDigit()
            Text("Owner label: \(volume.owner.isEmpty ? "Unknown" : volume.owner)")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(
                "Key: \(volume.key.isEmpty ? "Unknown" : volume.key) · Scope: \(volume.scope.isEmpty ? "Unknown" : volume.scope) · Trust: \(volume.trust.isEmpty ? "Unknown" : volume.trust)"
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            DisclosureGroup(
                review.disposition == .protected
                    ? "Retain: container reference observed" : "Retention: insufficient evidence"
            ) {
                ForEach(review.reasons, id: \.self) { reason in
                    Text(reason).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "Last content hit/access, restore/save overhead and measured time saved: Unknown. No pruning action is available."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }.font(Tokens.Typography.metadata)
            Text("Backing image: \(volume.source.isEmpty ? "Unknown" : volume.source)")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(volume.source)
            if let references = volume.containerReferences, !references.isEmpty {
                Text("Container references (including stopped): \(references.joined(separator: ", "))")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func filters(_ inventory: CICacheInventorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            ResponsiveRow {
                Picker("Project", selection: $selection.project) {
                    Text("All projects").tag("")
                    ForEach(Array(Set(inventory.volumes.map(\.project).filter { !$0.isEmpty })).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .frame(maxWidth: 300)
            } trailing: {
                Picker("Owner", selection: $selection.owner) {
                    Text("All owners").tag("")
                    ForEach(Array(Set(inventory.volumes.map(\.owner).filter { !$0.isEmpty })).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .frame(maxWidth: 420)
            }

        }
    }

    private func telemetryBody(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Dependency proxy").font(Tokens.Typography.section)
            Text("Source: \(CICacheTelemetry.endpoint.absoluteString)")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let error = cache.telemetryError {
                Text(error).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !selection.owner.isEmpty || !selection.project.isEmpty {
                Text("Proxy and store reports have no project/owner identity. They are unavailable for this selection.")
                    .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
            } else if let telemetry = cache.telemetry {
                Text("Runner proxy counters · since process start").font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.secondary)
                let proxyCounters = telemetry.observations(for: selection).filter { $0.label.hasPrefix("Proxy") }
                if proxyCounters.isEmpty {
                    Text("Process-wide proxy counters: Not reported. Attempt reports are a separate source.")
                        .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                }
                ForEach(proxyCounters, id: \.label) { counterRow($0, now: now) }
                Text("Job cache reports").font(Tokens.Typography.section)
                    .foregroundStyle(Tokens.Palette.secondary)
                let measured = telemetry.proxyReports(for: selection)
                if telemetry.attempts.isEmpty {
                    Text("Job cache reports: Not reported")
                        .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                } else {
                    ForEach(Array(telemetry.attempts.reversed().prefix(showAllProxyReports ? 20 : 1))) { attempt in
                        attemptReport(attempt)
                    }
                    if telemetry.attempts.count > 1 {
                        Button(
                            showAllProxyReports
                                ? "Show newest job" : "Show all \(telemetry.attempts.count) buffered jobs"
                        ) {
                            showAllProxyReports.toggle()
                        }.controlSize(.small)
                    }
                }
                let missing = telemetry.attempts.filter { $0.report.proxy == nil }.count
                Text(
                    "\(measured.count) measured · \(missing) without proxy measurements · latest \(telemetry.attempts.count) buffered reports"
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if telemetry.attempts.contains(where: { $0.report.invalidProxy }) {
                    Text("Incomplete or invalid proxy reports remain unknown.")
                        .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                }
                Text(
                    "Completed reports have no event time or rig identity; running attempts may not have reported. Received \(telemetry.receivedAt.formatted(date: .abbreviated, time: .standard))."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else if cache.telemetryError == nil {
                Text("Attempt proxy usage: Not yet read").font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
            }
            if let telemetry = cache.telemetry {
                let observations = telemetry.observations(for: selection)
                Text("Golden/store resolution").font(Tokens.Typography.section)
                let resolutions = observations.filter { !$0.label.hasPrefix("Proxy") }
                if resolutions.isEmpty {
                    Text("Resolution outcomes: Not reported for this selection")
                        .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                }
                ForEach(resolutions, id: \.label) { counterRow($0, now: now) }
                Text(
                    "Existing/seeded/cold describe store provisioning, not compiler or package content hits. Counters reset with the runner process."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "Compiler/package hit or miss counts: Not reported · Cache-volume I/O: Not reported · Guest filesystem used: Not reported"
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attemptReport(_ attempt: CICacheAttemptReport) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("\(attempt.nodeId) · \(attempt.attemptId)")
                .font(Tokens.Typography.log).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            if let proxy = attempt.report.proxy {
                proxyReport(attempt, proxy: proxy)
            } else {
                Text(
                    "Dependency-proxy usage: Unknown\(attempt.report.invalidProxy ? " (invalid/incomplete report)" : " (not reported)")"
                )
                .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
            }
            ForEach(Array(attempt.report.stores.prefix(4).enumerated()), id: \.offset) { _, store in
                Text("\(store.ecosystem ?? "Cache") \(store.kind) · \(store.mountPath)")
                    .font(Tokens.Typography.metadata).lineLimit(2).textSelection(.enabled)
                Text("\(store.provisioning) · \(store.commitDecision)")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            }
            if attempt.report.stores.count > 4 {
                Text("\(attempt.report.stores.count - 4) additional stores reported")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            }
            if attempt.report.stores.isEmpty {
                Text(
                    attempt.report.invalidStores
                        ? "Store report invalid; mounting unknown" : "Store mounting: Not reported"
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            }
            Text(
                "Per-store volume/key attribution, tool hits/misses, exact/partial restore match and restore/save duration: Not reported. A mounted store does not establish content reuse."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, Tokens.Spacing.sm)
    }

    private func proxyReport(_ attempt: CICacheAttemptReport, proxy: CICacheProxyReport) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ResponsiveRow {
                Text("\(proxy.requests.formatted()) requests · \(proxy.localHits.formatted()) local hits")
            } trailing: {
                Text("\(proxy.upstreamFetches.formatted()) upstream artifact fetches")
            }
            ResponsiveRow {
                Text("\(proxy.upstreamMetadataFetches.formatted()) upstream metadata fetches")
            } trailing: {
                Text("\(bytes(proxy.upstreamBytes)) fetched · \(bytes(proxy.servedBytes)) served")
            }
            Text(
                "Measured for this attempt. Served bytes include fresh downloads; they are not bytes saved. Local hits include stale responses. Errors and metadata prevent inferring artifact misses from requests minus hits."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(Tokens.Typography.body).monospacedDigit()
        .padding(.vertical, Tokens.Spacing.sm)
    }

    private func counterRow(_ observation: CICacheCounterObservation, now: Date) -> some View {
        ResponsiveRow {
            Text(observation.label)
        } trailing: {
            Text("\(observation.formatted) · \(observation.freshness(at: now))").monospacedDigit()
        }
        .font(Tokens.Typography.body)
    }

    private func runtimeIOBody(_ inventory: CICacheInventorySnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Mounted-job runtime I/O").font(Tokens.Typography.section)
            Text(
                "Cumulative bytes across every device in each container. Mount references do not attribute I/O to a cache volume."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            if let stats {
                let rows = CICacheRuntimeIO.observations(inventory: inventory, selection: selection, stats: stats)
                if rows.isEmpty {
                    Text(
                        "No joined runtime I/O observation. Missing references or stats do not establish zero activity."
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                }
                ForEach(Array(rows.prefix(5))) { row in
                    ResponsiveRow {
                        Text(row.id).lineLimit(1).truncationMode(.middle)
                    } trailing: {
                        Text("Read \(bytes(row.readBytes)) · Written \(bytes(row.writeBytes))")
                            .monospacedDigit()
                    }
                    .font(Tokens.Typography.metadata)
                }
                if let date = CICacheTelemetry.date(stats.sampledAt) {
                    Text(
                        "Sampled \(date.formatted(date: .abbreviated, time: .standard))\(now.timeIntervalSince(date) > 90 || date.timeIntervalSince(now) > 5 ? " · Earlier/invalid observation" : "")"
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                } else {
                    Text("Runtime observation time unknown").font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.warning)
                }
            } else {
                Text("Runtime I/O: Not reported").font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
            }
        }
    }

    private func bytes(_ value: UInt64?) -> String {
        CICacheByteFormat.string(value)
    }
}
