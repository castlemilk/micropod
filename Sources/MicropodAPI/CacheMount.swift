import Foundation
import MicropodCore
import MicropodRuntime
import SwiftProtobuf

/// CacheService, and the code the REST routes under `/v1/caches` share with
/// it: one guest read, one validation path. An RPC request is turned into the
/// JSON body its REST twin takes and checked by the same function, so a
/// request one refuses the other refuses with the same words.
extension APIHandlers {
    /// Dispatches a CacheService method; nil for any other name.
    func cacheRPC(_ method: String, _ body: Data, binary: Bool) async throws -> HTTPResponse? {
        do {
            switch method {
            case "GetCacheStatus":
                let req = try decode(Micropod_V1_GetCacheStatusRequest.self, body, binary: binary)
                let inspection = try await cacheInspection(includeStats: req.hasIncludeStats ? req.includeStats : true)
                return unary(CacheProto.status(inspection), binary: binary)

            case "ListCacheUnits":
                let req = try decode(Micropod_V1_ListCacheUnitsRequest.self, body, binary: binary)
                let filter = try CacheUnitFilter(scope: req.scope, layer: req.layer, tool: req.tool)
                let inspection = try await cacheInspection(includeStats: true)
                return unary(
                    Micropod_V1_ListCacheUnitsResponse.with {
                        $0.units = (inspection.units ?? []).filter(filter.matches).map(CacheProto.unit)
                        $0.policyDigest = inspection.policyDigest
                    }, binary: binary)

            case "ExplainContainerCache":
                let req = try decode(Micropod_V1_ContainerRef.self, body, binary: binary)
                return unary(CacheProto.explain(try await explainCache(req.id)), binary: binary)

            case "SampleCacheDedupe":
                let req = try decode(Micropod_V1_SampleCacheDedupeRequest.self, body, binary: binary)
                guard req.buckets <= 256 else {
                    throw ConnectDecodeError(code: .invalidArgument, message: "buckets must be at most 256")
                }
                let sample = try await cacheDedupe(buckets: req.buckets == 0 ? 16 : Int(req.buckets))
                return unary(CacheProto.dedupe(sample), binary: binary)

            case "PruneCaches":
                let req = try decode(Micropod_V1_PruneCachesRequest.self, body, binary: binary)
                return unary(CacheProto.prune(try await pruneCaches(body: Self.pruneBody(req))), binary: binary)

            case "GetCachePolicy":
                return unary(CacheProto.policy(try cachePolicyInForce()), binary: binary)

            case "SetCachePolicy":
                let req = try decode(Micropod_V1_SetCachePolicyRequest.self, body, binary: binary)
                let saved = try setCachePolicy(body: Self.policyPatchBody(req))
                return unary(
                    Micropod_V1_SetCachePolicyResponse.with {
                        $0.policy = CacheProto.policy(saved.policy)
                        $0.warnings = saved.warnings
                    }, binary: binary)

            default:
                return nil
            }
        } catch let error as BadRequest {
            throw ConnectDecodeError(code: .invalidArgument, message: error.message)
        }
    }

    // MARK: Shared with REST

    func cacheInspection(includeStats: Bool) async throws -> HVFCacheInspection {
        try await hvfMachineClient().cacheInspection(includeStats: includeStats)
    }

    func cacheDedupe(buckets: Int) async throws -> HVFCacheDedupeSample {
        try await hvfMachineClient().cacheDedupe(buckets: max(1, min(256, buckets)))
    }

    /// `POST /v1/caches/prune`'s body, validated (`cachePruneRequest`), then
    /// sent to the guest.
    func pruneCaches(body: Data) async throws -> HVFCachePruneResult {
        let request = try Self.cachePruneRequest(body)
        return try await hvfMachineClient().cachePrune(request)
    }

    /// A machine.json that does not load is an error, never the defaults
    /// presented as the policy in force.
    func cachePolicyInForce() throws -> HVFMachineCachePolicy {
        try HVFMachineConfig.load(from: hvfMachineClient().layout.config).effectiveCachePolicy
    }

    /// `PUT /v1/caches/policy`'s body: checked before machine.json is read,
    /// and machine.json must read cleanly (a config that fails to load is an
    /// error, never replaced by the defaults). Saves machine.json and renders
    /// the guest's copy, which a running guest picks up live.
    func setCachePolicy(body: Data) throws -> HVFCachePolicyUpdateResponse {
        let patch = try RequestFields(body, allowed: Self.cachePolicyFields, what: "cache policy")
        guard !patch.namesNothing(clearable: Self.cachePolicyClearableFields) else {
            throw BadRequest(
                message: "cache policy: name at least one field to change "
                    + "(\(Self.cachePolicyFields.sorted().joined(separator: ", "))); nothing was written")
        }
        let client = hvfMachineClient()
        let layout = client.layout
        if layout.installInProgress { throw layout.installInProgressError() }
        var cfg = try HVFMachineConfig.load(from: layout.config)
        let policy = try Self.cachePolicy(cfg.effectiveCachePolicy, patchedWith: patch)
        cfg.cache = policy
        try cfg.save(to: layout.config)
        try HVFMachineCachePolicy.write(policy, layout: layout)
        // The saved policy, plus `warnings` when a policy URL opens no host
        // port or names one the running machine has not opened.
        return HVFCachePolicyUpdateResponse(saved: cfg, client: client)
    }

    func explainCache(_ container: String) async throws -> HVFContainerCacheExplain {
        guard container.range(of: HVFMachineClient.containerReference, options: .regularExpression) != nil else {
            throw BadRequest(message: "cache explain: '\(container)' is not a container id or name")
        }
        return try await hvfMachineClient().explainContainerCache(container)
    }

    // MARK: RPC requests as REST bodies

    /// PruneCachesRequest as `POST /v1/caches/prune`'s body: `apply` false
    /// (the default) is `"dryRun": true`.
    static func pruneBody(_ req: Micropod_V1_PruneCachesRequest) -> Data {
        var body: [String: Any] = ["dryRun": !req.apply, "reason": req.hasReason ? req.reason : "api"]
        if req.all { body["all"] = true }
        if req.hasScope { body["scope"] = req.scope }
        if req.hasTool { body["tool"] = req.tool }
        if req.hasOlderThanSecs { body["olderThanSecs"] = req.olderThanSecs }
        if req.hasMaxBytes { body["maxBytes"] = req.maxBytes }
        if req.hasPartialGoBuild { body["partialGoBuild"] = req.partialGoBuild }
        if req.hasSafetyCutoffSecs { body["safetyCutoffSecs"] = req.safetyCutoffSecs }
        if req.hasMaxUnits { body["maxUnits"] = req.maxUnits }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    /// SetCachePolicyRequest as `PUT /v1/caches/policy`'s body: the fields
    /// set, and nothing else ("" and 0 clear, as `null` does over REST).
    static func policyPatchBody(_ req: Micropod_V1_SetCachePolicyRequest) -> Data {
        var body: [String: Any] = [:]
        if req.hasMode { body["mode"] = req.mode }
        if req.hasDefaultScope { body["defaultScope"] = req.defaultScope }
        if req.hasAllowedScopes { body["allowedScopes"] = req.allowedScopes.values }
        if req.hasTools { body["tools"] = req.tools.values }
        if req.hasGoTrimpath { body["goTrimpath"] = req.goTrimpath }
        if req.hasPnpmLegacyEnv { body["pnpmLegacyEnv"] = req.pnpmLegacyEnv }
        if req.hasSharedL0 { body["sharedL0"] = req.sharedL0 }
        if req.hasDefaultTrust { body["defaultTrust"] = req.defaultTrust }
        if req.hasProxyUntrusted { body["proxyUntrusted"] = req.proxyUntrusted }
        if req.hasGoProxy { body["goProxy"] = req.goProxy }
        if req.hasNpmRegistry { body["npmRegistry"] = req.npmRegistry }
        if req.hasMaxBytes { body["maxBytes"] = req.maxBytes }
        if req.hasMaxAgeDays { body["maxAgeDays"] = req.maxAgeDays }
        if req.hasMinFreeBytes { body["minFreeBytes"] = req.minFreeBytes }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }
}

/// ListCacheUnits' selection: empty fields select everything.
struct CacheUnitFilter {
    let scope: String
    let layer: String
    let kinds: Set<String>?

    init(scope: String, layer: String, tool: String) throws {
        guard ["", "L0", "L1"].contains(layer) else {
            throw ConnectDecodeError(code: .invalidArgument, message: "layer must be L0 or L1, got '\(layer)'")
        }
        if !scope.isEmpty, !HVFMachineCachePolicy.isValidScope(scope) {
            throw ConnectDecodeError(
                code: .invalidArgument, message: "scope '\(scope)' must match ^[a-z0-9][a-z0-9_-]{0,62}$")
        }
        self.scope = scope
        self.layer = layer
        if tool.isEmpty {
            kinds = nil
        } else {
            guard let normalized = try? HVFMachineCachePolicy.normalizedTools([tool]) else {
                throw ConnectDecodeError(
                    code: .invalidArgument,
                    message:
                        "unknown tool '\(tool)' (known: \(HVFMachineCachePolicy.toolNames.joined(separator: ", ")))")
            }
            kinds = Set(normalized)
        }
    }

    func matches(_ unit: HVFCacheUnitUsage) -> Bool {
        (scope.isEmpty || unit.scope == scope) && (layer.isEmpty || unit.layer == layer)
            && (kinds.map { $0.contains(unit.kind) } ?? true)
    }
}

/// The runtime library's cache models as CacheService messages. Lossless
/// for everything REST encodes, so `ControlPlaneJSON` renders the REST body
/// back from them.
enum CacheProto {
    static func status(_ s: HVFCacheInspection) -> Micropod_V1_CacheStatus {
        .with {
            $0.root = s.root
            $0.mountPoint = s.mountPoint
            if let l0 = s.mountL0Point { $0.mountL0Point = l0 }
            if let policy = s.policy { $0.policy = Self.policy(policy) }
            $0.policyDigest = s.policyDigest
            $0.scopes = s.scopes.mapValues { units in .with { $0.units = units } }
            $0.units = (s.units ?? []).map(unit)
            if let t = s.totals { $0.totals = totals(t) }
            if let b = s.budget {
                $0.budget = .with {
                    $0.maxBytes = b.maxBytes
                    $0.minFreeBytes = b.minFreeBytes
                    $0.maxAgeDays = Int32(clamping: b.maxAgeDays)
                    if let pct = b.utilizationPct { $0.utilizationPct = pct }
                }
            }
            if let e = s.evictions {
                $0.evictions = .with {
                    $0.evictions = e.evictions
                    $0.evictedUnits = e.evictedUnits
                    $0.evictedFiles = e.evictedFiles
                    $0.evictedBytes = e.evictedBytes
                    if let at = e.lastSweepUnix { $0.lastSweepUnix = at }
                    if let why = e.lastSweepReason { $0.lastSweepReason = why }
                }
            }
            $0.discardedAtStart = s.discardedAtStart ?? []
            $0.keptAtStart = s.keptAtStart ?? []
            if let disk = s.cacheDisk {
                $0.cacheDisk = .with {
                    if let state = disk.state { $0.state = state }
                    if let device = disk.device { $0.device = device }
                    $0.mounted = disk.mounted
                    if let error = disk.mountInfoError { $0.mountInfoError = error }
                    if let size = disk.sizeBytes { $0.sizeBytes = size }
                    if let free = disk.freeBytes { $0.freeBytes = free }
                }
            }
            if let why = s.unavailable { $0.unavailable = why }
        }
    }

    static func unit(_ u: HVFCacheUnitUsage) -> Micropod_V1_CacheUnit {
        .with {
            $0.scope = u.scope
            $0.kind = u.kind
            $0.unit = u.unit
            if let uid = u.uid { $0.uid = uid }
            $0.layer = u.layer
            $0.path = u.path
            $0.bytes = u.bytes
            $0.logicalBytes = u.logicalBytes
            $0.files = u.files
            $0.lastUsedUnix = u.lastUsedUnix
            $0.inUse = u.inUse
            if let dirty = u.dirty { $0.dirty = dirty }
        }
    }

    static func totals(_ t: HVFCacheTotals) -> Micropod_V1_CacheTotals {
        .with {
            $0.totalBytes = t.totalBytes
            $0.logicalBytes = t.logicalBytes
            $0.totalFiles = t.totalFiles
            $0.scopeCount = Int32(clamping: t.scopeCount)
            $0.unitCount = Int32(clamping: t.unitCount)
            $0.inUseCount = Int32(clamping: t.inUseCount)
            $0.l0Bytes = t.l0Bytes
            $0.l1Bytes = t.l1Bytes
            if let dirty = t.dirtyCount { $0.dirtyCount = Int32(clamping: dirty) }
        }
    }

    static func policy(_ p: HVFMachineCachePolicy) -> Micropod_V1_CachePolicy {
        .with {
            $0.version = Int32(clamping: p.version)
            $0.mode = p.mode.rawValue
            $0.defaultScope = p.defaultScope
            $0.allowedScopes = p.allowedScopes
            $0.tools = p.tools
            $0.goTrimpath = p.goTrimpath
            $0.pnpmLegacyEnv = p.pnpmLegacyEnv
            $0.sharedL0 = p.sharedL0
            if let trust = p.defaultTrust { $0.defaultTrust = trust.rawValue }
            $0.proxyUntrusted = p.proxyUntrusted
            if let proxy = p.goProxy { $0.goProxy = proxy }
            if let registry = p.npmRegistry { $0.npmRegistry = registry }
            if let bytes = p.maxBytes { $0.maxBytes = bytes }
            if let days = p.maxAgeDays { $0.maxAgeDays = Int32(clamping: days) }
            if let free = p.minFreeBytes { $0.minFreeBytes = free }
            $0.buildkit = .with {
                $0.registerBuildx = p.buildkit.registerBuildx
                if !p.buildkit.extra.isEmpty { $0.extra = ControlPlaneJSON.structValue(p.buildkit.extra) }
            }
            // Decoding keeps only the keys it does not know in `extra`.
            if !p.extra.isEmpty { $0.extra = ControlPlaneJSON.structValue(p.extra) }
        }
    }

    static func dedupe(_ d: HVFCacheDedupeSample) -> Micropod_V1_CacheDedupeSample {
        .with {
            $0.scopesSampled = d.scopesSampled
            $0.bucketsSampled = Int32(clamping: d.bucketsSampled)
            $0.totalObjects = d.totalObjects
            $0.uniqueObjects = d.uniqueObjects
            $0.duplicateObjects = d.duplicateObjects
            $0.duplicateBytes = d.duplicateBytes
            $0.estimatedFullDuplicateBytes = d.estimatedFullDuplicateBytes
        }
    }

    static func prune(_ r: HVFCachePruneResult) -> Micropod_V1_PruneCachesResponse {
        .with {
            $0.dryRun = r.dryRun
            $0.reason = r.reason
            $0.freedBytes = r.freedBytes
            $0.freedFiles = r.freedFiles
            $0.evictedUnits = r.evictedUnits
            $0.skippedInUse = r.skippedInUse
            $0.beforeBytes = r.beforeBytes
            $0.afterBytes = r.afterBytes
            $0.actions = r.actions.map { a in
                .with {
                    $0.scope = a.scope
                    $0.unit = a.unit
                    $0.action = a.action
                    if let files = a.files { $0.files = files }
                    $0.bytes = a.bytes
                }
            }
            if let dirty = r.skippedDirty { $0.skippedDirty = dirty }
        }
    }

    static func explain(_ e: HVFContainerCacheExplain) -> Micropod_V1_ContainerCacheExplain {
        .with {
            $0.containerID = e.containerId
            $0.containerName = e.containerName
            $0.image = e.image
            $0.state = e.state
            guard let c = e.cache else { return }
            $0.cache = .with {
                if let scope = c.scope { $0.scope = scope }
                if let uid = c.uid { $0.uid = uid }
                if let gid = c.gid { $0.gid = gid }
                if let home = c.home { $0.home = home }
                if let reason = c.reason { $0.reason = reason }
                if let digest = c.policyDigest { $0.policyDigest = digest }
                if let tools = c.tools {
                    $0.toolsReported = true
                    $0.tools = tools.mapValues { t in
                        .with {
                            $0.mode = t.mode
                            if let path = t.path { $0.path = path }
                            if let reason = t.reason { $0.reason = reason }
                            if let layer = t.layer { $0.layer = layer }
                            if let scope = t.scope { $0.scope = scope }
                            if let access = t.access { $0.access = access }
                        }
                    }
                }
                if let trust = c.trust { $0.trust = trust }
                if let from = c.trustFrom { $0.trustFrom = from }
                if let proxy = c.proxy {
                    $0.proxyReported = true
                    $0.proxy = proxy
                }
            }
        }
    }
}
