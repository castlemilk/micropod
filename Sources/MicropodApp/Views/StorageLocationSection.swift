import AppKit
import Combine
import MicropodCore
import SwiftUI

/// Settings → Storage location: where container images, volumes, VMs and
/// sandbox data live. Drives are discovered (and re-discovered as they mount
/// and unmount); a click selects one. Moving the data is
/// `StorageLocation.apply`, the same code path as `micropod storage set`.
struct StorageLocationSection: View {
    @State private var status = StorageLocation.status()
    @State private var volumes: [StorageLocation.Volume] = []
    @State private var chosen: String = ""
    @State private var migrate = true
    @State private var working = false
    @State private var log: [String] = []
    @State private var error: String?
    @State private var confirming = false
    @State private var showAdvanced = false
    /// Bytes the move would copy, measured in the background (nil: not yet).
    @State private var dataBytes: Int64?
    @State private var measuring = false

    var body: some View {
        Section("Storage Location") {
            if status.driveDisconnected {
                banner(
                    "Storage drive \(status.volumeName ?? "") is disconnected",
                    detail: "The container runtime is stopped until it is reconnected.",
                    systemImage: "externaldrive.badge.xmark", tint: Tokens.Palette.danger)
            } else if let relinkTo = status.relinkTo {
                banner(
                    "\(status.volumeName ?? "The storage drive") is now at \(relinkTo)",
                    detail: "It was renamed or remounted. Point the data back at it to start the runtime.",
                    systemImage: "externaldrive.badge.exclamationmark", tint: Tokens.Palette.warning
                ) {
                    Button("Reconnect") { Task { await relink() } }
                        .disabled(working)
                }
            }
            ForEach(otherProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Tokens.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(volumes, id: \.mountPoint) { volume in
                    StorageDriveCard(
                        volume: volume, isCurrent: isCurrent(volume), isSelected: isSelected(volume),
                        dataBytes: dataBytes
                    ) { select(volume) }
                }
                if volumes.isEmpty {
                    Text("No drives found").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            DisclosureGroup("Choose a folder…", isExpanded: $showAdvanced) {
                HStack {
                    TextField("Folder, e.g. /Volumes/External/Micropod", text: $chosen)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    Button("Browse…") { pickFolder() }
                        .controlSize(.small)
                }
            }
            .font(.caption)

            if !chosen.isEmpty, chosen != status.configuredRoot {
                InspectorFieldRow(label: "Move to", value: chosen)
                if let warning {
                    Text(warning).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fit = fitMessage {
                    Text(fit.text).font(Tokens.Typography.metadata)
                        .foregroundStyle(fit.fits ? Tokens.Palette.secondary : Tokens.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Copy existing data (otherwise start empty)", isOn: $migrate)
            }
            StorageLocationActions(
                working: working, canMove: canMove, canReset: status.configuredRoot != nil,
                hasOldData: status.trees.contains(where: \.oldDataLeft),
                move: { confirming = true },
                reset: {
                    Task { await run { try await StorageLocation.reset(migrate: migrate, control: Self.control) } }
                }, removeOld: { removeOld() })
            ForEach(Array(log.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line).font(Tokens.Typography.log).foregroundStyle(Tokens.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let error {
                Text(error).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            refresh()
            measure()
        }
        .onReceive(Self.volumeEvents) { _ in refresh() }
        .confirmationDialog(
            "Move Micropod's data to \(chosen)?", isPresented: $confirming
        ) {
            Button("Stop the Runtime and Move") {
                let root = chosen
                let copy = migrate
                Task {
                    await run {
                        try await StorageLocation.apply(
                            root: root, migrate: copy, control: Self.control,
                            progress: { step in Task { @MainActor in log.append(Self.describe(step)) } })
                    }
                }
            }
        } message: {
            Text(
                "Running containers stop while the runtime restarts. The current data stays on the internal disk until you remove it. Keep the drive connected: without it the runtime will not start."
            )
        }
    }

    // MARK: - Derived state

    /// Problems the banners above do not already say.
    private var otherProblems: [String] {
        guard status.driveDisconnected || status.relinkTo != nil else { return status.problems }
        return status.problems.filter { !$0.hasPrefix("storage drive") }
    }

    private func isCurrent(_ volume: StorageLocation.Volume) -> Bool {
        if let uuid = status.volumeUUID { return volume.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }
        guard let root = status.configuredRoot else { return volume.kind == .internal }
        return root.hasPrefix(volume.mountPoint.standardizedFileURL.path + "/")
            || root == volume.mountPoint.standardizedFileURL.path
    }

    private func isSelected(_ volume: StorageLocation.Volume) -> Bool {
        guard !chosen.isEmpty else { return false }
        let mount = volume.mountPoint.standardizedFileURL.path
        return chosen == mount || chosen.hasPrefix(mount + "/")
    }

    private var targetVolume: StorageLocation.Volume? {
        guard !chosen.isEmpty else { return nil }
        return volumes.first { isSelected($0) } ?? StorageLocation.volume(containing: URL(fileURLWithPath: chosen))
    }

    private var canMove: Bool {
        guard !working, !chosen.isEmpty, chosen != status.configuredRoot,
            StorageLocation.validate(root: chosen).isEmpty
        else { return false }
        if migrate, let fit = fitMessage, !fit.fits { return false }
        return true
    }

    private var warning: String? {
        if let problem = StorageLocation.validate(root: chosen).first { return problem.description }
        if let vol = targetVolume, !vol.isInternal {
            return "\(vol.name) is \(vol.kind == .removable ? "removable" : "external"): keep it connected."
        }
        return nil
    }

    private var fitMessage: (text: String, fits: Bool)? {
        guard migrate, let vol = targetVolume else { return nil }
        guard let dataBytes else { return measuring ? ("Measuring the data to copy…", true) : nil }
        let needed = StorageLocation.requiredBytes(forData: dataBytes)
        let fits = needed <= vol.availableBytes
        let text =
            "About \(ByteFormat.string(dataBytes)) to copy; \(vol.name) has \(ByteFormat.string(vol.availableBytes)) free"
            + (fits ? "." : " — not enough room (headroom included).")
        return (text, fits)
    }

    // MARK: - Actions

    private func select(_ volume: StorageLocation.Volume) {
        guard volume.unusableReason == nil else { return }
        error = nil
        if volume.kind == .internal {
            // The internal disk is the default location, not a folder to move
            // into: "Back to Internal Disk" is the way back.
            chosen = ""
            return
        }
        chosen = volume.defaultFolder.path
    }

    private func refresh() {
        status = StorageLocation.status()
        volumes = StorageLocation.candidateVolumes()
        if chosen.isEmpty, let root = status.configuredRoot { chosen = root }
    }

    private func measure() {
        guard !measuring else { return }
        measuring = true
        let urls = StorageLocation.dataToMove(root: "/nonexistent-target")
        Task.detached(priority: .utility) {
            let bytes = StorageLocation.estimateBytes(of: urls)
            await MainActor.run {
                dataBytes = bytes
                measuring = false
            }
        }
    }

    private func relink() async {
        await run {
            let relinked = try StorageLocation.relink()
            if !relinked.isEmpty {
                await MainActor.run { log.append("relinked \(relinked.joined(separator: ", "))") }
                try await Self.control(true)
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
    }

    private func removeOld() {
        do {
            let removed = try StorageLocation.removeOldData()
            log.append(removed.isEmpty ? "nothing to remove" : "removed \(removed.count) old copies")
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        working = true
        error = nil
        defer {
            working = false
            refresh()
        }
        do { try await body() } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder
    private func banner(
        _ title: String, detail: String, systemImage: String, tint: Color,
        @ViewBuilder action: @escaping () -> some View = { EmptyView() }
    ) -> some View {
        ResponsiveRow(spacing: Tokens.Spacing.md) {
            HStack(alignment: .top, spacing: Tokens.Spacing.sm) {
                Image(systemName: systemImage).foregroundStyle(tint).font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(title).font(Tokens.Typography.section)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            action()
        }
        .padding(Tokens.Spacing.md)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }

    // MARK: - Shared

    /// Drives mounting, unmounting or being renamed.
    static let volumeEvents = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
        .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification))
        .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification))
        .receive(on: RunLoop.main)

    static let control: StorageLocation.SystemControl = { start in
        let client = ContainerCLIClient()
        if start {
            _ = try await client.run(ContainerCommandFactory.systemStart(), timeout: .seconds(180))
        } else {
            _ = try? await client.run(ContainerCommandFactory.systemStop(), timeout: .seconds(120))
        }
    }

    static func describe(_ step: StorageLocation.Step) -> String {
        switch step {
        case .stopRuntime: return "stopping the runtime"
        case .copy(let name, _, let to): return "copying \(name) → \(to)"
        case .moveAside(let name, _, _): return "kept old \(name) data"
        case .link(let name, _, _): return "linked \(name)"
        case .alreadyThere(let name): return "\(name) already there"
        case .startRuntime: return "starting the runtime"
        }
    }
}

/// Relocation controls keep their native button sizes and stack on narrow settings panes.
struct StorageLocationActions: View {
    let working: Bool
    let canMove: Bool
    let canReset: Bool
    let hasOldData: Bool
    let move: () -> Void
    let reset: () -> Void
    let removeOld: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Spacing.sm) { buttons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: Tokens.Spacing.sm) { buttons }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(working ? "Moving…" : "Move Data Here", action: move)
            .disabled(!canMove)
            .accessibilityIdentifier("storageLocation.move")
            .formActionBounds("storageLocation.move")
        Button("Back to Internal Disk", action: reset)
            .disabled(working || !canReset)
            .accessibilityIdentifier("storageLocation.reset")
            .formActionBounds("storageLocation.reset")
        if hasOldData {
            Button("Remove Old Data", action: removeOld)
                .disabled(working)
                .help("Deletes the copies kept on the internal disk by the last move.")
                .accessibilityIdentifier("storageLocation.removeOld")
                .formActionBounds("storageLocation.removeOld")
        }
    }
}

/// One drive in the picker: native disk distinctions with shared meters and state badges.
struct StorageDriveCard: View {
    let volume: StorageLocation.Volume
    let isCurrent: Bool
    let isSelected: Bool
    let dataBytes: Int64?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(usable ? Tokens.Palette.accentText : Tokens.Palette.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                    ResponsiveRow(spacing: Tokens.Spacing.sm) {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            Text(volume.kind == .internal ? "\(volume.name) (internal)" : volume.name)
                                .font(Tokens.Typography.section)
                                .foregroundStyle(Tokens.Palette.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(volume.formatDescription ?? volume.format)
                                .font(Tokens.Typography.metadata)
                                .foregroundStyle(Tokens.Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } trailing: {
                        HStack(spacing: Tokens.Spacing.xs) {
                            if isCurrent { WorkspaceStatusBadge(title: "Current", color: Tokens.Palette.success) }
                            if volume.kind == .external {
                                WorkspaceStatusBadge(title: "External", color: Tokens.Palette.accentText)
                            }
                            if volume.kind == .removable {
                                WorkspaceStatusBadge(title: "Removable", color: Tokens.Palette.warning)
                            }
                        }
                    }
                    WorkspaceBudgetMeter(
                        used: UInt64(max(0, volume.usedBytes)), cap: UInt64(max(0, volume.totalBytes)),
                        label: "\(volume.name) disk space used", color: pressureColor)
                    ResponsiveRow(spacing: Tokens.Spacing.sm) {
                        Text(
                            "\(ByteFormat.string(volume.availableBytes)) free of \(ByteFormat.string(volume.totalBytes))"
                        )
                        .font(Tokens.Typography.metadata).monospacedDigit()
                        .foregroundStyle(Tokens.Palette.secondary)
                    } trailing: {
                        if let reason = volume.unusableReason {
                            Text(reason).font(Tokens.Typography.metadata).foregroundStyle(Tokens.Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !isCurrent, volume.kind != .internal {
                            Text(volume.defaultFolder.path).font(Tokens.Typography.log).foregroundStyle(
                                Tokens.Palette.tertiary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(Tokens.Spacing.md)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .fill(isSelected ? Tokens.Palette.selection : Tokens.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .strokeBorder(isSelected ? Tokens.Palette.focus : Tokens.Palette.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .help(usable ? "Store Micropod's data on \(volume.name)" : (volume.unusableReason ?? ""))
        .accessibilityLabel("\(volume.name), \(ByteFormat.string(volume.availableBytes)) free")
        .accessibilityValue(
            volume.unusableReason
                ?? (isCurrent ? "Current storage location" : isSelected ? "Selected target" : volume.kind.rawValue))
    }

    private var usable: Bool { volume.unusableReason == nil }
    private var icon: String {
        switch volume.kind {
        case .internal: return "internaldrive"
        case .external: return "externaldrive"
        case .removable: return "sdcard"
        }
    }
    private var usedFraction: Double {
        volume.totalBytes > 0 ? min(1, Double(volume.usedBytes) / Double(volume.totalBytes)) : 0
    }

    private var pressureColor: Color {
        usedFraction > 0.9
            ? Tokens.Palette.danger : usedFraction > 0.75 ? Tokens.Palette.warning : Tokens.Palette.accent
    }
}
