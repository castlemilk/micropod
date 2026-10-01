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
        public init(root: String?) { self.root = root }
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
        public var mountPoint: URL
        public var name: String
        public var format: String
        public var availableBytes: Int64
        public var totalBytes: Int64
        public var isInternal: Bool
        public var isRemovable: Bool
        public var isAPFS: Bool { format.lowercased() == "apfs" }
    }

    /// The volume `url` (or its nearest existing ancestor) is on.
    public static func volume(containing url: URL) -> Volume? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey, .volumeTypeNameKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        ]
        guard let values = try? probe.resourceValues(forKeys: keys), let mount = values.volume else { return nil }
        return Volume(
            mountPoint: mount, name: values.volumeName ?? mount.lastPathComponent,
            format: values.volumeTypeName ?? "unknown",
            availableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0), isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false)
    }

    /// Writable local volumes a user could pick, internal disk first.
    public static func candidateVolumes() -> [Volume] {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { volume(containing: $0) }
            .filter { $0.totalBytes > 0 }
            .reduce(into: [Volume]()) { seen, v in
                if !seen.contains(where: { $0.mountPoint == v.mountPoint }) { seen.append(v) }
            }
            .sorted { ($0.isInternal ? 0 : 1, $0.name) < ($1.isInternal ? 0 : 1, $1.name) }
    }

    // MARK: - Validation

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notAbsolute(String)
        case volumeNotMounted(String)
        case notAPFS(volume: String, format: String)
        case notWritable(String)
        case insideDefaultLocation(String)
        case targetNotEmpty(String)

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
        public var healthy: Bool { problems.isEmpty }
    }

    public static func status(paths: Paths = Paths()) -> Status {
        let config = loadConfig(paths)
        let fm = FileManager.default
        var trees: [TreeStatus] = []
        var problems: [String] = []
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
            if missing, let target {
                problems.append("\(name) data is at \(target), which is not mounted: connect the drive")
            }
        }
        if let configured = config.root {
            let notMoved = trees.filter { !$0.moved && FileManager.default.fileExists(atPath: $0.defaultPath) }
            if !notMoved.isEmpty {
                problems.append(
                    "configured for \(configured) but \(notMoved.map(\.name).joined(separator: ", ")) still on the internal disk: run `micropod storage set \(configured) --migrate` again"
                )
            }
        }
        return Status(configuredRoot: config.root, trees: trees, problems: problems)
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
        progress: @Sendable (Step) -> Void = { _ in }
    ) async throws {
        let problems = validate(root: root, paths: paths)
        if let first = problems.first { throw MicropodError.message(first.description) }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
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
            try saveConfig(Config(root: rootURL.path), paths)
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
