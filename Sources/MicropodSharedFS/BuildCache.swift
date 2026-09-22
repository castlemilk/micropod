import Foundation

/// Shared model for the content-addressed build-context cache — the
/// virtualFS-backed "cache re-use" half of fast rebuilds.
///
/// Every retained build context is keyed by its content tree-hash
/// (paths + file bytes, mtime-insensitive) and carries a manifest listing
/// every file with its content digest. File digests use the SAME content
/// addressing as the chunk store (`ChunkHash`), so manifests make
/// cross-context sharing visible: two different services built from
/// overlapping trees (same Dockerfile, same go.sum) share file bytes even
/// though their tree-hashes differ. `sharedBytes` quantifies exactly that.
///
/// This file is pure and dependency-free so the shim (read/write), the CLI
/// and the MCP server (read-only scans), and tests all share one definition.
public struct BuildFileEntry: Codable, Sendable, Hashable {
    public var path: String
    public var sha256: String
    public var size: UInt64

    public init(path: String, sha256: String, size: UInt64) {
        self.path = path
        self.sha256 = sha256
        self.size = size
    }
}

public struct BuildManifest: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var treeHash: String
    public var files: [BuildFileEntry]
    public var tarBytes: Int
    public var storedAt: Date

    public init(treeHash: String, files: [BuildFileEntry], tarBytes: Int, storedAt: Date = Date()) {
        self.version = Self.currentVersion
        self.treeHash = treeHash
        self.files = files
        self.tarBytes = tarBytes
        self.storedAt = storedAt
    }

    /// Unique content bytes (deduped by digest within the entry).
    public var contentBytes: UInt64 {
        var seen = Set<String>()
        var total: UInt64 = 0
        for file in files where seen.insert(file.sha256).inserted {
            total += file.size
        }
        return total
    }
}

/// Legacy per-entry sidecar (bytes only, no file list). Read for backwards
/// compatibility with caches written before manifests existed.
struct LegacyBuildMeta: Codable {
    var bytes: UInt64
}

public struct BuildCacheStats: Sendable {
    public var entries: Int
    /// Sum of per-entry unique content bytes.
    public var contentBytes: UInt64
    /// Bytes whose digest appears in two or more entries — the directly
    /// measurable cross-context re-use.
    public var sharedBytes: UInt64
    public var capBytes: UInt64

    public init(entries: Int, contentBytes: UInt64, sharedBytes: UInt64, capBytes: UInt64) {
        self.entries = entries
        self.contentBytes = contentBytes
        self.sharedBytes = sharedBytes
        self.capBytes = capBytes
    }

    public static let empty = BuildCacheStats(entries: 0, contentBytes: 0, sharedBytes: 0, capBytes: 0)
}

public enum BuildCacheStore {
    /// `~/.micropod/builds/cache` unless `MICROPOD_BUILD_CACHE_DIR` overrides.
    public static func standardRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["MICROPOD_BUILD_CACHE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod/builds/cache", isDirectory: true)
    }

    /// Default 5 GiB unless `MICROPOD_BUILD_CACHE_MAX_BYTES` overrides.
    public static func capBytes() -> UInt64 {
        if let raw = ProcessInfo.processInfo.environment["MICROPOD_BUILD_CACHE_MAX_BYTES"],
            let parsed = UInt64(raw)
        {
            return parsed
        }
        return 5 << 30
    }

    public static func disabled() -> Bool {
        ProcessInfo.processInfo.environment["MICROPOD_BUILD_CACHE_DISABLE"] == "1"
    }

    /// Read-only scan of a cache root: manifests (with legacy-meta fallback)
    /// plus aggregate stats. Safe to call concurrently with a live writer —
    /// entries that vanish or fail to decode mid-scan are skipped.
    public static func scan(root: URL) -> (manifests: [BuildManifest], stats: BuildCacheStats) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var manifests: [BuildManifest] = []
        for name in names where name.count == 64 {
            let entry = root.appendingPathComponent(name, isDirectory: true)
            if let manifest = readManifest(entry: entry) {
                manifests.append(manifest)
            }
        }
        let contentBytes = manifests.reduce(0) { $0 + $1.contentBytes }
        let stats = BuildCacheStats(
            entries: manifests.count, contentBytes: contentBytes,
            sharedBytes: sharedBytes(manifests: manifests),
            capBytes: capBytes())
        return (manifests, stats)
    }

    /// Sum of file sizes whose digest occurs in two or more manifests.
    /// Counts each shared digest once (size from its first occurrence).
    public static func sharedBytes(manifests: [BuildManifest]) -> UInt64 {
        var counts: [String: Int] = [:]
        var sizes: [String: UInt64] = [:]
        for manifest in manifests {
            var seenInEntry = Set<String>()
            for file in manifest.files {
                if sizes[file.sha256] == nil { sizes[file.sha256] = file.size }
                if seenInEntry.insert(file.sha256).inserted {
                    counts[file.sha256, default: 0] += 1
                }
            }
        }
        var total: UInt64 = 0
        for (digest, count) in counts where count >= 2 {
            total += sizes[digest] ?? 0
        }
        return total
    }

    // MARK: - Private

    public static func readManifest(entry: URL) -> BuildManifest? {
        let manifestURL = entry.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(BuildManifest.self, from: data),
            manifest.version == BuildManifest.currentVersion
        {
            return manifest
        }
        // Legacy sidecar: bytes known, file list unknown (excluded from
        // shared accounting until the entry is re-stored with a manifest).
        let metaURL = entry.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
            let meta = try? JSONDecoder().decode(LegacyBuildMeta.self, from: data)
        {
            return BuildManifest(
                treeHash: entry.lastPathComponent, files: [],
                tarBytes: Int(meta.bytes), storedAt: Date.distantPast)
        }
        return nil
    }
}
