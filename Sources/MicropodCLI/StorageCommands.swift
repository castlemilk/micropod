import Foundation
import MicropodCore

/// `micropod storage` — where container images, volumes, VMs and sandbox
/// data live, and moving them to another volume (an external drive).
/// Dispatched before `Services` resolution: it stops and starts the runtime
/// itself.
enum StorageCommands {
    static let helpText = """
        micropod storage — where Micropod's runtime data lives

        Usage:
          micropod storage [show]                 where the data is, per tree, and its volume
          micropod storage volumes                drives it could move to (kind, format, free space)
          micropod storage set <target> [--migrate]
                                                  move the data to <target>: a folder
                                                  (/Volumes/Ext/micropod), or a drive's name or
                                                  UUID (its Micropod folder)
          micropod storage relink                 re-point the data at its drive after the
                                                  drive was renamed or remounted elsewhere
          micropod storage reset [--migrate]      back to the internal disk
          micropod storage remove-old             delete the copies a move left behind

        `set` stops the container runtime, copies the current data across
        with --migrate (or starts empty without it), links the default paths
        to <dir>, and starts the runtime again. Running containers stop. The
        old data is kept as <path>.pre-relocate until `remove-old`.

        Everything that starts the runtime — this app, `container system
        start`, the Cuttlefish agent's repair — follows the links, so the
        setting needs no other configuration. Keep the drive connected: with
        it gone, the runtime does not start and `storage show` says why.
        """

    static func main(_ args: [String], json: Bool) async -> Int32 {
        do {
            switch args.first ?? "show" {
            case "show", "status":
                return show(json: json)
            case "volumes":
                volumes(json: json)
            case "set":
                guard args.count >= 2, !args[1].hasPrefix("-") else {
                    print(helpText)
                    return 2
                }
                let volumes = StorageLocation.candidateVolumes()
                guard let root = StorageLocation.resolveTarget(args[1], volumes: volumes) else {
                    throw MicropodError.message(
                        "no drive named or with UUID \"\(args[1])\" is mounted (see `micropod storage volumes`)")
                }
                try await set(root: root, migrate: args.contains("--migrate"))
            case "relink":
                let relinked = try StorageLocation.relink()
                if relinked.isEmpty {
                    print("nothing to relink")
                } else {
                    print("relinked \(relinked.joined(separator: ", ")); starting the runtime")
                    try await systemControl(true)
                }
            case "reset":
                try await StorageLocation.reset(migrate: args.contains("--migrate"), control: systemControl)
                print("data is back on the internal disk")
            case "remove-old":
                let removed = try StorageLocation.removeOldData()
                print(removed.isEmpty ? "nothing to remove" : removed.map { "removed \($0)" }.joined(separator: "\n"))
            case "help", "--help", "-h":
                print(helpText)
            default:
                print(helpText)
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static let systemControl: StorageLocation.SystemControl = { start in
        let client = ContainerCLIClient()
        if start {
            _ = try await client.run(ContainerCommandFactory.systemStart(), timeout: .seconds(180))
        } else {
            // Already stopped is fine.
            _ = try? await client.run(ContainerCommandFactory.systemStop(), timeout: .seconds(120))
        }
    }

    static func show(json: Bool) -> Int32 {
        let status = StorageLocation.status()
        if json {
            let body: [String: Any] = [
                "configuredRoot": status.configuredRoot as Any,
                "healthy": status.healthy,
                "problems": status.problems,
                "trees": status.trees.map {
                    [
                        "name": $0.name, "defaultPath": $0.defaultPath, "location": $0.location, "moved": $0.moved,
                        "missing": $0.missing, "oldDataLeft": $0.oldDataLeft,
                    ] as [String: Any]
                },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return status.healthy ? 0 : 1
        }
        print("location: \(status.configuredRoot ?? "internal disk (default)")")
        for tree in status.trees {
            let mark = tree.missing ? "MISSING" : tree.moved ? "moved" : "default"
            let old = tree.oldDataLeft ? "  (old copy kept: remove-old)" : ""
            print(
                "  \(tree.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(mark.padding(toLength: 8, withPad: " ", startingAt: 0)) \(tree.location)\(old)"
            )
        }
        if let root = status.configuredRoot, let vol = StorageLocation.volume(containing: URL(fileURLWithPath: root)) {
            print("volume:   \(vol.name) (\(vol.format)) \(gib(vol.availableBytes)) free of \(gib(vol.totalBytes))")
        }
        for problem in status.problems { print("problem:  \(problem)") }
        return status.healthy ? 0 : 1
    }

    static func volumes(json: Bool) {
        let list = StorageLocation.candidateVolumes()
        if json {
            let body = list.map {
                [
                    "mountPoint": $0.mountPoint.path, "name": $0.name, "format": $0.format,
                    "formatDescription": $0.formatDescription ?? $0.format, "uuid": $0.uuid as Any,
                    "kind": $0.kind.rawValue, "availableBytes": $0.availableBytes, "totalBytes": $0.totalBytes,
                    "internal": $0.isInternal, "removable": $0.isRemovable, "usable": $0.unusableReason == nil,
                    "folder": $0.defaultFolder.path,
                ] as [String: Any]
            }
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let current = StorageLocation.status().volumeUUID
        for v in list {
            var notes: [String] = [v.kind.rawValue]
            if let current, v.uuid == current { notes.append("current") }
            if let reason = v.unusableReason { notes.append(reason) }
            print(
                "\(v.name)  \(v.mountPoint.path)  \(v.formatDescription ?? v.format)  \(gib(v.availableBytes)) free of \(gib(v.totalBytes))  (\(notes.joined(separator: ", ")))"
            )
            if let uuid = v.uuid { print("    uuid \(uuid)") }
        }
    }

    static func set(root: String, migrate: Bool) async throws {
        let problems = StorageLocation.validate(root: root)
        if let first = problems.first { throw MicropodError.message(first.description) }
        if let vol = StorageLocation.volume(containing: URL(fileURLWithPath: root)), !vol.isInternal {
            print("note: \(vol.name) is an external volume; keep it connected, or the runtime will not start")
        }
        if migrate { print("measuring the data to copy…") }
        let progress: @Sendable (StorageLocation.Step) -> Void = { step in
            switch step {
            case .stopRuntime: print("stopping the container runtime")
            case .copy(let name, let from, let to): print("copying \(name): \(from) → \(to)")
            case .moveAside(let name, _, let to): print("keeping old \(name) data at \(to)")
            case .link(let name, let at, let to): print("linked \(name): \(at) → \(to)")
            case .alreadyThere(let name): print("\(name) already at the location")
            case .startRuntime: print("starting the container runtime")
            }
        }
        try await StorageLocation.apply(root: root, migrate: migrate, control: systemControl, progress: progress)
        print("done. old copies stay until `micropod storage remove-old`")
    }

    static func gib(_ bytes: Int64) -> String { String(format: "%.0f GiB", Double(bytes) / 1_073_741_824) }
}
