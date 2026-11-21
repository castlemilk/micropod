import Darwin
import Foundation

enum DevVolumeCommands {
    static let help = """
        micropod storage dev-volume plan|create --projects <dir> [cache options]
            [--container diskN] [--unencrypted] [--state-dir <dir>]
        micropod storage dev-volume add-caches [cache options] [--state-dir <dir>]
        Cache options: --npm-cache <dir> --go-mod-cache <dir> --go-build-cache <dir> --pnpm-store <dir>
        micropod storage dev-volume status|mount|remount|repair|migrate|restore [--state-dir <dir>]

        create provisions an encrypted APFS volume by default. macOS prompts for its passphrase.
        migrate checks for open files, verifies a copy, then swaps in a link at the original path.
        restore brings the current volume contents back, including edits made after migration.
        add-caches enrolls existing shared stores. Run migrate to move new entries.
        Each migrated directory retains an original backup next to its old path.
        """

    struct Arguments {
        let action: String
        let projects: String?
        static let cacheOptions = ["pnpm-store", "npm-cache", "go-mod-cache", "go-build-cache"]
        let cachePaths: [String: String]
        let container: String?
        let unencrypted: Bool
        let state: String

        init(_ args: [String]) throws {
            action = args.first ?? "status"
            var values: [String: String] = [:]
            var flags = Set<String>()
            var cursor = args.dropFirst().makeIterator()
            let provisioning = ["plan", "create"].contains(action)
            var allowed = ["--state-dir"]
            if provisioning { allowed += ["--projects", "--container"] }
            if provisioning || action == "add-caches" { allowed += Self.cacheOptions.map { "--" + $0 } }
            while let key = cursor.next() {
                if key == "--unencrypted", provisioning, flags.insert(key).inserted { continue }
                guard allowed.contains(key), values[key] == nil, let value = cursor.next(), !value.hasPrefix("-"),
                    !value.isEmpty
                else { throw DevVolumeError("Invalid option \(key)\n\(help)") }
                values[key] = value
            }
            projects = values["--projects"]
            cachePaths = Dictionary(
                uniqueKeysWithValues: Self.cacheOptions.compactMap { name in
                    values["--" + name].map { (name, $0) }
                })
            if action == "add-caches" && cachePaths.isEmpty { throw DevVolumeError("Supply at least one cache option") }
            container = values["--container"]
            unencrypted = flags.contains("--unencrypted")
            state = DevVolumeMigration.physical(values["--state-dir"] ?? NSHomeDirectory() + "/.micropod/dev-volume")
            if provisioning && projects == nil { throw DevVolumeError("Supply --projects <directory>\n\(help)") }
        }

        func requestedPath(_ value: String) -> String {
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
            // Resolve parent aliases such as /tmp, retaining the identity of a migrated leaf.
            return (DevVolumeMigration.physical(url.deletingLastPathComponent().path) as NSString)
                .appendingPathComponent(url.lastPathComponent)
        }

        func selectedTrees() throws -> [DevVolume.Tree] {
            guard let projects else { throw DevVolumeError("Missing projects directory") }
            let first = DevVolume.Tree(name: "projects", source: requestedPath(projects))
            try DevVolumeMigration.validateSource(first.source, state: state)
            return [first] + (try newCacheTrees(existing: [first], volume: nil))
        }

        func newCacheTrees(existing: [DevVolume.Tree], volume: DevVolume?) throws -> [DevVolume.Tree] {
            let contains = DevVolumeMigration.contains
            var candidates: [DevVolume.Tree] = []
            for name in Self.cacheOptions {
                guard let value = cachePaths[name] else { continue }
                let path = requestedPath(value)
                var source = path
                if let volume {
                    for tree in existing {
                        let destination = volume.destination(tree)
                        if contains(destination, path) {
                            source = tree.source + String(path.dropFirst(destination.count))
                        }
                    }
                    guard !contains(volume.mount, source),
                        !existing.contains(where: { contains($0.backup, source) || contains(source, $0.backup) })
                    else { throw DevVolumeError("Select the original cache path outside the volume and backups") }
                }
                if let prior = existing.first(where: { $0.name == name }), prior.source != source {
                    throw DevVolumeError("The requested \(name) differs from its recorded directory \(prior.source)")
                }
                if existing.contains(where: { $0.source == source }) { continue }
                try DevVolumeMigration.validateSource(path, state: state)
                if existing.contains(where: { contains($0.source, source) }) { continue }
                guard !existing.contains(where: { contains(source, $0.source) }) else {
                    throw DevVolumeError("The cache \(source) would enclose an already selected directory")
                }
                if !candidates.contains(where: { $0.source == source }) {
                    candidates.append(DevVolume.Tree(name: name, source: source))
                }
            }
            // Each physical directory is migrated once, including a store nested below another selected store.
            return candidates.filter { child in
                !candidates.contains { $0.source != child.source && contains($0.source, child.source) }
            }
        }
    }

    static func run(_ args: [String], json: Bool) throws {
        if args.first == "_initialize" {
            try DevVolume.initializeVolume(Array(args.dropFirst()))
            return
        }
        if let first = args.first, ["help", "--help", "-h"].contains(first) {
            print(help)
            return
        }
        let opt = try Arguments(args)
        let fm = FileManager.default
        let state = URL(fileURLWithPath: opt.state, isDirectory: true)
        let record = state.appendingPathComponent("volume.json")
        func save(_ volume: DevVolume) throws {
            try JSONEncoder().encode(volume).write(to: record, options: .atomic)
        }
        func load() throws -> DevVolume {
            guard try DevVolumeMigration.kind(record.path) == S_IFREG else {
                throw DevVolumeError("No volume record at \(record.path). Use plan or create.")
            }
            return try JSONDecoder().decode(DevVolume.self, from: Data(contentsOf: record))
        }
        func emit(_ body: [String: Any], _ lines: [String]) throws {
            if json {
                let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(lines.joined(separator: "\n"))
            }
        }
        if opt.action == "plan" {
            let trees = try opt.selectedTrees()
            let details = trees.map { "\($0.name)  \($0.source)" }
            try emit(
                [
                    "sources": trees.map(\.source), "encrypted": !opt.unencrypted, "stateDirectory": state.path,
                    "persistentFSEvents": false, "spotlightIndexing": false,
                ],
                details + [
                    "Volume encryption  \(opt.unencrypted ? "off" : "on")", "State  \(state.path)",
                    "Existing copies stay in place until migrate.",
                ])
            return
        }
        guard
            ["create", "add-caches", "status", "migrate", "restore", "remount", "mount", "repair"].contains(opt.action)
        else {
            throw DevVolumeError(help)
        }
        guard getuid() != 0 else {
            throw DevVolumeError("Run this command as your login user. create will request admin access.")
        }
        if opt.action == "status", try DevVolumeMigration.kind(record.path) == nil {
            try emit(["configured": false], ["No development volume configured."])
            return
        }
        if opt.action == "create", try DevVolumeMigration.kind(record.path) == nil { _ = try opt.selectedTrees() }
        if opt.action != "create", !fm.fileExists(atPath: state.path) {
            throw DevVolumeError("No development volume configured")
        }
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var meta = stat()
        guard lstat(state.path, &meta) == 0, meta.st_mode & S_IFMT == S_IFDIR, meta.st_uid == getuid(),
            meta.st_mode & 0o077 == 0
        else { throw DevVolumeError("Use a private user-owned state directory with mode 0700") }
        let lock = open(state.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw DevVolumeError("Cannot open the development volume lock") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw DevVolumeError("Another volume operation is in progress")
        }

        var volume: DevVolume
        if opt.action == "create", try DevVolumeMigration.kind(record.path) == nil {
            let trees = try opt.selectedTrees()
            let container = try DevVolume.container(device: opt.container)
            guard let id = (container["APFSContainerUUID"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw DevVolumeError("No APFS container UUID")
            }
            let sensitivity = try URL(fileURLWithPath: trees[0].source).resourceValues(forKeys: [
                .volumeSupportsCaseSensitiveNamesKey
            ]).volumeSupportsCaseSensitiveNames
            volume = DevVolume(
                token: UUID(), containerID: id, encrypted: !opt.unencrypted, caseSensitive: sensitivity == true,
                trees: trees)
            try save(volume)
        } else {
            volume = try load()
        }

        switch opt.action {
        case "create":
            // Validate repeat invocations even after the recorded paths became links.
            guard let projects = opt.projects, opt.requestedPath(projects) == volume.trees.first?.source,
                volume.encrypted == !opt.unencrypted
            else {
                throw DevVolumeError("The existing record describes a different development volume")
            }
            guard try opt.newCacheTrees(existing: volume.trees, volume: volume).isEmpty else {
                throw DevVolumeError("Use add-caches to enroll additional stores on the existing volume")
            }
            if let selected = opt.container {
                guard let cid = try DevVolume.container(device: selected)["APFSContainerUUID"] as? String,
                    UUID(uuidString: cid) == volume.containerID
                else { throw DevVolumeError("APFS container differs from the recorded container") }
            }
            try volume.provision()
            try save(volume)
            fallthrough
        case "repair":
            try volume.mountVolume()
            guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path, let uuid = volume.volumeID else {
                throw DevVolumeError("Missing executable or volume identity")
            }
            try DevTool.interact(
                DevTool.sudo, [exe, "storage", "dev-volume", "_initialize", uuid.uuidString, volume.token.uuidString])
            if !volume.initialized {
                try volume.mountVolume(remount: true)
                volume.initialized = true
                try save(volume)
            }
        case "add-caches":
            let additions = try opt.newCacheTrees(existing: volume.trees, volume: volume)
            if !additions.isEmpty {
                volume.trees += additions
                try save(volume)
            }
        case "mount", "remount": try volume.mountVolume(remount: opt.action == "remount")
        case "migrate", "restore":
            guard volume.initialized else { throw DevVolumeError("Volume setup is incomplete. Repeat create.") }
            _ = try volume.diskInfo(requireMount: true)
            let migrating = opt.action == "migrate"
            try DevVolumeMigration.sameDevice(volume.payload, volume.mount)
            for tree in volume.trees {
                let target = volume.destination(tree)
                if DevVolumeMigration.link(tree.source) == target {
                    try DevVolumeMigration.sameDevice(target, volume.payload)
                    guard try DevVolumeMigration.kind(tree.backup) == S_IFDIR else {
                        throw DevVolumeError("The original backup is missing at \(tree.backup)")
                    }
                } else {
                    try DevVolumeMigration.validateSource(tree.source, state: state.path)
                }
            }
            let pending = volume.trees.filter {
                let linked = DevVolumeMigration.link($0.source) == volume.destination($0)
                return migrating != linked
            }
            guard !pending.isEmpty else { break }
            try DevVolumeMigration.quiescent(
                volume.trees.map {
                    let target = volume.destination($0)
                    return DevVolumeMigration.link($0.source) == target ? target : $0.source
                })
            var links = DevVolumeMigration.FileLinks()
            for index in volume.trees.indices {
                var tree = volume.trees[index]
                if opt.action == "migrate" {
                    if try DevVolumeMigration.kind(tree.source) == S_IFDIR,
                        try DevVolumeMigration.kind(volume.destination(tree)) != nil
                    {
                        tree.generation = UUID()
                        volume.trees[index] = tree
                        try save(volume)
                    }
                    try DevVolumeMigration.migrate(tree, volume: volume, state: state.path, links: &links)
                } else {
                    try DevVolumeMigration.restore(tree, volume: volume, links: &links)
                }
            }
        default: break
        }
        if volume.volumeID == nil {
            try emit(
                ["configured": true, "initialized": false, "phase": "creation-pending"],
                ["Volume creation is pending. Repeat create with the same options."])
            return
        }
        let info = try volume.diskInfo(requireMount: false)
        let mounted = info["MountPoint"] as? String == volume.mount
        let spot = mounted ? try DevTool.capture(DevTool.mdutil, ["-s", volume.mount]) : nil
        let observed = spot.map { ($0.output + $0.error).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "offline"
        let trees: [[String: Any]] = volume.trees.map { tree in
            let target = volume.destination(tree)
            return [
                "name": tree.name, "source": tree.source, "destination": target, "backup": tree.backup,
                "linked": DevVolumeMigration.link(tree.source) == target,
            ]
        }
        try emit(
            [
                "configured": true, "initialized": volume.initialized, "volumeUUID": volume.volumeID?.uuidString ?? "",
                "mount": volume.mount, "mounted": mounted, "payload": volume.payload, "spotlight": observed,
                "persistentLogMarker": mounted && fm.fileExists(atPath: volume.mount + "/.fseventsd/no_log")
                    ? "present" : "unverified",
                "trees": trees,
            ],
            ["Development volume  \(volume.mount)  \(mounted ? "mounted" : "offline")", observed]
                + volume.trees.map {
                    "\($0.source)  \(DevVolumeMigration.link($0.source) == volume.destination($0) ? "on volume" : "original path")"
                })
    }
}
