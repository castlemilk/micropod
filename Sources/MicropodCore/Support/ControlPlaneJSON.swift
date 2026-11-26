import Foundation
import SwiftProtobuf

/// The REST JSON shape of the control-plane messages (CacheService,
/// RigService, TelemetryService, the sandbox and runtime-dependency
/// reports), for a client that reads them over binary Connect but shows
/// what the REST twin shows — the MCP server. Each rendering carries the
/// keys and value types of the REST route's body: present where REST
/// writes them, absent where REST leaves an unset optional out, numbers as
/// JSON numbers (never proto-JSON's quoted 64-bit integers), false and zero
/// kept. MicropodAPITests checks every one against its REST route.
public enum ControlPlaneJSON {
    /// `object` as text, keys sorted, slashes unescaped (as REST writes them).
    public static func text(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pretty-printed `text(_:)`.
    public static func prettyText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: JSON values

    /// A JSON value as `google.protobuf.Value` (numbers are doubles in both).
    public static func value(_ json: JSONValue) -> Google_Protobuf_Value {
        switch json {
        case .string(let text): return Google_Protobuf_Value(stringValue: text)
        case .number(let number): return Google_Protobuf_Value(numberValue: number)
        case .bool(let flag): return Google_Protobuf_Value(boolValue: flag)
        case .null: return Google_Protobuf_Value(nilLiteral: ())
        case .array(let items): return Google_Protobuf_Value(listValue: .init(values: items.map(value)))
        case .object(let fields): return Google_Protobuf_Value(structValue: structValue(fields))
        }
    }

    public static func structValue(_ fields: [String: JSONValue]) -> Google_Protobuf_Struct {
        Google_Protobuf_Struct(fields: fields.mapValues(value))
    }

    /// `google.protobuf.Value` back as a JSON value.
    public static func jsonValue(_ value: Google_Protobuf_Value) -> JSONValue {
        switch value.kind {
        case .stringValue(let text): return .string(text)
        case .numberValue(let number): return .number(number)
        case .boolValue(let flag): return .bool(flag)
        case .nullValue, nil: return .null
        case .listValue(let list): return .array(list.values.map(jsonValue))
        case .structValue(let object): return .object(object.fields.mapValues(jsonValue))
        }
    }

    public static func jsonFields(_ value: Google_Protobuf_Struct) -> [String: JSONValue] {
        value.fields.mapValues(jsonValue)
    }

    /// A JSON value as a Foundation object for JSONSerialization.
    public static func foundation(_ json: JSONValue) -> Any {
        switch json {
        case .string(let text): return text
        case .number(let number):
            // An integral double prints as an integer, as JSONEncoder writes it.
            if number.rounded() == number, abs(number) < 9.007_199_254_740_992e15 { return Int64(number) }
            return number
        case .bool(let flag): return flag
        case .null: return NSNull()
        case .array(let items): return items.map(foundation)
        case .object(let fields): return fields.mapValues(foundation)
        }
    }

    // MARK: Caches

    /// `HVFMachineCachePolicy.encode(to:)`: off flags and unset limits are
    /// left out; unknown keys follow at the top level.
    public static func policy(_ p: Micropod_V1_CachePolicy) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in p.extra.fields { out[key] = foundation(jsonValue(value)) }
        out["version"] = Int(p.version)
        out["mode"] = p.mode
        out["defaultScope"] = p.defaultScope
        out["allowedScopes"] = p.allowedScopes
        out["tools"] = p.tools
        out["goTrimpath"] = p.goTrimpath
        out["pnpmLegacyEnv"] = p.pnpmLegacyEnv
        if p.sharedL0 { out["sharedL0"] = true }
        if p.hasGoProxy, !p.goProxy.isEmpty { out["goProxy"] = p.goProxy }
        if p.hasNpmRegistry, !p.npmRegistry.isEmpty { out["npmRegistry"] = p.npmRegistry }
        if p.hasMaxBytes, p.maxBytes > 0 { out["maxBytes"] = p.maxBytes }
        if p.hasMaxAgeDays, p.maxAgeDays > 0 { out["maxAgeDays"] = Int(p.maxAgeDays) }
        if p.hasMinFreeBytes, p.minFreeBytes > 0 { out["minFreeBytes"] = p.minFreeBytes }
        if p.hasDefaultTrust { out["defaultTrust"] = p.defaultTrust }
        if p.proxyUntrusted { out["proxyUntrusted"] = true }
        var buildkit: [String: Any] = [:]
        for (key, value) in p.buildkit.extra.fields { buildkit[key] = foundation(jsonValue(value)) }
        buildkit["registerBuildx"] = p.buildkit.registerBuildx
        out["buildkit"] = buildkit
        return out
    }

    public static func unit(_ u: Micropod_V1_CacheUnit) -> [String: Any] {
        var out: [String: Any] = [
            "scope": u.scope, "kind": u.kind, "unit": u.unit, "layer": u.layer, "path": u.path, "bytes": u.bytes,
            "logicalBytes": u.logicalBytes, "files": u.files, "lastUsedUnix": u.lastUsedUnix, "inUse": u.inUse,
        ]
        if u.hasUid { out["uid"] = u.uid }
        if u.hasDirty { out["dirty"] = u.dirty }
        return out
    }

    public static func totals(_ t: Micropod_V1_CacheTotals) -> [String: Any] {
        var out: [String: Any] = [
            "totalBytes": t.totalBytes, "logicalBytes": t.logicalBytes, "totalFiles": t.totalFiles,
            "scopeCount": Int(t.scopeCount), "unitCount": Int(t.unitCount), "inUseCount": Int(t.inUseCount),
            "l0Bytes": t.l0Bytes, "l1Bytes": t.l1Bytes,
        ]
        if t.hasDirtyCount { out["dirtyCount"] = Int(t.dirtyCount) }
        return out
    }

    public static func budget(_ b: Micropod_V1_CacheBudget) -> [String: Any] {
        var out: [String: Any] = [
            "maxBytes": b.maxBytes, "minFreeBytes": b.minFreeBytes, "maxAgeDays": Int(b.maxAgeDays),
        ]
        if b.hasUtilizationPct { out["utilizationPct"] = b.utilizationPct }
        return out
    }

    public static func evictions(_ e: Micropod_V1_CacheEvictions) -> [String: Any] {
        var out: [String: Any] = [
            "evictions": e.evictions, "evictedUnits": e.evictedUnits, "evictedFiles": e.evictedFiles,
            "evictedBytes": e.evictedBytes,
        ]
        if e.hasLastSweepUnix { out["lastSweepUnix"] = e.lastSweepUnix }
        if e.hasLastSweepReason { out["lastSweepReason"] = e.lastSweepReason }
        return out
    }

    public static func cacheDisk(_ d: Micropod_V1_CacheDisk) -> [String: Any] {
        var out: [String: Any] = ["mounted": d.mounted]
        if d.hasState { out["state"] = d.state }
        if d.hasDevice { out["device"] = d.device }
        if d.hasMountInfoError { out["mountInfoError"] = d.mountInfoError }
        if d.hasSizeBytes { out["sizeBytes"] = d.sizeBytes }
        if d.hasFreeBytes { out["freeBytes"] = d.freeBytes }
        return out
    }

    /// GET /v1/caches.
    public static func status(_ s: Micropod_V1_CacheStatus) -> [String: Any] {
        var out: [String: Any] = [
            "root": s.root, "mountPoint": s.mountPoint, "policyDigest": s.policyDigest,
            "scopes": s.scopes.mapValues(\.units), "units": s.units.map(unit),
        ]
        if s.hasMountL0Point { out["mountL0Point"] = s.mountL0Point }
        if s.hasPolicy { out["policy"] = policy(s.policy) }
        if s.hasTotals { out["totals"] = totals(s.totals) }
        if s.hasBudget { out["budget"] = budget(s.budget) }
        if s.hasEvictions { out["evictions"] = evictions(s.evictions) }
        if !s.discardedAtStart.isEmpty { out["discardedAtStart"] = s.discardedAtStart }
        if !s.keptAtStart.isEmpty { out["keptAtStart"] = s.keptAtStart }
        if s.hasCacheDisk { out["cacheDisk"] = cacheDisk(s.cacheDisk) }
        if s.hasUnavailable { out["unavailable"] = s.unavailable }
        return out
    }

    /// GET /v1/caches/dedupe.
    public static func dedupe(_ d: Micropod_V1_CacheDedupeSample) -> [String: Any] {
        [
            "scopesSampled": d.scopesSampled, "bucketsSampled": Int(d.bucketsSampled),
            "totalObjects": d.totalObjects, "uniqueObjects": d.uniqueObjects,
            "duplicateObjects": d.duplicateObjects, "duplicateBytes": d.duplicateBytes,
            "estimatedFullDuplicateBytes": d.estimatedFullDuplicateBytes,
        ]
    }

    /// POST /v1/caches/prune.
    public static func prune(_ r: Micropod_V1_PruneCachesResponse) -> [String: Any] {
        var out: [String: Any] = [
            "dryRun": r.dryRun, "reason": r.reason, "freedBytes": r.freedBytes, "freedFiles": r.freedFiles,
            "evictedUnits": r.evictedUnits, "skippedInUse": r.skippedInUse, "beforeBytes": r.beforeBytes,
            "afterBytes": r.afterBytes,
            "actions": r.actions.map { a -> [String: Any] in
                var action: [String: Any] = ["scope": a.scope, "unit": a.unit, "action": a.action, "bytes": a.bytes]
                if a.hasFiles { action["files"] = a.files }
                return action
            },
        ]
        if r.hasSkippedDirty { out["skippedDirty"] = r.skippedDirty }
        return out
    }

    /// PUT /v1/caches/policy: the saved policy, plus `warnings` when any.
    public static func policyUpdate(_ r: Micropod_V1_SetCachePolicyResponse) -> [String: Any] {
        var out = policy(r.policy)
        if !r.warnings.isEmpty { out["warnings"] = r.warnings }
        return out
    }

    /// GET /v1/caches/explain/{id}.
    public static func explain(_ e: Micropod_V1_ContainerCacheExplain) -> [String: Any] {
        var out: [String: Any] = [
            "containerId": e.containerID, "containerName": e.containerName, "image": e.image, "state": e.state,
        ]
        guard e.hasCache else { return out }
        let c = e.cache
        var plan: [String: Any] = [:]
        if c.hasScope { plan["scope"] = c.scope }
        if c.hasUid { plan["uid"] = c.uid }
        if c.hasGid { plan["gid"] = c.gid }
        if c.hasHome { plan["home"] = c.home }
        if c.hasReason { plan["reason"] = c.reason }
        if c.hasPolicyDigest { plan["policyDigest"] = c.policyDigest }
        if c.hasTrust { plan["trust"] = c.trust }
        if c.hasTrustFrom { plan["trustFrom"] = c.trustFrom }
        if c.toolsReported {
            plan["tools"] = c.tools.mapValues { t -> [String: Any] in
                var tool: [String: Any] = ["mode": t.mode]
                if t.hasPath { tool["path"] = t.path }
                if t.hasReason { tool["reason"] = t.reason }
                if t.hasLayer { tool["layer"] = t.layer }
                if t.hasScope { tool["scope"] = t.scope }
                if t.hasAccess { tool["access"] = t.access }
                return tool
            }
        }
        if c.proxyReported { plan["proxy"] = c.proxy }
        out["cache"] = plan
        return out
    }

    // MARK: Rig

    /// GET /v1/rig/mode (PUT leaves out `modes`).
    public static func rigMode(_ m: Micropod_V1_RigMode) -> [String: Any] {
        var out: [String: Any] = ["mode": m.mode, "defaultRuntime": m.defaultRuntime]
        if !m.modes.isEmpty {
            out["modes"] = m.modes.map { ["name": $0.name, "engine": $0.engine, "summary": $0.summary] }
        }
        return out
    }

    public static func rigCacheDisk(_ d: Micropod_V1_RigCacheDisk) -> [String: Any] {
        var out: [String: Any] = [
            "mounted": d.mounted, "configured": d.configured, "source": d.source, "sharedCaches": d.sharedCaches,
            "summary": d.summary,
        ]
        if d.hasMissing { out["missing"] = d.missing }
        if d.hasReason { out["reason"] = d.reason }
        if d.hasState { out["state"] = d.state }
        if d.hasDevice { out["device"] = d.device }
        if d.hasMountInfoError { out["mountInfoError"] = d.mountInfoError }
        if d.hasSizeBytes { out["sizeBytes"] = d.sizeBytes }
        if d.hasFreeBytes { out["freeBytes"] = d.freeBytes }
        if d.hasUnavailable { out["unavailable"] = d.unavailable }
        return out
    }

    /// GET /v1/rig/health.
    public static func rigHealth(_ h: Micropod_V1_RigHealth) -> [String: Any] {
        var out: [String: Any] = [
            "mode": h.mode, "defaultRuntime": h.defaultRuntime,
            "hvf": [
                "installed": h.hvf.installed, "phase": h.hvf.phase, "summary": h.hvf.summary, "root": h.hvf.root,
                "dockerEndpoint": h.hvf.dockerEndpoint, "cacheDiskPresent": h.hvf.cacheDiskPresent,
                "cacheDisk": rigCacheDisk(h.hvf.cacheDisk), "sharedCaches": h.hvf.sharedCaches,
                "updatePending": h.hvf.updatePending, "payloadVersion": h.hvf.payloadVersion,
            ] as [String: Any],
            "cachePolicy": [
                "mode": h.cachePolicy.mode, "sharedL0": h.cachePolicy.sharedL0,
                "defaultTrust": h.cachePolicy.defaultTrust, "goProxy": h.cachePolicy.goProxy,
                "toolCount": Int(h.cachePolicy.toolCount),
            ] as [String: Any],
            "depproxy": ["url": h.depproxy.url, "healthy": h.depproxy.healthy] as [String: Any],
        ]
        if h.hasConfigError { out["configError"] = h.configError }
        return out
    }

    public static func manifest(_ m: Micropod_V1_HVFPayloadManifest) -> [String: Any] {
        var out: [String: Any] = [
            "schema": Int(m.schema), "version": m.version, "revision": m.revision, "installedAt": m.installedAt,
            "digests": m.digests,
        ]
        if m.hasOrigin { out["origin"] = m.origin }
        return out
    }

    /// GET /v1/rig/hvf/update.
    public static func updateStatus(_ s: Micropod_V1_HVFUpdateStatus) -> [String: Any] {
        var out: [String: Any] = ["updatePending": s.updatePending, "availableVersions": s.availableVersions]
        if s.hasCurrentPath { out["currentPath"] = s.currentPath }
        if s.hasPreviousPath { out["previousPath"] = s.previousPath }
        if s.hasStagedPath { out["stagedPath"] = s.stagedPath }
        if s.hasKnownGoodPath { out["knownGoodPath"] = s.knownGoodPath }
        if s.hasCurrent { out["current"] = manifest(s.current) }
        if s.hasPrevious { out["previous"] = manifest(s.previous) }
        if s.hasStaged { out["staged"] = manifest(s.staged) }
        if s.hasKnownGood { out["knownGood"] = manifest(s.knownGood) }
        if s.hasRunningPath { out["runningPath"] = s.runningPath }
        if s.hasRunningVersion { out["runningVersion"] = s.runningVersion }
        if s.hasRunningRevision { out["runningRevision"] = s.runningRevision }
        if s.hasLastActivationFailure { out["lastActivationFailure"] = s.lastActivationFailure }
        return out
    }

    /// POST /v1/rig/hvf/update/rollback's 200 body (an activation's too).
    public static func updateResult(_ r: Micropod_V1_HVFUpdateResult) -> [String: Any] {
        var out: [String: Any] = [
            "action": r.action, "activeContainers": Int(r.activeContainers), "detail": r.detail,
        ]
        if r.hasFromVersion { out["fromVersion"] = r.fromVersion }
        if r.hasToVersion { out["toVersion"] = r.toVersion }
        if r.hasTargetVersion { out["targetVersion"] = r.targetVersion }
        if r.hasSwitchoverMilliseconds { out["switchoverMilliseconds"] = r.switchoverMilliseconds }
        return out
    }

    /// The machine status (`micropod machine status`'s facts).
    public static func machineStatus(_ s: Micropod_V1_HVFMachineStatus) -> [String: Any] {
        var out: [String: Any] = [
            "root": s.root, "socket": s.socket, "missing": s.missing, "installed": s.installed,
            "supervisorAlive": s.supervisorAlive, "phase": s.phase, "updatePending": s.updatePending,
            "summary": s.summary, "stoppedOnRequest": s.stoppedOnRequest,
        ]
        if s.hasProblem { out["problem"] = s.problem }
        if s.hasStateError { out["stateError"] = s.stateError }
        if s.hasState {
            let st = s.state
            var state: [String: Any] = [
                "phase": st.phase, "supervisorPID": Int(st.supervisorPid), "restartCount": Int(st.restartCount),
                "updatedAt": st.updatedAt,
            ]
            if st.hasVmmPid { state["vmmPID"] = Int(st.vmmPid) }
            if st.hasStartedAt { state["startedAt"] = st.startedAt }
            if st.hasReadyAt { state["readyAt"] = st.readyAt }
            if st.hasLastExitReason { state["lastExitReason"] = st.lastExitReason }
            if st.hasLastExitCode { state["lastExitCode"] = Int(st.lastExitCode) }
            if st.hasLoadedPayloadPath { state["loadedPayloadPath"] = st.loadedPayloadPath }
            if st.hasLoadedPayloadVersion { state["loadedPayloadVersion"] = st.loadedPayloadVersion }
            out["state"] = state
        }
        return out
    }

    // MARK: Telemetry

    public static func telemetryHealth(_ h: Micropod_V1_TelemetryHealth) -> [String: Any] {
        let e = h.engine
        var out: [String: Any] = [
            "verdict": h.verdict, "warnings": h.warnings, "timestamp": h.timestamp,
            "engine": [
                "vmm": e.vmm, "engine": e.engine, "engineVersion": e.engineVersion, "cpus": Int(e.cpus),
                "memoryBytes": e.memoryBytes, "storageDriver": e.storageDriver, "cgroupDriver": e.cgroupDriver,
                "buildkitAvailable": e.buildkitAvailable, "worker": e.worker, "instance": e.instance, "boot": e.boot,
            ] as [String: Any],
            "workloads": ["runningCount": Int(h.workloads.runningCount), "totalCount": Int(h.workloads.totalCount)],
            "hypervisorReported": h.hypervisorReported, "kernelReported": h.kernelReported,
        ]
        if h.hasCacheTotals { out["cacheTotals"] = totals(h.cacheTotals) }
        return out
    }

    public static func telemetryIssues(_ i: Micropod_V1_TelemetryIssues) -> [String: Any] {
        [
            "verdict": i.verdict, "warnings": i.warnings,
            "recentIssues": i.issues.map { issue -> [String: Any] in
                var out: [String: Any] = [
                    "tsUnixNs": issue.tsUnixNs, "kind": issue.kind, "source": issue.source, "method": issue.method,
                    "route": issue.route, "status": Int(issue.status), "durationMs": issue.durationMs,
                ]
                if issue.hasMessage { out["message"] = issue.message }
                return out
            },
        ]
    }

    // MARK: Sandbox and the Apple runtime

    /// `micropod sandbox status --json`.
    public static func sandboxStatus(_ s: Micropod_V1_SandboxStatus) -> [String: Any] {
        var out: [String: Any] = [
            "root": s.root, "kernelOrigin": s.kernelOrigin, "vminit": s.vminit, "contentOrigin": s.contentOrigin,
            "contentPath": s.contentPath, "initfsPaths": s.initfsPaths, "standaloneReady": s.standaloneReady,
        ]
        if s.hasKernelPath { out["kernelPath"] = s.kernelPath }
        if s.hasKernelSource {
            out["kernelSource"] = [
                "origin": s.kernelSource.origin, "path": s.kernelSource.path, "sha256": s.kernelSource.sha256,
            ]
        }
        return out
    }

    /// GET /v1/system/dependency (`RuntimeDependencyStatus`'s keys).
    public static func runtimeDependency(_ d: Micropod_V1_RuntimeDependency) -> [String: Any] {
        [
            "state": d.state, "cliPath": d.cliPath, "cliVersion": d.cliVersion,
            "cliVersionSupported": d.cliVersionSupported, "apiServerVersion": d.apiServerVersion,
            "backend": d.backend, "runtimeInstallRoot": d.runtimeInstallRoot,
            "maintenanceBlocked": d.maintenanceBlocked, "message": d.message, "nextAction": d.nextAction,
            "installerURL": d.installerURL,
        ]
    }
}
