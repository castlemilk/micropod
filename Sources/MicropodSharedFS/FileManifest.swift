import Foundation

/// What a single path looked like at the end of the last successful sync.
///
/// `size` + `mtime` is the fast comparison; `digest` is the authority. A file
/// touched but not modified (a checkout, a `make` that rewrites a header
/// identically) changes mtime without changing content, and re-shipping it
/// costs far more than the hash needed to rule it out.
public struct ManifestEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
        case symlink
    }

    public var kind: Kind
    public var size: UInt64
    public var mtimeNanos: Int64
    /// SHA256 of the contents, or of the link target for a symlink. Empty for
    /// directories, which have no content of their own.
    public var digest: String
    /// POSIX permission bits, so a chmod alone still counts as a change.
    public var mode: UInt16

    public init(
        kind: Kind, size: UInt64, mtimeNanos: Int64, digest: String, mode: UInt16
    ) {
        self.kind = kind
        self.size = size
        self.mtimeNanos = mtimeNanos
        self.digest = digest
        self.mode = mode
    }

    /// Whether `other` could be the same content without hashing it. Only a
    /// cheap pre-filter — a false "yes" here is what `digest` exists to catch.
    func looksUnchanged(comparedTo other: ManifestEntry) -> Bool {
        kind == other.kind && size == other.size && mtimeNanos == other.mtimeNanos
            && mode == other.mode
    }
}

/// The state of a source tree as of the last sync into a particular volume.
public struct FileManifest: Codable, Sendable, Equatable {
    /// Bumped when the on-disk shape changes so a stale manifest is discarded
    /// rather than misread — a wrong manifest silently skips real changes.
    public static let currentVersion = 1

    public var version: Int
    /// Relative path (POSIX separators, no leading slash) → entry.
    public var entries: [String: ManifestEntry]
    /// Identifies the volume incarnation this history describes. A mismatch
    /// means the volume was deleted or replaced and the history is worthless.
    public var volumeFingerprint: String

    public init(
        version: Int = FileManifest.currentVersion,
        entries: [String: ManifestEntry] = [:],
        volumeFingerprint: String = ""
    ) {
        self.version = version
        self.entries = entries
        self.volumeFingerprint = volumeFingerprint
    }

    public var isEmpty: Bool { entries.isEmpty }
}

/// What changed between two manifests.
public struct ManifestDiff: Sendable, Equatable {
    /// Paths whose content must be shipped (new or modified files/symlinks).
    public var changed: [String]
    /// Directories that must exist even if they hold nothing to ship.
    public var directories: [String]
    /// Paths that no longer exist in the source and must be deleted.
    public var removed: [String]

    public var isEmpty: Bool { changed.isEmpty && removed.isEmpty && directories.isEmpty }

    public init(changed: [String] = [], directories: [String] = [], removed: [String] = []) {
        self.changed = changed
        self.directories = directories
        self.removed = removed
    }
}

extension FileManifest {
    /// Paths present here but not in `previous`, or whose entry differs, plus
    /// paths `previous` had that are now gone.
    ///
    /// Results are sorted so a sync is reproducible and diffable — an
    /// unordered tar makes two identical syncs look different.
    public func diff(against previous: FileManifest) -> ManifestDiff {
        guard previous.version == Self.currentVersion else {
            // Unreadable history: ship everything rather than guess.
            return ManifestDiff(
                changed: entries.filter { $0.value.kind != .directory }.keys.sorted(),
                directories: entries.filter { $0.value.kind == .directory }.keys.sorted(),
                removed: [])
        }
        var changed: [String] = []
        var directories: [String] = []
        for (path, entry) in entries {
            if entry.kind == .directory {
                if previous.entries[path]?.kind != .directory { directories.append(path) }
                continue
            }
            guard let before = previous.entries[path] else {
                changed.append(path)
                continue
            }
            if before.kind != entry.kind || before.digest != entry.digest
                || before.mode != entry.mode
            {
                changed.append(path)
            }
        }
        let removed = previous.entries.keys.filter { entries[$0] == nil }
        return ManifestDiff(
            changed: changed.sorted(), directories: directories.sorted(),
            removed: removed.sorted())
    }
}

/// Reads and writes manifests next to the chunk cache.
public struct ManifestStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// One manifest per (source tree, volume, destination) triple — the same
    /// tree synced into two volumes has two independent histories, and sharing
    /// one would make the second sync think it had already shipped everything.
    public func url(source: URL, volume: String, destination: String) -> URL {
        let key = "\(source.standardizedFileURL.path)\u{0}\(volume)\u{0}\(destination)"
        let digest = (try? ChunkHash.compute(Data(key.utf8)))?.value ?? "unkeyed"
        return root.appendingPathComponent("\(digest).json")
    }

    public func load(source: URL, volume: String, destination: String) -> FileManifest {
        let path = url(source: source, volume: volume, destination: destination)
        guard let data = try? Data(contentsOf: path),
            let manifest = try? JSONDecoder().decode(FileManifest.self, from: data)
        else {
            return FileManifest(version: 0)  // forces a full ship
        }
        return manifest
    }

    public func save(
        _ manifest: FileManifest, source: URL, volume: String, destination: String
    ) throws {
        let path = url(source: source, volume: volume, destination: destination)
        let data = try JSONEncoder().encode(manifest)
        // Atomic: a half-written manifest read back as valid would under-ship
        // on the next sync and leave the volume quietly stale.
        try data.write(to: path, options: .atomic)
    }

    public func forget(source: URL, volume: String, destination: String) throws {
        let path = url(source: source, volume: volume, destination: destination)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}
