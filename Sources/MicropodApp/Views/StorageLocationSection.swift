import AppKit
import MicropodCore
import SwiftUI

/// Settings → Storage location: where container images, volumes, VMs and
/// sandbox data live. Moving them is `StorageLocation.apply`, the same code
/// path as `micropod storage set`.
struct StorageLocationSection: View {
    @State private var status = StorageLocation.status()
    @State private var volumes: [StorageLocation.Volume] = []
    @State private var chosen: String = ""
    @State private var migrate = true
    @State private var working = false
    @State private var log: [String] = []
    @State private var error: String?
    @State private var confirming = false

    var body: some View {
        Section("Storage Location") {
            HStack {
                Text("Data lives on")
                Spacer()
                Text(status.configuredRoot ?? "Internal disk (default)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ForEach(status.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(volumes, id: \.mountPoint) { volume in
                HStack {
                    Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                    Text(volume.name)
                    Text(volume.format).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.gib(volume.availableBytes) + " free of " + Self.gib(volume.totalBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !volume.isAPFS {
                        Text("not APFS").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                TextField("Folder, e.g. /Volumes/External/micropod", text: $chosen)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button("Choose…") { pickFolder() }
                    .controlSize(.small)
            }
            if let warning = warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Copy existing data (otherwise start empty)", isOn: $migrate)
            HStack(spacing: 8) {
                Button(working ? "Moving…" : "Move Data Here") { confirming = true }
                    .disabled(working || chosen.isEmpty || !StorageLocation.validate(root: chosen).isEmpty)
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
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Move Micropod's data to \(chosen)?", isPresented: $confirming
        ) {
            Button("Stop the Runtime and Move") {
                let root = chosen
                let copy = migrate
                Task {
                    await run {
                        try await StorageLocation.apply(root: root, migrate: copy, control: Self.control) { step in
                            Task { @MainActor in log.append(Self.describe(step)) }
                        }
                    }
                }
            }
        } message: {
            Text(
                "Running containers stop while the runtime restarts. The current data stays on the internal disk until you remove it. Keep the drive connected: without it the runtime will not start."
            )
        }
    }

    private var warning: String? {
        guard !chosen.isEmpty else { return nil }
        if let problem = StorageLocation.validate(root: chosen).first { return problem.description }
        if let vol = StorageLocation.volume(containing: URL(fileURLWithPath: chosen)), !vol.isInternal {
            return "\(vol.name) is external\(vol.isRemovable ? " and removable" : ""): keep it connected."
        }
        return nil
    }

    private func refresh() {
        status = StorageLocation.status()
        volumes = StorageLocation.candidateVolumes()
        if chosen.isEmpty, let root = status.configuredRoot { chosen = root }
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

    static func gib(_ bytes: Int64) -> String { String(format: "%.0f GiB", Double(bytes) / 1_073_741_824) }
}
