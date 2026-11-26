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
    public var dryRun: Bool
    public var reason: String?

    public init(
        scope: String? = nil, tool: String? = nil, olderThanSecs: Int64? = nil, maxBytes: UInt64? = nil,
        partialGoBuild: Bool? = nil, safetyCutoffSecs: Int64? = nil, maxUnits: Int? = nil, dryRun: Bool = false,
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
}

public struct HVFContainerCacheTool: Codable, Sendable, Equatable {
    public let mode: String
    public let path: String?
    public let reason: String?
    public let layer: String?
    public let scope: String?
}

public struct HVFContainerCachePlan: Codable, Sendable, Equatable {
    public let scope: String?
    public let uid: UInt32?
    public let gid: UInt32?
    public let home: String?
    public let reason: String?
    public let policyDigest: String?
    public let tools: [String: HVFContainerCacheTool]?
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
    public func explainContainerCache(_ container: String, timeout: Duration = .seconds(5)) async throws
        -> HVFContainerCacheExplain
    {
        try ensureSocketReachable()
        let encoded = container.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? container
        let resp = try await docker.request("GET", "/containers/\(encoded)/json", timeout: timeout)
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
