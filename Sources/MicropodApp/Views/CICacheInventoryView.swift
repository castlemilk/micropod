import MicropodCore
import SwiftUI

/// A separate, read-only inventory. It offers no cache lifecycle actions.
struct CICacheInventoryView: View {
    @Bindable var cache: CICacheStore
    var stats: Micropod_V1_StatsSnapshot? = nil
    @State private var selection = CICacheSelection()
    @State private var showAll = false
    @State private var showAllProxyReports = false
    @State private var showAllCacheGroups = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                PanelCard {
                    Label("CI storage", systemImage: "externaldrive").font(Tokens.Typography.section)
                    if let error = cache.inventoryError {
                        Text(error).foregroundStyle(Tokens.Palette.warning)
                            .font(Tokens.Typography.metadata).fixedSize(horizontal: false, vertical: true)
                    }
                    if let inventory = cache.inventory {
                        filters(inventory)
                        inventoryBody(inventory, now: context.date)
                    } else if cache.inventoryError == nil {
                        Text(
                            cache.isRefreshing ? "Reading local named-volume metadata…" : "Inventory has not been read."
                        )
                        .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                    }
                }
                PanelCard {
                    Label("CI cache activity", systemImage: "chart.bar")
                        .font(Tokens.Typography.section)
                    Text("Measured dependency-proxy requests and golden-store resolution.")
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    telemetryBody(now: context.date)
                    historyBody
                    if let inventory = cache.inventory { runtimeIOBody(inventory, now: context.date) }
                }
            }
        }
        .onChange(of: cache.inventory?.sourceID) { _, _ in
            selection = CICacheSelection()
            showAll = false
            showAllProxyReports = false
            showAllCacheGroups = false
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
            if let telemetry = cache.telemetry {
                if selection.owner.isEmpty && selection.project.isEmpty {
                    Text("Runner proxy counters · since process start").font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Palette.secondary)
                    let counters = telemetry.observations(for: selection).filter { $0.label.hasPrefix("Proxy") }
                    if counters.isEmpty {
                        Text("Process-wide proxy counters: Not reported. Job reports are a separate source.")
                            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    }
                    ForEach(counters, id: \.label) { counterRow($0, now: now) }
                } else {
                    Text(
                        "Process-wide proxy counters have no project/owner attribution and are hidden for this selection."
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                }
                jobReportsBody(telemetry)
                cacheGroupsBody(telemetry)
                Text("Golden/store resolution").font(Tokens.Typography.section)
                let resolutions = telemetry.observations(for: selection).filter { !$0.label.hasPrefix("Proxy") }
                if resolutions.isEmpty {
                    Text("Resolution outcomes: Not reported for this selection")
                        .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                }
                ForEach(resolutions, id: \.label) { counterRow($0, now: now) }
                Text(
                    "Existing/seeded/cold describe store provisioning. Proxy hits measure requests; neither establishes compiler/package content hits. Process counters reset with the runner."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Received \(telemetry.receivedAt.formatted(date: .abbreviated, time: .standard)). Latest 20 job reports and 128 late saves are local, volatile windows. Restarts, missed polls and rollover leave history incomplete."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                if telemetry.invalidSaves > 0 {
                    Text("\(telemetry.invalidSaves) invalid late-save records remain unknown.")
                        .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                }
            } else if cache.telemetryError == nil {
                Text("Job cache usage: Not yet read").font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
            }
            Text(
                "Per-cache tool hits/misses, cache-volume I/O, total clone restore time, time saved and guest filesystem used: Not reported"
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var historyBody: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Divider()
            Text("Persisted producer history").font(Tokens.Typography.section)
            Text("Source: \(LocalCICacheHistoryPageReader.endpoint.absoluteString)")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let history = cache.history {
                if let error = history.error {
                    Text(error).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("History \(history.state.historyId ?? "Unknown") · consumed sequence \(history.state.after)")
                    .font(Tokens.Typography.metadata).textSelection(.enabled)
                if let summary = history.state.summary {
                    Text(
                        "Producer status \(summary.status) · sessions \(summary.sessions) · oldest sequence \(summary.oldestSequence) · last sequence \(summary.lastSequence)"
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Producer retains \(summary.retainedRecords) records / \(CICacheByteFormat.string(summary.retainedBytes)) of event payload · pending \(summary.pendingRecords) · evicted \(summary.evictedRecords) · persisted loss \(summary.lostRecords) · unpersisted loss at least \(summary.unpersistedLoss)"
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Producer retention budget: 2,048 events / 4 MiB payload; database overhead is additional. No multi-day coverage is promised."
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Producer coverage: \(summary.coverageReasons.joined(separator: ", "))")
                        .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "Observer retains \(history.state.events.count) curated records across projects · cursor and records \(history.persisted ? "persisted together" : "not confirmed persisted") · read \(time(history.state.sampledAt))"
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if history.traversalLimited {
                    Text(
                        "Read paused after four bounded pages; the next visible refresh resumes. The captured window is not fully consumed."
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !history.state.gaps.isEmpty {
                    Text("Observed coverage gaps: \(history.state.gaps.joined(separator: ", "))")
                        .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(history.retentionBlockers, id: \.self) { reason in
                    Text(reason).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                }
                cacheGroupsBody(history.telemetry, title: "Persisted cache observations", sampleKind: "persisted")
            } else {
                Text("Durable history has not been read. Older installed producers may not provide it.")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            }
            Text(
                "History belongs to the local producer; it is not a confirmed join to the selected runtime or owner. Empty pages do not establish zero use. Physical incarnation and lease protection remain unknown. No pruning action is available."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func jobReportsBody(_ telemetry: CICacheTelemetry) -> some View {
        let jobs = telemetry.jobReports(for: selection)
        let measured = jobs.filter { $0.report.proxy != nil }.count
        return VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Job cache reports").font(Tokens.Typography.section)
            if !selection.owner.isEmpty {
                Text(
                    "The inventory owner label is not a runner ID. Job attribution is unavailable for this owner selection."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            } else if jobs.isEmpty {
                Text(
                    "No attributed job reports in this window for the selection. This does not establish unused caches."
                )
                .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
            }
            ForEach(Array(jobs.prefix(showAllProxyReports ? 20 : 1))) { attempt in
                attemptReport(attempt)
            }
            if jobs.count > 1 {
                Button(showAllProxyReports ? "Show newest job" : "Show all \(jobs.count) buffered jobs") {
                    showAllProxyReports.toggle()
                }.controlSize(.small)
            }
            if !jobs.isEmpty {
                Text(
                    "\(measured) proxy measurements · \(jobs.count - measured) without proxy measurements · \(jobs.count) job reports shown by this selection"
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if jobs.contains(where: { $0.runnerId?.isEmpty != false || $0.observationTime == nil }) {
                Text(
                    "Legacy reports lack rig identity or event time. They cannot establish per-cache history; running jobs may not have reported."
                )
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cacheGroupsBody(
        _ telemetry: CICacheTelemetry, title: String = "Buffered cache observations",
        sampleKind: String = "buffered"
    ) -> some View {
        let groups = CICacheRecentActivity.observations(telemetry, selection: selection)
        let saves = telemetry.saveReports(for: selection)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text(title).font(Tokens.Typography.section)
            if groups.isEmpty {
                Text("Per-cache attribution: Not reported for this selection")
                    .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
            }
            ForEach(Array(groups.prefix(showAllCacheGroups ? 50 : 5))) { group in
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Rig \(group.id.runnerID) · Cache \(group.id.cacheID)")
                        .font(Tokens.Typography.log).lineLimit(2).textSelection(.enabled)
                    Text(
                        "Named volume: \(group.volumeNames.sorted().joined(separator: ", ").isEmpty ? "Not reported" : group.volumeNames.sorted().joined(separator: ", "))"
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    .lineLimit(2).textSelection(.enabled)
                    Text(
                        "\(group.attemptIDs.count) \(sampleKind) job observations · Existing \(group.existing) · Seeded \(group.seeded) · Cold \(group.cold)"
                    )
                    .font(Tokens.Typography.metadata).fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Measured resolution: \(CICacheDurationFormat.string(group.resolutionCost)) across \(group.resolutions.count) measurements · Save operation cost: \(CICacheDurationFormat.string(group.saveCost)) across \(group.saves.compactMap(\.save.durationMs).count) of \(group.saves.count) observed outcomes"
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Last report observation: \(time(group.lastReport)) · Last save finish: \(time(group.lastSave))"
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(group.saves.prefix(3))) { event in saveRow(event) }
                    if group.saves.count > 3 {
                        Text("\(group.saves.count - 3) additional late-save outcomes in this buffer")
                            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    }
                    Divider()
                }
            }
            if groups.count > 5 {
                Button(showAllCacheGroups ? "Show newest 5 caches" : "Show newest \(min(groups.count, 50)) caches") {
                    showAllCacheGroups.toggle()
                }.controlSize(.small)
            }
            if !telemetry.saveFeedAvailable {
                Text("Completed save measurements: Not reported by this producer")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            } else if saves.isEmpty {
                Text("No completed save observations in this selected window; absence does not establish no saves.")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            }
            Text(
                "Resolution measures lookup/provision/seed including waits; it excludes attachment, clone creation and tool execution. A measured 0 ms is below one millisecond. Save duration includes generation waiting and retries. These are costs, not measured benefit."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Identity is a logical name on a rig, not a physical incarnation. Named-volume joins need confirmation of the same rig. Last content hit/access, complete history and unique/reclaimable space remain unknown; pruning is unavailable."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveRow(_ event: CICacheSaveReport) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(
                "\(event.save.outcomeLabel) · \(CICacheDurationFormat.string(event.save.durationMs)) · \(time(event.save.finishTime))"
            )
            .font(Tokens.Typography.metadata).foregroundStyle(
                event.save.outcome == "unknown" ? Tokens.Palette.warning : Tokens.Palette.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("Job \(event.attemptId) · Clone owner \(event.save.containerId)")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary).lineLimit(2).textSelection(
                    .enabled)
            if let allocation = event.save.acknowledgedAllocation {
                Text("Acknowledged golden allocation: \(bytes(allocation)); not bytes written or reclaimable space")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func time(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        guard date.timeIntervalSinceNow <= 5 else { return "Invalid sample time" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func attemptReport(_ attempt: CICacheAttemptReport) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("\(attempt.nodeId) · \(attempt.attemptId)")
                .font(Tokens.Typography.log).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Text(
                "Run \(attempt.runId ?? "Unknown") · Project \(attempt.projectId ?? "Unknown") · Rig \(attempt.runnerId ?? "Unknown")"
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            .lineLimit(2).textSelection(.enabled)
            Text("Observed \(time(attempt.observationTime)) · Trust tier \(attempt.report.trust ?? "Unknown")")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            if let proxy = attempt.report.proxy {
                proxyReport(attempt, proxy: proxy)
            } else {
                Text(
                    "Dependency-proxy usage: Unknown\(attempt.report.invalidProxy ? " (invalid/incomplete report)" : " (not reported)")"
                )
                .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
            }
            ForEach(Array(attempt.report.stores.prefix(4).enumerated()), id: \.offset) { _, store in
                reportedStoreRow(store)
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
                "Per-store tool hits/misses, exact/partial restore match, attachment/clone restore duration and time saved: Not reported. Resolution or a mount report does not establish content reuse."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, Tokens.Spacing.sm)
    }

    private func reportedStoreRow(_ store: CICacheStoreReport) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("\(store.ecosystem ?? "Cache") \(store.kind) · \(store.mountPath)")
                .font(Tokens.Typography.metadata).lineLimit(2).textSelection(.enabled)
            Text("\(store.provisioning) · \(store.commitDecision)")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            Text(
                "Cache \(store.cacheId ?? "Unknown") · Volume \(store.volumeName ?? "Not reported") · Resolution \(CICacheDurationFormat.string(store.resolveMs))"
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
            .lineLimit(3).textSelection(.enabled)
        }
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
