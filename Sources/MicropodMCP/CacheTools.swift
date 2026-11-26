import Foundation
import MicropodCore

/// The HVF machine's cache, rig and telemetry tools: each is one CacheService,
/// RigService or TelemetryService call to the API daemon, which owns the
/// machine. Replies are the JSON the REST twins (`/v1/caches…`, `/v1/rig…`,
/// `/v1/ci…`) answer, rendered from the typed reply (`ControlPlaneJSON`).
enum CacheTools {
    static let names: Set<String> = [
        "cache_status", "cache_ls", "cache_explain", "cache_dedupe", "cache_prune", "cache_policy", "cache_policy_set",
        "runtime_mode", "rig_health", "update_hvf_status", "update_hvf_apply", "update_hvf_rollback",
        "machine_status", "machine_control", "telemetry_health", "telemetry_issues", "telemetry_traces",
    ]

    static func call(_ name: String, _ args: MCPArguments, api: LocalAPI) async throws -> String {
        let empty = Micropod_V1_Empty()
        switch name {
        case "cache_status":
            let status = try await api.unary(
                "CacheService", "GetCacheStatus", Micropod_V1_GetCacheStatusRequest(), as: Micropod_V1_CacheStatus.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.status(status))
        case "cache_ls":
            let units = try await api.unary(
                "CacheService", "ListCacheUnits",
                Micropod_V1_ListCacheUnitsRequest.with {
                    $0.scope = args.optionalString("scope") ?? ""
                    $0.layer = args.optionalString("layer") ?? ""
                    $0.tool = args.optionalString("tool") ?? ""
                }, as: Micropod_V1_ListCacheUnitsResponse.self)
            return ControlPlaneJSON.text([
                "policyDigest": units.policyDigest, "units": units.units.map(ControlPlaneJSON.unit),
            ])
        case "cache_explain":
            let id = args.string("id")
            _ = try LocalAPI.pathSegment(id, name: "id")
            let explain = try await api.unary(
                "CacheService", "ExplainContainerCache", Micropod_V1_ContainerRef.with { $0.id = id },
                as: Micropod_V1_ContainerCacheExplain.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.explain(explain))
        case "cache_dedupe":
            let sample = try await api.unary(
                "CacheService", "SampleCacheDedupe",
                Micropod_V1_SampleCacheDedupeRequest.with { $0.buckets = UInt32(args.integer("buckets") ?? 16) },
                as: Micropod_V1_CacheDedupeSample.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.dedupe(sample))
        case "cache_prune":
            let result = try await api.unary(
                "CacheService", "PruneCaches", try pruneRequest(args), as: Micropod_V1_PruneCachesResponse.self,
                timeout: api.longCallSeconds)
            return ControlPlaneJSON.text(ControlPlaneJSON.prune(result))
        case "cache_policy":
            let policy = try await api.unary("CacheService", "GetCachePolicy", empty, as: Micropod_V1_CachePolicy.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.policy(policy))
        case "cache_policy_set":
            let saved = try await api.unary(
                "CacheService", "SetCachePolicy", try policyPatch(args), as: Micropod_V1_SetCachePolicyResponse.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.policyUpdate(saved))
        case "runtime_mode":
            guard let mode = args.optionalString("mode") else {
                let shown = try await api.unary("RigService", "GetRigMode", empty, as: Micropod_V1_RigMode.self)
                return ControlPlaneJSON.text(ControlPlaneJSON.rigMode(shown))
            }
            var switched = try await api.unary(
                "RigService", "SetRigMode", Micropod_V1_SetRigModeRequest.with { $0.mode = mode },
                as: Micropod_V1_RigMode.self)
            // As PUT /v1/rig/mode answers: the mode and the default it wrote.
            switched.modes = []
            return ControlPlaneJSON.text(ControlPlaneJSON.rigMode(switched))
        case "rig_health":
            let health = try await api.unary("RigService", "GetRigHealth", empty, as: Micropod_V1_RigHealth.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.rigHealth(health))
        case "update_hvf_status":
            let status = try await api.unary(
                "RigService", "GetHVFUpdateStatus", empty, as: Micropod_V1_HVFUpdateStatus.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.updateStatus(status))
        case "update_hvf_rollback", "update_hvf_apply":
            // Deferred (failed_precondition), or a boot that did not take, is
            // a tool error carrying the daemon's detail.
            let result = try await api.unary(
                "RigService", name == "update_hvf_apply" ? "ApplyHVFUpdate" : "RollbackHVFUpdate",
                Micropod_V1_HVFUpdateRequest.with { $0.force = args.flag("force") },
                as: Micropod_V1_HVFUpdateResult.self,
                timeout: api.longCallSeconds)
            return ControlPlaneJSON.text(ControlPlaneJSON.updateResult(result))
        case "machine_status":
            let status = try await api.unary(
                "RigService", "GetMachineStatus", empty, as: Micropod_V1_HVFMachineStatus.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.machineStatus(status))
        case "machine_control":
            let status = try await api.unary(
                "RigService", "ControlMachine",
                Micropod_V1_ControlMachineRequest.with { $0.action = args.string("action") },
                as: Micropod_V1_HVFMachineStatus.self, timeout: api.longCallSeconds)
            return ControlPlaneJSON.text(ControlPlaneJSON.machineStatus(status))
        case "telemetry_health":
            let health = try await api.unary(
                "TelemetryService", "GetTelemetryHealth", empty, as: Micropod_V1_TelemetryHealth.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.telemetryHealth(health))
        case "telemetry_issues":
            let issues = try await api.unary(
                "TelemetryService", "ListTelemetryIssues", empty, as: Micropod_V1_TelemetryIssues.self)
            return ControlPlaneJSON.text(ControlPlaneJSON.telemetryIssues(issues))
        case "telemetry_traces":
            let traces = try await api.unary(
                "TelemetryService", "GetTraces", empty, as: Micropod_V1_TelemetryTraces.self)
            return String(decoding: traces.otlpJson, as: UTF8.self)
        default:
            throw MicropodError.message("\(name) is not a cache, rig or telemetry tool")
        }
    }

    /// PruneCaches' request. A prune is a dry run unless the call says
    /// `apply: true`, and an apply that names no scope, tool, budget or age —
    /// a sweep of every idle unit in every scope — also needs `all: true`.
    static func pruneRequest(_ args: MCPArguments) throws -> Micropod_V1_PruneCachesRequest {
        func refuse(_ detail: String) -> MCPArgumentError { MCPArgumentError(message: "cache_prune: \(detail)") }
        let apply = args.flag("apply")
        switch args.bool("dry_run") {
        case true? where apply:
            throw refuse("dry_run true and apply true contradict each other; nothing was pruned")
        case false? where !apply:
            throw refuse(
                "dry_run false does not evict on its own: pass apply: true to evict (nothing was pruned)")
        default:
            break
        }
        var request = Micropod_V1_PruneCachesRequest()
        request.apply = apply
        request.reason = "mcp"
        if let scope = args.optionalString("scope") { request.scope = scope }
        if let tool = args.optionalString("tool") { request.tool = tool }
        if let maxBytes = args.bytes("max_bytes") {
            guard maxBytes > 0 else { throw refuse("max_bytes must be positive (it is the size to prune down to)") }
            request.maxBytes = maxBytes
        }
        if let older = args.integer("older_than_secs") {
            guard older > 0 else { throw refuse("older_than_secs must be positive") }
            request.olderThanSecs = older
        }
        if let partial = args.bool("partial_go_build") { request.partialGoBuild = partial }
        if args.flag("all") { request.all = true }
        let selected = request.hasScope || request.hasTool || request.hasMaxBytes || request.hasOlderThanSecs
        if apply, !selected, !args.flag("all") {
            throw refuse(
                "apply with no scope, tool, max_bytes or older_than_secs evicts every idle cache unit in every "
                    + "scope; pass all: true to confirm (nothing was pruned)")
        }
        return request
    }

    /// SetCachePolicy's request: only the settings the call names. A call
    /// naming none is refused rather than sent as an empty write.
    ///
    /// For go_proxy, npm_registry and default_scope an explicit `""` is a
    /// clear (as REST and earlier releases read it), like "off"/"none" —
    /// never silently dropped while another setting is written.
    static func policyPatch(_ args: MCPArguments) throws -> Micropod_V1_SetCachePolicyRequest {
        /// "off" and "none" clear a URL, as `micropod cache policy` reads them.
        func url(_ raw: String) -> String { ["off", "none"].contains(raw.lowercased()) ? "" : raw }
        var patch = Micropod_V1_SetCachePolicyRequest()
        var named = false
        if let mode = args.optionalString("mode") {
            patch.mode = mode
            named = true
        }
        if let shared = args.bool("shared_l0") {
            patch.sharedL0 = shared
            named = true
        }
        if let trust = args.optionalString("default_trust") {
            patch.defaultTrust = trust
            named = true
        }
        if let proxy = args.bool("proxy_untrusted") {
            patch.proxyUntrusted = proxy
            named = true
        }
        if let goProxy = args.optionalString("go_proxy") {
            patch.goProxy = url(goProxy)
            named = true
        } else if args.isEmptyString("go_proxy") {
            patch.goProxy = ""
            named = true
        }
        if let registry = args.optionalString("npm_registry") {
            patch.npmRegistry = url(registry)
            named = true
        } else if args.isEmptyString("npm_registry") {
            patch.npmRegistry = ""
            named = true
        }
        if let scope = args.optionalString("default_scope") {
            patch.defaultScope = scope == "none" ? "" : scope
            named = true
        } else if args.isEmptyString("default_scope") {
            patch.defaultScope = ""
            named = true
        }
        if let maxBytes = args.bytes("max_bytes") {
            patch.maxBytes = maxBytes
            named = true
        }
        if let days = args.integer("max_age_days") {
            patch.maxAgeDays = UInt32(clamping: days)
            named = true
        }
        guard named else {
            throw MCPArgumentError(
                message: "cache_policy_set: name at least one setting to change (mode, shared_l0, default_trust, "
                    + "proxy_untrusted, go_proxy, npm_registry, default_scope, max_bytes, max_age_days); "
                    + "nothing was written")
        }
        return patch
    }
}
