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
                    systemImage: "externaldrive.badge.xmark", tint: .red)
            } else if let relinkTo = status.relinkTo {
                banner(
                    "\(status.volumeName ?? "The storage drive") is now at \(relinkTo)",
                    detail: "It was renamed or remounted. Point the data back at it to start the runtime.",
                    systemImage: "externaldrive.badge.exclamationmark", tint: .orange
                ) {
                    Button("Reconnect") { Task { await relink() } }
                        .disabled(working)
                }
            }
            ForEach(otherProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                ForEach(volumes, id: \.mountPoint) { volume in
                    DriveCard(
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
                HStack {
                    Text("Move to").foregroundStyle(.secondary)
                    Text(chosen).font(.caption.monospaced())
                    Spacer()
                }
                .font(.caption)
                if let warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                if let fit = fitMessage {
                    Text(fit.text).font(.caption).foregroundStyle(fit.fits ? Color.secondary : Color.red)
                }
                Toggle("Copy existing data (otherwise start empty)", isOn: $migrate)
            }
            HStack(spacing: 8) {
                Button(working ? "Moving…" : "Move Data Here") { confirming = true }
                    .disabled(!canMove)
                Button("Back to Internal Disk") {
                    Task { await run { try await StorageLocation.reset(migrate: migrate, control: Self.control) } }
                }
                .disabled(working || status.configuredRoot == nil)
                if status.trees.contains(where: \.oldDataLeft) {
                    Button("Remove Old Data") { removeOld() }
                        .disabled(working)
                        .help("Deletes the copies kept on the internal disk by the last move.")
                }
            }
            .controlSize(.small)
            ForEach(Array(log.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
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
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(10)
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

/// One drive in the picker: icon, name, format, usage bar and badges.
private struct DriveCard: View {
    let volume: StorageLocation.Volume
    let isCurrent: Bool
    let isSelected: Bool
    let dataBytes: Int64?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(usable ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(volume.kind == .internal ? "\(volume.name) (internal)" : volume.name)
                            .font(.callout.weight(.medium))
                        Text(volume.formatDescription ?? volume.format)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if isCurrent { badge("Current", .green) }
                        if volume.kind == .external { badge("External", .blue) }
                        if volume.kind == .removable { badge("Removable", .orange) }
                        Spacer()
                    }
                    ProgressView(value: usedFraction)
                        .tint(usedFraction > 0.9 ? .red : usedFraction > 0.75 ? .orange : .accentColor)
                    HStack {
                        Text(
                            "\(ByteFormat.string(volume.availableBytes)) free of \(ByteFormat.string(volume.totalBytes))"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Spacer()
                        if let reason = volume.unusableReason {
                            Text(reason).font(.caption2).foregroundStyle(.orange)
                        } else if !isCurrent, volume.kind != .internal {
                            Text(volume.defaultFolder.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .opacity(usable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .help(usable ? "Store Micropod's data on \(volume.name)" : (volume.unusableReason ?? ""))
        .accessibilityLabel("\(volume.name), \(ByteFormat.string(volume.availableBytes)) free")
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

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
