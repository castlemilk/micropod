import MicropodCore
import SwiftUI

/// A separate, read-only inventory. It offers no cache lifecycle actions.
struct CICacheInventoryView: View {
    @Bindable var cache: CICacheStore
    @State private var selection = CICacheSelection()
    @State private var showAll = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            PanelCard {
                Label("CI named volumes", systemImage: "externaldrive")
                    .font(Tokens.Typography.section)
                Text("Cuttlefish ext4 caches are separate from build contexts and shared package chunks.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Divider()
                telemetryBody(now: context.date)
            }
        }
        .onChange(of: cache.inventory?.sourceID) { _, _ in
            selection = CICacheSelection()
            showAll = false
        }
    }

    private func inventoryBody(_ inventory: CICacheInventorySnapshot, now: Date) -> some View {
        let rows = inventory.selected(selection)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            ResponsiveRow {
                Text("\(inventory.volumes.count) CI volumes · Local Apple runtime · \(inventory.sourceID)")
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
            Text(
                "Host allocation is per backing file. APFS clones may share extents; these values are not unique disk use or reclaimable space. Guest filesystem usage is not measured here."
            )
            .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
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
                        volumeRow(row, stale: inventory.isStale(at: now) || cache.inventoryError != nil)
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

    private func volumeRow(_ volume: CICacheVolume, stale: Bool) -> some View {
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
            Text("Backing image: \(volume.source.isEmpty ? "Unknown" : volume.source)")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(volume.source)
            if let active = volume.activeContainers, !active.isEmpty {
                Text("Containers: \(active.joined(separator: ", "))")
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func telemetryBody(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Local runner hit counters").font(Tokens.Typography.section)
            Text("Source: \(CICacheTelemetry.endpoint.absoluteString) · Since process start")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Rig identity and volume-level attribution are not supplied by this endpoint.")
                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !selection.owner.isEmpty {
                Text("Counters cannot be attributed to the selected owner.")
                    .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
            } else {
                if let error = cache.telemetryError {
                    Text(error).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let telemetry = cache.telemetry {
                    let observations = telemetry.observations(for: selection)
                    if observations.isEmpty {
                        Text(
                            "No applicable hit counters reported. Missing telemetry does not establish an unused cache."
                        )
                        .font(Tokens.Typography.body).foregroundStyle(Tokens.Palette.secondary)
                    }
                    ForEach(observations, id: \.label) { observation in
                        ResponsiveRow {
                            Text(observation.label)
                        } trailing: {
                            Text(
                                "\(observation.hits.formatted(.number.precision(.fractionLength(0)))) hits · \(observation.freshness(at: now))"
                            )
                            .monospacedDigit()
                        }
                        .font(Tokens.Typography.body)
                        if let date = observation.capturedAt {
                            Text("Sampled \(date.formatted(date: .abbreviated, time: .standard))")
                                .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                        }
                    }
                    Text("Received \(telemetry.receivedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                } else if cache.telemetryError == nil {
                    Text("Counters have not been read.").font(Tokens.Typography.body).foregroundStyle(
                        Tokens.Palette.secondary)
                }
                if !selection.project.isEmpty {
                    Text(
                        "Only volume counters labelled for \(selection.project) are shown. Process-wide store and proxy counters are excluded."
                    )
                    .font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bytes(_ value: UInt64?) -> String {
        CICacheByteFormat.string(value)
    }
}
