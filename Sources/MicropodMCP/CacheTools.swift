import Foundation
import MicropodCore

/// The HVF machine's cache and rig tools: each is one request to the API
/// daemon (`/v1/caches…`, `/v1/rig…`), which owns the machine.
enum CacheTools {
    static let names: Set<String> = [
        "cache_status", "cache_explain", "cache_dedupe", "cache_prune", "cache_policy", "cache_policy_set",
        "runtime_mode", "rig_health", "update_hvf_status", "update_hvf_rollback",
    ]

    static func call(_ name: String, _ args: MCPArguments, api: LocalAPI) async throws -> String {
        switch name {
        case "cache_status":
            return try await api.callRaw("GET", "/v1/caches")
        case "cache_explain":
            let id = try LocalAPI.pathSegment(args.string("id"), name: "id")
            return try await api.callRaw("GET", "/v1/caches/explain/\(id)")
        case "cache_dedupe":
            return try await api.callRaw("GET", "/v1/caches/dedupe?buckets=\(args.integer("buckets") ?? 16)")
        case "cache_prune":
            return try await api.callRaw("POST", "/v1/caches/prune", try pruneBody(args), timeout: api.longCallSeconds)
        case "cache_policy":
            return try await api.callRaw("GET", "/v1/caches/policy")
        case "cache_policy_set":
            return try await api.callRaw("PUT", "/v1/caches/policy", try policyPatch(args))
        case "runtime_mode":
            guard let mode = args.optionalString("mode") else { return try await api.callRaw("GET", "/v1/rig/mode") }
            return try await api.callRaw("PUT", "/v1/rig/mode", ["mode": mode])
        case "rig_health":
            return try await api.callRaw("GET", "/v1/rig/health")
        case "update_hvf_status":
            return try await api.callRaw("GET", "/v1/rig/hvf/update")
        case "update_hvf_rollback":
            // Deferred (409) or a failed rollback boot (500) is a tool error.
            let body: [String: Any] = args.flag("force") ? ["force": true] : [:]
            return try await api.callRaw(
                "POST", "/v1/rig/hvf/update/rollback", body, timeout: api.longCallSeconds)
        default:
            throw MicropodError.message("\(name) is not a cache tool")
        }
    }

    /// `POST /v1/caches/prune`'s body. A prune is a dry run unless the call
    /// says `apply: true`, and an apply that names no scope, tool, budget or
    /// age — a sweep of every idle unit in every scope — also needs `all: true`.
    static func pruneBody(_ args: MCPArguments) throws -> [String: Any] {
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
        var body: [String: Any] = ["dryRun": !apply, "reason": "mcp"]
        if let scope = args.optionalString("scope") { body["scope"] = scope }
        if let tool = args.optionalString("tool") { body["tool"] = tool }
        if let maxBytes = args.bytes("max_bytes") {
            guard maxBytes > 0 else { throw refuse("max_bytes must be positive (it is the size to prune down to)") }
            body["maxBytes"] = maxBytes
        }
        if let older = args.integer("older_than_secs") {
            guard older > 0 else { throw refuse("older_than_secs must be positive") }
            body["olderThanSecs"] = older
        }
        if let partial = args.bool("partial_go_build") { body["partialGoBuild"] = partial }
        if args.flag("all") { body["all"] = true }
        let selected = ["scope", "tool", "maxBytes", "olderThanSecs"].contains { body[$0] != nil }
        if apply, !selected, !args.flag("all") {
            throw refuse(
                "apply with no scope, tool, max_bytes or older_than_secs evicts every idle cache unit in every "
                    + "scope; pass all: true to confirm (nothing was pruned)")
        }
        return body
    }

    /// `PUT /v1/caches/policy`'s body: only the settings the call names. A
    /// call naming none is refused rather than sent as an empty write.
    ///
    /// For go_proxy, npm_registry and default_scope an explicit `""` is a
    /// clear (as REST and earlier releases read it), like "off"/"none" —
    /// never silently dropped while another setting is written.
    static func policyPatch(_ args: MCPArguments) throws -> [String: Any] {
        /// "off" and "none" clear a URL, as `micropod cache policy` reads them.
        func url(_ raw: String) -> String { ["off", "none"].contains(raw.lowercased()) ? "" : raw }
        var body: [String: Any] = [:]
        if let mode = args.optionalString("mode") { body["mode"] = mode }
        if let shared = args.bool("shared_l0") { body["sharedL0"] = shared }
        if let trust = args.optionalString("default_trust") { body["defaultTrust"] = trust }
        if let proxy = args.bool("proxy_untrusted") { body["proxyUntrusted"] = proxy }
        if let goProxy = args.optionalString("go_proxy") {
            body["goProxy"] = url(goProxy)
        } else if args.isEmptyString("go_proxy") {
            body["goProxy"] = ""
        }
        if let registry = args.optionalString("npm_registry") {
            body["npmRegistry"] = url(registry)
        } else if args.isEmptyString("npm_registry") {
            body["npmRegistry"] = ""
        }
        if let scope = args.optionalString("default_scope") {
            body["defaultScope"] = scope == "none" ? "" : scope
        } else if args.isEmptyString("default_scope") {
            body["defaultScope"] = ""
        }
        if let maxBytes = args.bytes("max_bytes") { body["maxBytes"] = maxBytes }
        if let days = args.integer("max_age_days") { body["maxAgeDays"] = days }
        guard !body.isEmpty else {
            throw MCPArgumentError(
                message: "cache_policy_set: name at least one setting to change (mode, shared_l0, default_trust, "
                    + "proxy_untrusted, go_proxy, npm_registry, default_scope, max_bytes, max_age_days); "
                    + "nothing was written")
        }
        return body
    }
}
