import Darwin
import Foundation

/// Where Micropod's bulky runtime data lives, and moving it to another
/// volume (an external drive on a rig whose internal disk is full).
///
/// Two trees hold the bulk:
/// - Apple `container`'s app root, `~/Library/Application Support/com.apple.container`:
///   images, container root filesystems, volumes, the k8s VM.
/// - Micropod's own data under `~/.micropod`: sandbox rootfs cache and
///   clones, checkpoints, the native k8s VM, build contexts.
///
/// A moved tree is reached through a **symlink at its default path**. That is
/// deliberate: `container system start` (1.5.0, `SystemStart.swift`) defaults
/// `--app-root` to `ApplicationRoot.defaultPath` and ignores
/// `CONTAINER_APP_ROOT`, so a setting would be lost by every plain start —
/// the app's own, a script's, the Cuttlefish agent's runtime repair. Through
/// a symlink every one of them lands on the configured volume, and Micropod's
/// own paths (which are built from `~/.micropod/…`) need no change either.
/// Each micropod tree moves whole, so the sandbox engine's APFS `clonefile`
/// keeps source and clone on one volume.
///
/// A missing volume is never papered over: the symlink dangles, the runtime
/// cannot start, and `health()` names the volume to mount.
public enum StorageLocation {
    /// `~/.micropod` subdirectories that move with the setting: the large,
    /// regenerable data. Sockets, config and the API daemon's binaries stay
    /// on the internal disk.
    public static let movedMicropodDirectories = ["sandbox", "native", "k8s", "builds", "backup", "loads"]

    /// Suffix of a tree moved aside by a relocation, kept until the user
    /// removes it (`removeOldData`).
    public static let oldDataSuffix = ".pre-relocate"

    public struct Paths: Sendable, Equatable {
        public var home: URL
        public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) { self.home = home }
        public var containerAppRoot: URL {
            home.appendingPathComponent("Library/Application Support/com.apple.container")
        }
        public var micropodHome: URL { home.appendingPathComponent(".micropod") }
        public var configFile: URL { micropodHome.appendingPathComponent("storage.json") }

        /// (default location, location under `root`) for every moved tree.
        public func trees(under root: URL) -> [(name: String, source: URL, target: URL)] {
            [("container", containerAppRoot, root.appendingPathComponent("container"))]
                + StorageLocation.movedMicropodDirectories.map {
                    ($0, micropodHome.appendingPathComponent($0), root.appendingPathComponent("micropod/\($0)"))
                }
        }
    }

    public struct Config: Codable, Sendable, Equatable {
        /// Absolute directory the data lives under; nil = the internal disk.
        public var root: String?
        /// The volume `root` is on, by UUID, and `root` relative to its mount
        /// point: a drive renamed or remounted at another `/Volumes/<name>`
        /// is still recognised (and relinked), and a disconnected one is
        /// named. Nil on the internal disk and in configs from before 0.11.10.
        public var volumeUUID: String?
        public var volumeName: String?
        public var relativePath: String?
        public init(root: String?, volumeUUID: String? = nil, volumeName: String? = nil, relativePath: String? = nil) {
            self.root = root
            self.volumeUUID = volumeUUID
            self.volumeName = volumeName
            self.relativePath = relativePath
        }

        /// A config for `root` on `volume` (nil: no volume identity).
        public static func at(_ root: URL, on volume: Volume?) -> Config {
            guard let volume, let uuid = volume.uuid, !volume.isInternal else { return Config(root: root.path) }
            let mount = volume.mountPoint.standardizedFileURL.path
            var relative = String(root.path.dropFirst(mount.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            return Config(root: root.path, volumeUUID: uuid, volumeName: volume.name, relativePath: relative)
        }

        /// Where the data lives now: the configured volume's current mount
        /// point plus the relative path, when that volume is among `mounted`;
        /// otherwise the recorded root.
        public func resolvedRoot(mounted: [Volume]) -> String? {
            guard let uuid = volumeUUID, let relativePath,
                let volume = mounted.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame })
            else { return root }
            return relativePath.isEmpty
                ? volume.mountPoint.standardizedFileURL.path
                : volume.mountPoint.appendingPathComponent(relativePath).standardizedFileURL.path
        }
    }

    public static func loadConfig(_ paths: Paths = Paths()) -> Config {
        guard let data = try? Data(contentsOf: paths.configFile),
            let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config(root: nil) }
        return config
    }

    static func saveConfig(_ config: Config, _ paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.micropodHome, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: paths.configFile, options: .atomic)
    }

    // MARK: - Volumes

    public struct Volume: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable, Codable {
            /// The Mac's own disk (the volume holding the home directory).
            case `internal`
            /// A fixed external drive: Thunderbolt/USB SSD or HDD.
            case external
            /// Removable media: SD cards and the like.
            case removable
        }

        public var mountPoint: URL
        public var name: String
        /// `volumeTypeName`: "apfs", "hfs", "exfat", "msdos"…
        public var format: String
        public var availableBytes: Int64
        public var totalBytes: Int64
        public var isInternal: Bool
        public var isRemovable: Bool
        public var uuid: String? = nil
        /// Human format, e.g. "APFS" or "ExFAT" (falls back to `format`).
        public var formatDescription: String? = nil
        public var isEjectable: Bool = false

        public var isAPFS: Bool { format.lowercased() == "apfs" }
        public var kind: Kind { isInternal && !isRemovable ? .internal : isRemovable ? .removable : .external }
        public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
        /// Why it cannot hold the data, or nil when it can.
        public var unusableReason: String? { isAPFS ? nil : "Needs APFS — format it with Disk Utility" }
        /// The folder a click on this volume selects.
        public var defaultFolder: URL { mountPoint.appendingPathComponent("Micropod") }
    }

    /// One mounted volume as the system reports it, before filtering.
    /// Separate from `Volume` so the filtering is testable without disks.
    public struct VolumeDescriptor: Sendable, Equatable {
        public var volume: Volume
        public var isLocal: Bool
        public var isReadOnly: Bool
        public var isRootFileSystem: Bool
        /// Mounted from a disk image (a `.dmg`, per `hdiutil info`).
        public var isDiskImage: Bool
        public init(volume: Volume, isLocal: Bool, isReadOnly: Bool, isRootFileSystem: Bool, isDiskImage: Bool) {
            self.volume = volume
            self.isLocal = isLocal
            self.isReadOnly = isReadOnly
            self.isRootFileSystem = isRootFileSystem
            self.isDiskImage = isDiskImage
        }
    }

    private static let volumeKeys: Set<URLResourceKey> = [
        .volumeURLKey, .volumeNameKey, .volumeTypeNameKey, .volumeLocalizedFormatDescriptionKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
        .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey, .volumeUUIDStringKey,
    ]

    private static func descriptor(at url: URL, diskImages: Set<String>) -> VolumeDescriptor? {
        guard let values = try? url.resourceValues(forKeys: volumeKeys), let mount = values.volume else { return nil }
        // "Important usage" counts purgeable space as free; fall back to the
        // plain figure where a filesystem (exFAT) does not report it.
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let volume = Volume(
            mountPoint: mount, name: values.volumeName ?? mount.lastPathComponent,
            format: values.volumeTypeName ?? "unknown", availableBytes: available,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0), isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false, uuid: values.volumeUUIDString,
            formatDescription: values.volumeLocalizedFormatDescription, isEjectable: values.volumeIsEjectable ?? false)
        return VolumeDescriptor(
            volume: volume, isLocal: values.volumeIsLocal ?? true, isReadOnly: values.volumeIsReadOnly ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            isDiskImage: diskImages.contains(mount.standardizedFileURL.path))
    }

    /// The volume `url` (or its nearest existing ancestor) is on.
    public static func volume(containing url: URL) -> Volume? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
        return descriptor(at: probe, diskImages: [])?.volume
    }

    /// Whether a volume belongs in the picker: writable local storage, not
    /// the system's own volumes, backups, disk images or network shares.
    /// The home directory's volume (the internal Data volume, mounted under
    /// /System/Volumes) is kept: it is the default location.
    public static func isSelectable(_ d: VolumeDescriptor, homeVolume: URL?) -> Bool {
        let path = d.volume.mountPoint.standardizedFileURL.path
        if let homeVolume, path == homeVolume.standardizedFileURL.path { return d.volume.totalBytes > 0 }
        if d.volume.totalBytes <= 0 || !d.isLocal || d.isReadOnly || d.isDiskImage || d.isRootFileSystem {
            return false
        }
        if path == "/" || path.hasPrefix("/System/Volumes/") || path.hasPrefix("/private/") { return false }
        let name = d.volume.name
        if name == "Recovery" || name == "Preboot" || name == "VM" || name == "Update" { return false }
        // Time Machine: its APFS backup volumes and the snapshot mounts.
        let backupDB = d.volume.mountPoint.appendingPathComponent("Backups.backupdb").path
        if name.hasPrefix("Backups of ") || path.contains("/.timemachine/") || path.contains(".backupdb")
            || FileManager.default.fileExists(atPath: backupDB)
        {
            return false
        }
        return true
    }

    /// Filters and orders `descriptors` for the picker: the internal disk
    /// first, then other volumes by name. Duplicate mounts collapse.
    public static func classify(_ descriptors: [VolumeDescriptor], homeVolume: URL?) -> [Volume] {
        var seen = Set<String>()
        var volumes: [Volume] = []
        for d in descriptors where isSelectable(d, homeVolume: homeVolume) {
            let key = d.volume.uuid ?? d.volume.mountPoint.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            var volume = d.volume
            if let homeVolume, d.volume.mountPoint.standardizedFileURL.path == homeVolume.standardizedFileURL.path {
                volume.isInternal = true
                volume.isRemovable = false
            }
            volumes.append(volume)
        }
        let order: (Volume) -> Int = { $0.kind == .internal ? 0 : $0.kind == .external ? 1 : 2 }
        return volumes.sorted {
            (order($0), $0.name.localizedLowercase) < (order($1), $1.name.localizedLowercase)
        }
    }

    /// Writable local volumes a user could pick, internal disk first.
    public static func candidateVolumes(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [Volume] {
        let images = diskImageMountPoints()
        var descriptors =
            (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(volumeKeys), options: [])
            ?? []).compactMap { descriptor(at: $0, diskImages: images) }
        let homeDescriptor = descriptor(at: home, diskImages: images)
        if let homeDescriptor { descriptors.insert(homeDescriptor, at: 0) }
        return classify(descriptors, homeVolume: homeDescriptor?.volume.mountPoint)
    }

    /// Mount points of attached disk images (`hdiutil info`): a mounted
    /// installer `.dmg` looks like any other external APFS/HFS volume.
    static func diskImageMountPoints() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseDiskImageMountPoints(data)
    }

    static func parseDiskImageMountPoints(_ plist: Data) -> Set<String> {
        guard
            let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        else { return [] }
        var mounts = Set<String>()
        for image in images {
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                if let mount = entity["mount-point"] as? String {
                    mounts.insert(URL(fileURLWithPath: mount).standardizedFileURL.path)
                }
            }
        }
        return mounts
    }

    /// Resolves a `micropod storage set` argument: a path, or a volume's
    /// name or UUID among `volumes` (its `Micropod` folder). Nil when a
    /// name or UUID matches nothing.
    public static func resolveTarget(_ argument: String, volumes: [Volume]) -> String? {
        if argument.hasPrefix("/") || argument.hasPrefix("~") || argument.hasPrefix(".") {
            return (argument as NSString).expandingTildeInPath
        }
        let match =
            volumes.first { $0.uuid?.caseInsensitiveCompare(argument) == .orderedSame }
            ?? volumes.first { $0.name == argument }
            ?? volumes.first { $0.name.caseInsensitiveCompare(argument) == .orderedSame }
        return match?.defaultFolder.path
    }

    // MARK: - Space

    /// Space the move needs on the target: the data plus headroom (10%, at
    /// least 5 GiB) so containers can keep writing afterwards.
    public static func requiredBytes(forData data: Int64) -> Int64 {
        data + max(data / 10, 5 * 1_073_741_824)
    }

    /// Bytes on disk under `urls` (`du -sk`, following no links but the
    /// top-level ones: a moved tree is measured where it now lives).
    public static func estimateBytes(of urls: [URL]) -> Int64 {
        let existing = urls.map { $0.resolvingSymlinksInPath() }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existing.isEmpty else { return 0 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk"] + existing.map(\.path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n").reduce(Int64(0)) { sum, line in
            sum + (Int64(line.split(whereSeparator: \.isWhitespace).first ?? "") ?? 0) * 1024
        }
    }

    /// The data a move to `root` would copy: every tree not already there.
    public static func dataToMove(root: String, paths: Paths = Paths()) -> [URL] {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        return paths.trees(under: rootURL).compactMap { _, source, target in
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path) {
                return URL(fileURLWithPath: link).standardizedFileURL == target ? nil : URL(fileURLWithPath: link)
            }
            return source
        }
    }

    // MARK: - Validation

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notAbsolute(String)
        case volumeNotMounted(String)
        case notAPFS(volume: String, format: String)
        case notWritable(String)
        case insideDefaultLocation(String)
        case targetNotEmpty(String)
        case doesNotFit(volume: String, needed: Int64, available: Int64)

        public var description: String {
            switch self {
            case .notAbsolute(let p): return "\(p) is not an absolute path"
            case .volumeNotMounted(let p):
                return "\(p) is not on a mounted volume (is the drive connected?)"
            case .notAPFS(let v, let f):
                return
                    "\(v) is \(f), not APFS: container and sandbox data rely on APFS clones and sparse files; reformat it as APFS"
            case .notWritable(let p): return "\(p) is not writable"
            case .insideDefaultLocation(let p):
                return
                    "\(p) is inside the data it would hold (pick a directory outside ~/.micropod and the container app root)"
            case .targetNotEmpty(let p):
                return "\(p) already holds data; pass --migrate only into an empty or Micropod-created directory"
            case .doesNotFit(let v, let needed, let available):
                return
                    "\(v) has \(ByteFormat.string(available)) free; the data needs \(ByteFormat.string(needed)) with headroom"
            }
        }
    }

    /// Checks `root` can hold the data. A path under `/Volumes/<name>` needs
    /// that volume mounted: the mount point itself must exist.
    public static func validate(root: String, paths: Paths = Paths()) -> [Problem] {
        guard root.hasPrefix("/") else { return [.notAbsolute(root)] }
        let url = URL(fileURLWithPath: root).standardizedFileURL
        let components = url.pathComponents
        if components.count >= 3, components[1] == "Volumes",
            !FileManager.default.fileExists(atPath: "/Volumes/\(components[2])")
        {
            return [.volumeNotMounted(root)]
        }
        for (_, source, _) in paths.trees(under: url)
        where url.path.hasPrefix(source.resolvingSymlinksInPath().path + "/")
            || url.path == source.path
        {
            return [.insideDefaultLocation(root)]
        }
        if url.path.hasPrefix(paths.micropodHome.path + "/") { return [.insideDefaultLocation(root)] }
        var problems: [Problem] = []
        guard let vol = volume(containing: url) else { return [.volumeNotMounted(root)] }
        if !vol.isAPFS { problems.append(.notAPFS(volume: vol.name, format: vol.format)) }
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) { probe.deleteLastPathComponent() }
        if !FileManager.default.isWritableFile(atPath: probe.path) { problems.append(.notWritable(probe.path)) }
        return problems
    }

    // MARK: - Status

    public struct TreeStatus: Sendable, Equatable {
        public var name: String
        public var defaultPath: String
        /// Where the data actually is (the symlink's target when moved).
        public var location: String
        public var moved: Bool
        /// A moved tree whose target is gone: its volume is not mounted.
        public var missing: Bool
        public var oldDataLeft: Bool
    }

    public struct Status: Sendable, Equatable {
        public var configuredRoot: String?
        public var trees: [TreeStatus]
        /// Human-readable trouble, empty when healthy.
        public var problems: [String]
        /// The configured drive (by UUID) is not mounted: the runtime cannot
        /// start until it is reconnected.
        public var driveDisconnected: Bool = false
        /// The drive is mounted, but somewhere else (renamed, or remounted
        /// as `/Volumes/<name> 1`): `relink` points the data back at it.
        public var relinkTo: String? = nil
        public var volumeUUID: String? = nil
        public var volumeName: String? = nil
        public var healthy: Bool { problems.isEmpty }
    }

    /// `mounted` is consulted only for a config that names a volume by
    /// UUID; nil probes the system.
    public static func status(paths: Paths = Paths(), mounted: [Volume]? = nil) -> Status {
        let config = loadConfig(paths)
        let fm = FileManager.default
        var trees: [TreeStatus] = []
        var problems: [String] = []
        var disconnected = false
        var relinkTo: String?
        if let uuid = config.volumeUUID {
            let volumes = mounted ?? candidateVolumes(home: paths.home)
            if !volumes.contains(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) {
                disconnected = true
                problems.append(
                    "storage drive \(config.volumeName ?? uuid) is not connected: the runtime is stopped until it is")
            } else if let resolved = config.resolvedRoot(mounted: volumes), resolved != config.root {
                relinkTo = resolved
            }
        }
        let root = config.root.map { URL(fileURLWithPath: $0) } ?? paths.home
        for (name, source, _) in paths.trees(under: root) {
            let link = try? fm.destinationOfSymbolicLink(atPath: source.path)
            let target = link.map { URL(fileURLWithPath: $0, relativeTo: source.deletingLastPathComponent()).path }
            let missing = target.map { !fm.fileExists(atPath: $0) } ?? false
            let old = fm.fileExists(atPath: source.path + oldDataSuffix)
            trees.append(
                TreeStatus(
                    name: name, defaultPath: source.path, location: target ?? source.path, moved: link != nil,
                    missing: missing, oldDataLeft: old))
            if missing, let target, !disconnected, relinkTo == nil {
                problems.append("\(name) data is at \(target), which is not mounted: connect the drive")
            }
        }
        if let relinkTo {
            problems.append(
                "storage drive \(config.volumeName ?? "") is now at \(relinkTo): relink (`micropod storage relink`)")
        }
        if let configured = config.root {
            let notMoved = trees.filter { !$0.moved && FileManager.default.fileExists(atPath: $0.defaultPath) }
            if !notMoved.isEmpty {
                problems.append(
                    "configured for \(configured) but \(notMoved.map(\.name).joined(separator: ", ")) still on the internal disk: run `micropod storage set \(configured) --migrate` again"
                )
            }
        }
        return Status(
            configuredRoot: config.root, trees: trees, problems: problems, driveDisconnected: disconnected,
            relinkTo: relinkTo, volumeUUID: config.volumeUUID, volumeName: config.volumeName)
    }

    /// Points the moved trees at the configured drive's current mount point
    /// (it was renamed or remounted elsewhere) and records the new root.
    /// Returns the trees relinked. The runtime is not touched: it could not
    /// start while the links dangled, so the caller starts it afterwards.
    @discardableResult
    public static func relink(paths: Paths = Paths(), mounted: [Volume]? = nil) throws -> [String] {
        var config = loadConfig(paths)
        let volumes = mounted ?? candidateVolumes(home: paths.home)
        guard let oldRoot = config.root, let newRoot = config.resolvedRoot(mounted: volumes), newRoot != oldRoot else {
            return []
        }
        let fm = FileManager.default
        let newURL = URL(fileURLWithPath: newRoot)
        var relinked: [String] = []
        for (name, source, target) in paths.trees(under: newURL) {
            guard (try? fm.destinationOfSymbolicLink(atPath: source.path)) != nil else { continue }
            let staging = source.deletingLastPathComponent().appendingPathComponent(
                ".\(source.lastPathComponent).relink-\(getpid())")
            try? fm.removeItem(at: staging)
            try fm.createSymbolicLink(at: staging, withDestinationURL: target)
            guard rename(staging.path, source.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(at: staging)
                throw MicropodError.message("relinking \(source.path): \(reason)")
            }
            relinked.append(name)
        }
        config.root = newRoot
        try saveConfig(config, paths)
        return relinked
    }

    // MARK: - Applying

    /// Runs `container system stop|start`; injected so tests need no runtime.
    public typealias SystemControl = @Sendable (_ start: Bool) async throws -> Void

    public enum Step: Sendable, Equatable {
        case stopRuntime
        case copy(name: String, from: String, to: String)
        case moveAside(name: String, from: String, to: String)
        case link(name: String, at: String, to: String)
        case alreadyThere(name: String)
        case startRuntime
    }

    /// Moves every tree under `root` and points its default path there.
    /// `migrate` copies the current data across (`ditto`, preserving
    /// sparseness and clones within the source); without it the new location
    /// starts empty. The old data is kept as `<default>.pre-relocate` either
    /// way; `removeOldData` deletes it. `progress` reports each step.
    public static func apply(
        root: String, migrate: Bool, paths: Paths = Paths(), control: SystemControl,
        estimate: @Sendable ([URL]) -> Int64 = { estimateBytes(of: $0) },
        progress: @Sendable (Step) -> Void = { _ in }
    ) async throws {
        let problems = validate(root: root, paths: paths)
        if let first = problems.first { throw MicropodError.message(first.description) }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let targetVolume = volume(containing: rootURL)
        // Refuse before stopping anything when the copy cannot fit.
        if migrate, let targetVolume {
            let needed = requiredBytes(forData: estimate(dataToMove(root: root, paths: paths)))
            if needed > targetVolume.availableBytes {
                let problem = Problem.doesNotFit(
                    volume: targetVolume.name, needed: needed, available: targetVolume.availableBytes)
                throw MicropodError.message(problem.description)
            }
        }
        let fm = FileManager.default
        progress(.stopRuntime)
        try await control(false)
        do {
            for (name, source, target) in paths.trees(under: rootURL) {
                if let link = try? fm.destinationOfSymbolicLink(atPath: source.path),
                    URL(fileURLWithPath: link).standardizedFileURL == target
                {
                    progress(.alreadyThere(name: name))
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let current = (try? fm.destinationOfSymbolicLink(atPath: source.path)).map {
                    URL(fileURLWithPath: $0)
                }
                let dataAt = current ?? source
                let hasData = fm.fileExists(atPath: dataAt.path)
                if migrate, hasData {
                    if fm.fileExists(atPath: target.path),
                        !((try? fm.contentsOfDirectory(atPath: target.path))?.isEmpty ?? true)
                    {
                        throw MicropodError.message(Problem.targetNotEmpty(target.path).description)
                    }
                    progress(.copy(name: name, from: dataAt.path, to: target.path))
                    try runDitto(from: dataAt, to: target)
                } else {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                if current != nil {
                    // Previously moved elsewhere: drop only the link; the old
                    // location's data stays where it is.
                    try fm.removeItem(at: source)
                } else if hasData {
                    let aside = URL(fileURLWithPath: source.path + oldDataSuffix)
                    if fm.fileExists(atPath: aside.path) {
                        throw MicropodError.message(
                            "\(aside.path) already exists from an earlier move: remove it (`micropod storage remove-old`) first"
                        )
                    }
                    progress(.moveAside(name: name, from: source.path, to: aside.path))
                    try fm.moveItem(at: source, to: aside)
                }
                progress(.link(name: name, at: source.path, to: target.path))
                try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: source, withDestinationURL: target)
            }
            try saveConfig(Config.at(rootURL, on: targetVolume), paths)
        } catch {
            // Leave the runtime running on whatever is in place: a partial
            // move still has every tree reachable (aside or linked).
            progress(.startRuntime)
            try? await control(true)
            throw error
        }
        progress(.startRuntime)
        try await control(true)
    }

    /// Moves the data back to the internal disk's default paths (copying it
    /// back with `migrate`) and clears the setting.
    public static func reset(migrate: Bool, paths: Paths = Paths(), control: SystemControl) async throws {
        let fm = FileManager.default
        try await control(false)
        for (_, source, _) in paths.trees(under: paths.home) {
            guard let link = try? fm.destinationOfSymbolicLink(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: link)
            try fm.removeItem(at: source)
            if migrate, fm.fileExists(atPath: target.path) {
                try runDitto(from: target, to: source)
            } else {
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
            }
        }
        try saveConfig(Config(root: nil), paths)
        try await control(true)
    }

    /// Deletes the `.pre-relocate` copies a move left behind. Returns the
    /// paths removed.
    @discardableResult
    public static func removeOldData(paths: Paths = Paths()) throws -> [String] {
        var removed: [String] = []
        for (_, source, _) in paths.trees(under: paths.home) {
            let aside = source.path + oldDataSuffix
            if FileManager.default.fileExists(atPath: aside) {
                try FileManager.default.removeItem(atPath: aside)
                removed.append(aside)
            }
        }
        return removed
    }

    static func runDitto(from source: URL, to target: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, target.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw MicropodError.message("copying \(source.path) to \(target.path) failed: \(message)")
        }
    }
}
