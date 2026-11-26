import Foundation
import MicropodCore

// MARK: - Live Guest Cache Inspection, Dedupe & Prune Models

public struct HVFCacheUnitUsage: Codable, Sendable, Equatable {
    public let scope: String
    public let kind: String
    public let unit: String
    public let uid: UInt32?
    public let layer: String
    public let path: String
    public let bytes: UInt64
    public let logicalBytes: UInt64
    public let files: UInt64
    public let lastUsedUnix: Int64
    public let inUse: Bool
    /// The guest's crash fence has the unit (or an alias volume's kind-wide
    /// unit covering it) marked dirty: a writer may have left unsynced
    /// entries. The janitor and `cache prune` never touch a dirty unit.
    /// Absent from guests that predate the fence.
    public var dirty: Bool? = nil
}

public struct HVFCacheTotals: Codable, Sendable, Equatable {
    public let totalBytes: UInt64
    public let logicalBytes: UInt64
    public let totalFiles: UInt64
    public let scopeCount: Int
    public let unitCount: Int
    public let inUseCount: Int
    public let l0Bytes: UInt64
    public let l1Bytes: UInt64
    /// Units the crash fence has marked dirty.
    public var dirtyCount: Int? = nil
}

public struct HVFCacheBudgetStatus: Codable, Sendable, Equatable {
    public let maxBytes: UInt64
    public let minFreeBytes: UInt64
    public let maxAgeDays: Int
    public let utilizationPct: Double?
}

public struct HVFCacheEvictionSummary: Codable, Sendable, Equatable {
    public let evictions: UInt64
    public let evictedUnits: UInt64
    public let evictedFiles: UInt64
    public let evictedBytes: UInt64
    public let lastSweepUnix: Int64?
    public let lastSweepReason: String?
}

public struct HVFCacheInspection: Codable, Sendable, Equatable {
    public let root: String
    public let mountPoint: String
    public let mountL0Point: String?
    public let policy: HVFMachineCachePolicy?
    public let policyDigest: String
    public let scopes: [String: [String]]
    public let units: [HVFCacheUnitUsage]?
    public let totals: HVFCacheTotals?
    public let budget: HVFCacheBudgetStatus?
    public let evictions: HVFCacheEvictionSummary?
    /// Units (`scope/unit`) the engine moved to trash at its start because an
    /// unclean stop left them marked dirty.
    public var discardedAtStart: [String]? = nil
    /// Marked units the engine kept at its start because their boot stopped
    /// cleanly (or is still running).
    public var keptAtStart: [String]? = nil
    /// The persistent cache disk (caches.ext4) as the guest sees it: guest
    /// init's outcome and what its mountinfo shows. Absent from guests that
    /// predate it; an engine that sent guest init's word alone decodes too.
    public var cacheDisk: HVFCacheDiskState? = nil
    /// Why the guest has no shared caches this boot (the cache disk should be
    /// mounted but is not): every container then runs uncached. Absent while
    /// shared caches work.
    public var unavailable: String? = nil

    /// The reason shared caches are off this boot, or nil while they work.
    public var sharedCachesOffReason: String? {
        guard let why = unavailable?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty else {
            return nil
        }
        return why
    }
}

public struct HVFCacheDedupeSample: Codable, Sendable, Equatable {
    public let scopesSampled: [String]
    public let bucketsSampled: Int
    public let totalObjects: UInt64
    public let uniqueObjects: UInt64
    public let duplicateObjects: UInt64
    public let duplicateBytes: UInt64
    public let estimatedFullDuplicateBytes: UInt64
}

public struct HVFCachePruneRequest: Encodable, Sendable, Equatable {
    public var scope: String?
    public var tool: String?
    public var olderThanSecs: Int64?
    public var maxBytes: UInt64?
    public var partialGoBuild: Bool?
    public var safetyCutoffSecs: Int64?
    public var maxUnits: Int?
    /// Required, never defaulted: a caller that forgets it must not evict.
    /// Always encoded, so the guest never falls back to its own default.
    public var dryRun: Bool
    public var reason: String?

    public init(
        scope: String? = nil, tool: String? = nil, olderThanSecs: Int64? = nil, maxBytes: UInt64? = nil,
        partialGoBuild: Bool? = nil, safetyCutoffSecs: Int64? = nil, maxUnits: Int? = nil, dryRun: Bool,
        reason: String? = nil
    ) {
        self.scope = scope
        self.tool = tool
        self.olderThanSecs = olderThanSecs
        self.maxBytes = maxBytes
        self.partialGoBuild = partialGoBuild
        self.safetyCutoffSecs = safetyCutoffSecs
        self.maxUnits = maxUnits
        self.dryRun = dryRun
        self.reason = reason
    }
}

public struct HVFCachePruneAction: Codable, Sendable, Equatable {
    public let scope: String
    public let unit: String
    public let action: String
    public let files: UInt64?
    public let bytes: UInt64
}

public struct HVFCachePruneResult: Codable, Sendable, Equatable {
    public let dryRun: Bool
    public let reason: String
    public let freedBytes: UInt64
    public let freedFiles: UInt64
    public let evictedUnits: UInt64
    public let skippedInUse: UInt64
    public let beforeBytes: UInt64
    public let afterBytes: UInt64
    public let actions: [HVFCachePruneAction]
    /// Units left alone because the crash fence still had them marked dirty.
    public var skippedDirty: UInt64? = nil
}

public struct HVFContainerCacheTool: Codable, Sendable, Equatable {
    public let mode: String
    public let path: String?
    public let reason: String?
    public let layer: String?
    public let scope: String?
    /// How the latest start reached the store: `copy-on-write` (a view of
    /// the container's own, whose writes go with it) or `read-only`; nil is
    /// the store itself, read-write. Absent from guests before the trust tier.
    public var access: String? = nil
}

public struct HVFContainerCachePlan: Codable, Sendable, Equatable {
    public let scope: String?
    public let uid: UInt32?
    public let gid: UInt32?
    public let home: String?
    public let reason: String?
    public let policyDigest: String?
    public let tools: [String: HVFContainerCacheTool]?
    /// The container's cache trust tier: `untrusted` or `readonly`; nil is
    /// trusted (the guest leaves it out then).
    public var trust: String? = nil
    /// Where the tier came from: `policy-default`, `label`, `claim-refused`,
    /// `creator` or `legacy-policy-default`.
    public var trustFrom: String? = nil
    /// The dependency proxy decision per tool kind (`gomod`, `npm`, `pnpm`):
    /// `injected`, or why it was left out (`reader-tier`, `request-env`,
    /// `npmrc-registry`, `goenv-proxy`, `proxy-unreachable`).
    public var proxy: [String: String]? = nil

    /// `trust`, with trusted for nil.
    public var effectiveTrust: String { trust.flatMap { $0.isEmpty ? nil : $0 } ?? "trusted" }
}

public struct HVFContainerCacheExplain: Codable, Sendable, Equatable {
    public let containerId: String
    public let containerName: String
    public let image: String
    public let state: String
    public let cache: HVFContainerCachePlan?
}

// MARK: - HVFMachineClient Cache Queries

extension HVFMachineClient {
    /// Fetch live cache inventory, per-unit byte usage, lock state, budget & evictions.
    public func cacheInspection(includeStats: Bool = true, timeout: Duration = .seconds(10)) async throws
        -> HVFCacheInspection
    {
        try ensureSocketReachable()
        let query = includeStats ? [:] : ["stats": "0"]
        let resp = try await docker.request("GET", "/micropod/caches", query: query, timeout: timeout)
        guard resp.status == 200 else {
            throw MicropodError.message(
                "guest cache inspection failed (HTTP \(resp.status)): \(String(decoding: resp.body, as: UTF8.self))")
        }
        return try JSONDecoder().decode(HVFCacheInspection.self, from: resp.body)
    }

    /// Run cross-scope Go build-cache duplication sampling across `buckets` (1..256).
    public func cacheDedupe(buckets: Int = 16, timeout: Duration = .seconds(15)) async throws -> HVFCacheDedupeSample {
        try ensureSocketReachable()
        let resp = try await docker.request(
            "GET", "/micropod/caches/dedupe", query: ["buckets": "\(buckets)"], timeout: timeout)
        guard resp.status == 200 else {
            throw MicropodError.message(
                "guest cache dedupe failed (HTTP \(resp.status)): \(String(decoding: resp.body, as: UTF8.self))")
        }
        return try JSONDecoder().decode(HVFCacheDedupeSample.self, from: resp.body)
    }

    /// Run lock-safe bounded LRU / partial Go-build cache pruning.
    public func cachePrune(_ request: HVFCachePruneRequest, timeout: Duration = .seconds(30)) async throws
        -> HVFCachePruneResult
    {
        try ensureSocketReachable()
        var payload: [String: Any] = ["dryRun": request.dryRun]
        if let scope = request.scope { payload["scope"] = scope }
        if let tool = request.tool { payload["tool"] = tool }
        if let older = request.olderThanSecs { payload["olderThanSecs"] = older }
        if let maxB = request.maxBytes { payload["maxBytes"] = maxB }
        if let partial = request.partialGoBuild { payload["partialGoBuild"] = partial }
        if let cutoff = request.safetyCutoffSecs { payload["safetyCutoffSecs"] = cutoff }
        if let maxU = request.maxUnits { payload["maxUnits"] = maxU }
        if let reason = request.reason { payload["reason"] = reason }
        let resp = try await docker.request("POST", "/micropod/caches/prune", json: payload, timeout: timeout)
        guard resp.status == 200 else {
            throw MicropodError.message(
                "guest cache prune failed (HTTP \(resp.status)): \(String(decoding: resp.body, as: UTF8.self))")
        }
        return try JSONDecoder().decode(HVFCachePruneResult.self, from: resp.body)
    }

    /// Inspect a container's `MicropodCache` attach/skip decision plan.
    /// A Docker container id or name, as one request path segment.
    public static let containerReference = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$"

    public func explainContainerCache(_ container: String, timeout: Duration = .seconds(5)) async throws
        -> HVFContainerCacheExplain
    {
        // One path segment: '/', '?' or '#' would name another guest route.
        guard container.range(of: Self.containerReference, options: .regularExpression) != nil else {
            throw MicropodError.message("invalidArgument: '\(container)' is not a container id or name")
        }
        try ensureSocketReachable()
        let resp = try await docker.request("GET", "/containers/\(container)/json", timeout: timeout)
        guard resp.status == 200 else {
            throw MicropodError.message(
                "container '\(container)' not found or inspect failed (HTTP \(resp.status))")
        }
        struct RawInspect: Decodable {
            struct State: Decodable { let Status: String? }
            let Id: String
            let Name: String?
            let Image: String?
            let State: State?
            let MicropodCache: HVFContainerCachePlan?
        }
        let raw = try JSONDecoder().decode(RawInspect.self, from: resp.body)
        let cleanName = (raw.Name ?? raw.Id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return HVFContainerCacheExplain(
            containerId: raw.Id,
            containerName: cleanName,
            image: raw.Image ?? "",
            state: raw.State?.Status ?? "unknown",
            cache: raw.MicropodCache)
    }

    private func ensureSocketReachable() throws {
        guard FileManager.default.fileExists(atPath: layout.dockerSocket.path) else {
            throw MicropodError.message(
                "failedPrecondition: hvf machine is not running (no socket at \(layout.dockerSocket.path)); "
                    + "start with `micropod machine start`")
        }
    }
}
