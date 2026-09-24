import Foundation

/// How named-volume mounts are handled on container create — the shared
/// policy read by every surface that creates containers (API, docker
/// shim, app, CLI, MCP) so a UI toggle applies everywhere without each
/// client passing labels.
///
/// Precedence: per-container `com.micropod.*` labels > this policy >
/// per-mount defaults (fsync / cached / direct attach).
public struct VolumePolicy: Codable, Sendable, Equatable {
    /// Which named-volume mounts get clonefile-forked per container.
    public enum CloneMode: String, Codable, Sendable, CaseIterable {
        /// Only when the container carries `com.micropod.cache.clone`.
        case labels
        /// Auto-clone mounts of the volumes named in `goldenVolumes`.
        case goldens
        /// Clone every named-volume mount.
        case all
    }

    /// `full` / `fsync` / `nosync` — nil = per-mount default (fsync for
    /// named volumes, nosync for clones).
    public enum SyncMode: String, Codable, Sendable, CaseIterable {
        case full, fsync, nosync
    }

    /// `on` / `off` / `auto` — VZ disk-image caching mode.
    public enum CacheMode: String, Codable, Sendable, CaseIterable {
        case on, off, auto
    }

    public var cloneMode: CloneMode
    /// Golden volume names auto-cloned under `.goldens` mode.
    public var goldenVolumes: [String]
    /// When true, the clone policy only applies to job-labelled
    /// containers (`com.cuttlefish.job` / `com.micropod.job`). Per-
    /// container `com.micropod.cache.clone` labels always apply.
    public var jobsOnly: Bool
    public var sync: SyncMode?
    public var cache: CacheMode

    public init(
        cloneMode: CloneMode = .labels,
        goldenVolumes: [String] = [],
        jobsOnly: Bool = false,
        sync: SyncMode? = nil,
        cache: CacheMode = .on
    ) {
        self.cloneMode = cloneMode
        self.goldenVolumes = goldenVolumes
        self.jobsOnly = jobsOnly
        self.sync = sync
        self.cache = cache
    }

    public static let standard = VolumePolicy()

    /// Tolerant decode: any absent field falls back to the standard
    /// default so partial API bodies and older/newer files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cloneMode = try c.decodeIfPresent(CloneMode.self, forKey: .cloneMode) ?? .labels
        goldenVolumes = try c.decodeIfPresent([String].self, forKey: .goldenVolumes) ?? []
        jobsOnly = try c.decodeIfPresent(Bool.self, forKey: .jobsOnly) ?? false
        sync = try c.decodeIfPresent(SyncMode.self, forKey: .sync)
        cache = try c.decodeIfPresent(CacheMode.self, forKey: .cache) ?? .on
    }

    /// Clone set for a create: explicit labels win; otherwise the policy
    /// decides — gated by `jobsOnly` for non-job containers.
    public func cloneSet(labels: [String: String]) -> Set<String> {
        if let explicit = labels["com.micropod.cache.clone"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty
        {
            return Set(
                explicit.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
        }
        if jobsOnly, Self.jobLabel(in: labels) == false { return [] }
        switch cloneMode {
        case .labels: return []
        case .goldens: return Set(goldenVolumes)
        case .all: return ["*"]
        }
    }

    /// Effective sync case name for a mount: label > policy > `fallback`.
    public func syncCase(labels: [String: String], fallback: String) -> String {
        Self.parseSync(labels["com.micropod.volume.sync"]) ?? sync?.rawValue ?? fallback
    }

    /// Effective cache case name: label > policy.
    public func cacheCase(labels: [String: String]) -> String {
        Self.parseCache(labels["com.micropod.volume.cache"]) ?? cache.rawValue
    }

    public static func jobLabel(in labels: [String: String]) -> Bool {
        labels["com.cuttlefish.job"].map { !$0.isEmpty } == true
            || labels["com.micropod.job"].map { !$0.isEmpty } == true
    }

    static func parseSync(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "full": return "full"
        case "fsync": return "fsync"
        case "nosync", "none": return "nosync"
        default: return nil
        }
    }

    static func parseCache(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "off", "uncached": return "off"
        case "auto", "automatic": return "auto"
        case "on", "cached": return "on"
        default: return nil
        }
    }
}

/// Persists `VolumePolicy` at
/// `~/Library/Application Support/micropod/volume-policy.json` — one file
/// every Micropod process reads at create time, so a change in the app is
/// picked up by the API server, shim, CLI, and MCP without a restart.
/// `MICROPOD_VOLUME_POLICY` overrides the path (tests).
public enum VolumePolicyStore {
    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["MICROPOD_VOLUME_POLICY"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("micropod/volume-policy.json")
    }

    /// Missing or unreadable files resolve to `.standard` — a corrupt
    /// policy must never break container creates.
    public static func load() -> VolumePolicy {
        guard let data = try? Data(contentsOf: url),
            let policy = try? JSONDecoder().decode(VolumePolicy.self, from: data)
        else { return .standard }
        return policy
    }

    public static func save(_ policy: VolumePolicy) throws {
        let target = url
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(policy)
        try data.write(to: target, options: .atomic)
    }
}
