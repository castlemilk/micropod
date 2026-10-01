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
          micropod storage volumes                local volumes it could move to (free space, format)
          micropod storage set <dir> [--migrate]  move the data under <dir> (e.g. /Volumes/Ext/micropod)
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
                try await set(root: (args[1] as NSString).expandingTildeInPath, migrate: args.contains("--migrate"))
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
                    "availableBytes": $0.availableBytes, "totalBytes": $0.totalBytes, "internal": $0.isInternal,
                    "removable": $0.isRemovable,
                ] as [String: Any]
            }
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        for v in list {
            var notes: [String] = [v.isInternal ? "internal" : "external"]
            if v.isRemovable { notes.append("removable") }
            if !v.isAPFS { notes.append("not APFS: unusable") }
            print(
                "\(v.mountPoint.path)  \(v.format)  \(gib(v.availableBytes)) free of \(gib(v.totalBytes))  (\(notes.joined(separator: ", ")))"
            )
        }
    }

    static func set(root: String, migrate: Bool) async throws {
        let problems = StorageLocation.validate(root: root)
        if let first = problems.first { throw MicropodError.message(first.description) }
        if let vol = StorageLocation.volume(containing: URL(fileURLWithPath: root)), !vol.isInternal {
            print("note: \(vol.name) is an external volume; keep it connected, or the runtime will not start")
        }
        try await StorageLocation.apply(root: root, migrate: migrate, control: systemControl) { step in
            switch step {
            case .stopRuntime: print("stopping the container runtime")
            case .copy(let name, let from, let to): print("copying \(name): \(from) → \(to)")
            case .moveAside(let name, _, let to): print("keeping old \(name) data at \(to)")
            case .link(let name, let at, let to): print("linked \(name): \(at) → \(to)")
            case .alreadyThere(let name): print("\(name) already at the location")
            case .startRuntime: print("starting the container runtime")
            }
        }
        print("done. old copies stay until `micropod storage remove-old`")
    }

    static func gib(_ bytes: Int64) -> String { String(format: "%.0f GiB", Double(bytes) / 1_073_741_824) }
}
