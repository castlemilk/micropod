import Foundation
import MicropodCore
import MicropodRuntime

/// Unified `micropod cache …` CLI for live cache visibility, cross-scope
/// deduplication sampling, container cache diagnosis, lock-safe LRU/partial
/// pruning, and L0/L1/proxy/budget policy management.
///
/// Dispatched before `Services` resolution — requires zero Apple `container`
/// dependency and talks directly to the running HVF machine (or CI worker)
/// Docker socket.
enum CacheCommands {
    static let helpText = """
        micropod cache — Unified dependency & build cache visibility, pruning, and fleet policy

        Usage:
          micropod cache status [--json]
                                    Summary of L0/L1 disk usage, budget utilization, attach/skip
                                    decisions, proxy wiring, bounded eviction telemetry, and the
                                    units the crash fence discarded or kept at engine start
          micropod cache ls [--scope S] [--json]
                                    Per-scope & per-tool sizes, file counts, layer (L0/L1),
                                    last-used age, live lock (in-use) and crash-fence (dirty) status
          micropod cache explain <container> [--json]
                                    Explain why each tool cache attached or skipped on a container
                                    (with actionable hints for skips)
          micropod cache dedupe [--buckets N] [--json]
                                    Sample cross-scope Go build-cache duplication (default 16/256
                                    buckets) and estimate recoverable bytes
          micropod cache prune [--scope S] [--tool T] [--older-than 14d|6h|30m]
                               [--max-bytes 20g] [--partial on|off] [--dry-run] [--json]
                                    Lock-safe LRU & partial mtime-ordered Go-build pruning
                                    (never evicts in-flight locked stores or ones still marked
                                    dirty by the crash fence)
          micropod cache policy [show] [--mode auto|off] [--default-scope S|none]
                                [--allow-scopes a,b*] [--tools go,npm,…|all]
                                [--share-l0 on|off] [--go-proxy URL|off]
                                [--npm-registry URL|off] [--max-bytes SIZE|off]
                                [--max-age-days N|off] [--min-free-bytes SIZE|off]
                                [--go-trimpath on|off] [--pnpm-legacy-env on|off]
                                [--register-buildx on|off]
                                    View or hot-update machine cache policy (L0 sharing, rig
                                    depproxy wiring, janitor budgets, and tool selection)

        Target resolution: uses MICROPOD_HVF_ROOT (~/.micropod/hvf) by default, or falls back
        to a running CI worker socket (MICROPOD_CI_HOME) when no HVF machine is serving.
        """

    static func route(_ argv: [String]) -> (args: [String], json: Bool)? {
        var args = argv
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" || $0 == "--no-color" }
        if let index = args.firstIndex(of: "--cli"), index + 1 < args.count {
            args.removeSubrange(index...index + 1)
        }
        guard args.first == "cache" else { return nil }
        return (Array(args.dropFirst()), json)
    }

    static func main(_ args: [String], json: Bool) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let client = HVFMachineClient(environment: environment)
        let sub = args.first ?? "status"
        let rest = Array(args.dropFirst())
        do {
            switch sub {
            case "help", "--help", "-h":
                print(helpText)
                return ExitCode.ok
            case "policy":
                try MachineCommands.cache(["policy"] + rest, client: client, json: json)
                return ExitCode.ok
            case "status":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "cache status")
                try await handleStatus(client: client, environment: environment, json: json)
                return ExitCode.ok
            case "ls", "list":
                try await handleList(rest, client: client, environment: environment, json: json)
                return ExitCode.ok
            case "explain":
                try await handleExplain(rest, client: client, environment: environment, json: json)
                return ExitCode.ok
            case "dedupe":
                try await handleDedupe(rest, client: client, environment: environment, json: json)
                return ExitCode.ok
            case "prune":
                try await handlePrune(rest, client: client, environment: environment, json: json)
                return ExitCode.ok
            default:
                FileHandle.standardError.write(
                    Data("usage: unknown cache subcommand '\(sub)' — run `micropod cache --help`\n".utf8))
                return ExitCode.usage
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data("error: \(errorMessage(error))\n".utf8))
            return ExitCode.failure
        }
    }

    /// Resolves the live Docker socket for cache queries: prefers the HVF
    /// machine socket, falling back to an active CI worker socket.
    private static func resolveClient(_ client: HVFMachineClient, environment: [String: String]) -> HVFMachineClient {
        if FileManager.default.fileExists(atPath: client.layout.dockerSocket.path) {
            return client
        }
        var ciEnv = environment
        ciEnv["MICROPOD_CI_ENGINE"] = ciEnv["MICROPOD_CI_ENGINE"] ?? "containerd"
        let worker = CIWorker(environment: ciEnv)
        if FileManager.default.fileExists(atPath: worker.dockerSocket.path) {
            // Point a lightweight HVFMachineLayout at the CI worker directory so
            // dockerSocket maps cleanly when only a CI worker is active.
            let ciSock = worker.dockerSocket
            let layout = HVFMachineLayout(root: ciSock.deletingLastPathComponent(), dockerSocketOverride: ciSock)
            return HVFMachineClient(layout: layout, environment: environment)
        }
        return client
    }

    private static func handleStatus(client: HVFMachineClient, environment: [String: String], json: Bool) async throws {
        let active = resolveClient(client, environment: environment)
        let inspection = try await active.cacheInspection(includeStats: true)
        if json {
            try printJSON(inspection)
            return
        }
        let totals = inspection.totals
        let pol = inspection.policy
        print(
            "CACHE ROOT:  \(inspection.root) (mount=\(inspection.mountPoint)\(pol?.sharedL0 == true ? ", L0=\(inspection.mountL0Point ?? "/micropod/cache-l0")" : ""))"
        )
        if let line = cacheDiskLine(inspection) {
            print("CACHE DISK:  \(line)")
        }
        if let pol {
            var extras: [String] = []
            if pol.sharedL0 { extras.append("shared-L0=on") }
            if let gp = pol.goProxy { extras.append("GOPROXY=\(gp)") }
            if let nr = pol.npmRegistry { extras.append("npm_registry=\(nr)") }
            let extraStr = extras.isEmpty ? "" : " [" + extras.joined(separator: ", ") + "]"
            print("POLICY:      \(pol.summary) (digest \(inspection.policyDigest))\(extraStr)")
        }
        if let totals {
            let dirty = totals.dirtyCount.map { ", \($0) dirty" } ?? ""
            print(
                "USAGE:       \(formatBytes(totals.totalBytes)) across \(totals.unitCount) unit(s) in \(totals.scopeCount) scope(s) "
                    + "(\(totals.totalFiles) files, \(totals.inUseCount) in-use\(dirty))")
            print(
                "LAYERS:      L0 (verified artifacts) = \(formatBytes(totals.l0Bytes)) | "
                    + "L1 (build artifacts) = \(formatBytes(totals.l1Bytes))")
        }
        if let budget = inspection.budget {
            let maxStr = budget.maxBytes > 0 ? formatBytes(budget.maxBytes) : "unbounded"
            let pctStr = budget.utilizationPct.map { String(format: " (%.1f%%)", $0) } ?? ""
            let ageStr = budget.maxAgeDays > 0 ? ", max-age=\(budget.maxAgeDays)d" : ""
            let floorStr = budget.minFreeBytes > 0 ? ", min-free=\(formatBytes(budget.minFreeBytes))" : ""
            print("BUDGET:      ceiling=\(maxStr)\(pctStr)\(ageStr)\(floorStr)")
        }
        if let ev = inspection.evictions {
            let reason = ev.lastSweepReason.map { " last=\($0)" } ?? ""
            print(
                "EVICTIONS:   \(ev.evictions) sweep(s), freed \(formatBytes(ev.evictedBytes)) "
                    + "(\(ev.evictedUnits) units, \(ev.evictedFiles) files)\(reason)")
        }
        if let line = recoveryLine(inspection) {
            print("RECOVERY:    \(line)")
        }
    }

    /// The persistent cache disk's state, or nil when the guest reports none
    /// (a guest that predates it). A disk that should be there but is not
    /// turns shared caches off for the boot.
    static func cacheDiskLine(_ inspection: HVFCacheInspection) -> String? {
        HVFCacheDiskState.summary(inspection.cacheDisk, sharedCachesOff: inspection.sharedCachesOffReason)
    }

    /// What the crash fence did at the engine's start, or nil when it found no
    /// marked unit (or the guest predates the fence).
    static func recoveryLine(_ inspection: HVFCacheInspection) -> String? {
        let discarded = inspection.discardedAtStart ?? []
        let kept = inspection.keptAtStart ?? []
        guard !discarded.isEmpty || !kept.isEmpty else { return nil }
        var parts: [String] = []
        if !discarded.isEmpty {
            parts.append("discarded after an unclean stop: " + discarded.joined(separator: ", "))
        }
        if !kept.isEmpty {
            parts.append("kept after a clean stop: " + kept.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    /// The STATE column of `cache ls`.
    static func unitState(_ unit: HVFCacheUnitUsage) -> String {
        switch (unit.inUse, unit.dirty ?? false) {
        case (true, true): return "in-use,dirty"
        case (true, false): return "in-use"
        case (false, true): return "dirty"
        case (false, false): return "idle"
        }
    }

    private static func handleList(
        _ args: [String], client: HVFMachineClient, environment: [String: String], json: Bool
    ) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: ["--scope"], commandName: "cache ls")
        guard parsed.positionals.isEmpty else {
            throw UsageError(message: "cache ls takes no positional arguments")
        }
        let scopeFilter = parsed.value("--scope")
        let active = resolveClient(client, environment: environment)
        let inspection = try await active.cacheInspection(includeStats: true)
        var units = inspection.units ?? []
        if let scopeFilter {
            units = units.filter { $0.scope == scopeFilter }
        }
        if json {
            try printJSON(units)
            return
        }
        if units.isEmpty {
            if let why = inspection.sharedCachesOffReason {
                print("No cache stores: shared caches are off this boot (\(why)).")
                return
            }
            print("No cache stores found\(scopeFilter.map { " in scope '\($0)'" } ?? "").")
            return
        }
        print(
            "\(padRight("SCOPE", 20)) \(padRight("UNIT", 14)) \(padRight("LAYER", 5)) \(padLeft("SIZE", 10)) \(padLeft("FILES", 8)) \(padRight("LAST USED", 12)) STATE"
        )
        print(String(repeating: "-", count: 80))
        let now = Int64(Date().timeIntervalSince1970)
        for u in units {
            let age = formatAge(now - u.lastUsedUnix)
            let state = unitState(u)
            print(
                "\(padRight(u.scope, 20)) \(padRight(u.unit, 14)) \(padRight(u.layer, 5)) \(padLeft(formatBytes(u.bytes), 10)) \(padLeft(String(u.files), 8)) \(padRight(age, 12)) \(state)"
            )
        }
    }

    private static func handleExplain(
        _ args: [String], client: HVFMachineClient, environment: [String: String], json: Bool
    ) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "cache explain")
        guard parsed.positionals.count == 1 else {
            throw UsageError(message: "usage: micropod cache explain <container> [--json]")
        }
        let active = resolveClient(client, environment: environment)
        let info = try await active.explainContainerCache(parsed.positionals[0])
        if json {
            try printJSON(info)
            return
        }
        print("CONTAINER: \(info.containerName) (\(String(info.containerId.prefix(12)))) [\(info.state)]")
        print("IMAGE:     \(info.image)")
        guard let cache = info.cache else {
            print("CACHE:     no MicropodCache plan recorded on this container")
            return
        }
        let scope = cache.scope?.isEmpty == false ? cache.scope! : "(none)"
        print("SCOPE:     \(scope)  UID=\(cache.uid ?? 0)  GID=\(cache.gid ?? 0)  HOME=\(cache.home ?? "/")")
        if let reason = cache.reason, !reason.isEmpty {
            print("PLAN OFF:  \(reason) — \(skipHint(reason))")
            return
        }
        guard let tools = cache.tools, !tools.isEmpty else {
            print("TOOLS:     none")
            return
        }
        print("")
        print(
            "\(padRight("TOOL", 12)) \(padRight("LAYER", 5)) \(padRight("STATUS", 8)) \(padRight("SCOPE", 14)) DETAIL")
        print(String(repeating: "-", count: 78))
        for kind in HVFMachineCachePolicy.toolKinds {
            guard let st = tools[kind] else { continue }
            let layer = st.layer ?? (kind == "gobuild" ? "L1" : "L0")
            let sc = st.scope ?? scope
            if st.mode == "skipped" {
                let r = st.reason ?? "skipped"
                print(
                    "\(padRight(kind, 12)) \(padRight(layer, 5)) \(padRight("skipped", 8)) \(padRight("-", 14)) \(r) — \(skipHint(r))"
                )
            } else {
                let detail = "\(st.mode) -> \(st.path ?? "")"
                print(
                    "\(padRight(kind, 12)) \(padRight(layer, 5)) \(padRight("attached", 8)) \(padRight(sc, 14)) \(detail)"
                )
            }
        }
    }

    private static func handleDedupe(
        _ args: [String], client: HVFMachineClient, environment: [String: String], json: Bool
    ) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: ["--buckets"], commandName: "cache dedupe")
        guard parsed.positionals.isEmpty else {
            throw UsageError(message: "cache dedupe takes no positional arguments")
        }
        let buckets = parsed.intValue("--buckets", default: 16)
        guard (1...256).contains(buckets) else {
            throw UsageError(message: "cache dedupe: --buckets must be between 1 and 256")
        }
        let active = resolveClient(client, environment: environment)
        let sample = try await active.cacheDedupe(buckets: buckets)
        if json {
            try printJSON(sample)
            return
        }
        print(
            "SCOPES SAMPLED:  \(sample.scopesSampled.isEmpty ? "(none)" : sample.scopesSampled.joined(separator: ", "))"
        )
        print("BUCKETS SAMPLED: \(sample.bucketsSampled) / 256")
        print(
            "OBJECTS:         \(sample.totalObjects) total, \(sample.uniqueObjects) unique, \(sample.duplicateObjects) duplicate"
        )
        print(
            "DUPLICATE BYTES: \(formatBytes(sample.duplicateBytes)) sampled (~ \(formatBytes(sample.estimatedFullDuplicateBytes)) estimated across all 256 buckets)"
        )
        if sample.duplicateObjects > 0 {
            print(
                "HINT:            consolidate trusted Go build scopes or enable --share-l0 on to eliminate duplication")
        }
    }

    /// `cache prune`'s request. The command prunes unless `--dry-run` is
    /// given, and says which on the wire every time (`dryRun` is always
    /// sent), so it never depends on what the receiving end assumes when
    /// the field is missing — the API routes assume a dry run.
    static func pruneRequest(_ args: [String]) throws -> HVFCachePruneRequest {
        let parsed = try parseArgs(
            args, boolFlags: ["--dry-run"],
            valueFlags: ["--scope", "--tool", "--older-than", "--max-bytes", "--partial"],
            commandName: "cache prune")
        guard parsed.positionals.isEmpty else {
            throw UsageError(message: "cache prune takes no positional arguments")
        }
        var req = HVFCachePruneRequest(
            scope: parsed.value("--scope"),
            tool: parsed.value("--tool"),
            dryRun: parsed.has("--dry-run"),
            reason: "cli-prune")
        if let raw = parsed.value("--older-than") {
            req.olderThanSecs = try parseDurationSeconds(raw)
        }
        if let raw = parsed.value("--max-bytes") {
            req.maxBytes = try MachineCommands.parseCacheSizeBytes(raw, flag: "--max-bytes")
        }
        if let raw = parsed.value("--partial") {
            switch raw.lowercased() {
            case "on", "true", "yes", "1": req.partialGoBuild = true
            case "off", "false", "no", "0": req.partialGoBuild = false
            default: throw UsageError(message: "cache prune: --partial wants on or off, got '\(raw)'")
            }
        }
        return req
    }

    private static func handlePrune(
        _ args: [String], client: HVFMachineClient, environment: [String: String], json: Bool
    ) async throws {
        let req = try pruneRequest(args)
        let active = resolveClient(client, environment: environment)
        let res = try await active.cachePrune(req)
        if json {
            try printJSON(res)
            return
        }
        let verb = res.dryRun ? "WOULD FREE" : "FREED"
        let dirty = res.skippedDirty.map { ", \($0) skipped dirty" } ?? ""
        print(
            "\(verb): \(formatBytes(res.freedBytes)) (\(res.evictedUnits) unit(s), \(res.freedFiles) file(s), \(res.skippedInUse) skipped in-use\(dirty))"
        )
        print("BEFORE / AFTER: \(formatBytes(res.beforeBytes)) -> \(formatBytes(res.afterBytes))")
        for a in res.actions {
            let files = a.files.map { " (\($0) files)" } ?? ""
            print("  [\(padRight(a.action, 19))] \(a.scope)/\(a.unit): \(formatBytes(a.bytes))\(files)")
        }
    }

    // MARK: Formatting & Parsing Helpers

    static func parseDurationSeconds(_ raw: String) throws -> Int64 {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let scale: Int64
        let numPart: Substring
        if trimmed.hasSuffix("d") {
            scale = 86400
            numPart = trimmed.dropLast()
        } else if trimmed.hasSuffix("h") {
            scale = 3600
            numPart = trimmed.dropLast()
        } else if trimmed.hasSuffix("m") {
            scale = 60
            numPart = trimmed.dropLast()
        } else if trimmed.hasSuffix("s") {
            scale = 1
            numPart = trimmed.dropLast()
        } else {
            scale = 1
            numPart = trimmed[...]
        }
        guard let value = Int64(numPart), value > 0 else {
            throw UsageError(message: "--older-than wants a duration like 14d, 12h, 30m, or seconds, got '\(raw)'")
        }
        let (secs, overflow) = value.multipliedReportingOverflow(by: scale)
        guard !overflow else { throw UsageError(message: "--older-than '\(raw)' is too large") }
        return secs
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let v = Double(bytes)
        if v >= gb { return String(format: "%.2f GiB", v / gb) }
        if v >= mb { return String(format: "%.1f MiB", v / mb) }
        if v >= kb { return String(format: "%.1f KiB", v / kb) }
        return "\(bytes) B"
    }

    static func formatAge(_ secs: Int64) -> String {
        if secs < 0 { return "now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    static func skipHint(_ reason: String) -> String {
        switch reason {
        case "user-env": return "container explicitly set the tool's cache env var"
        case "disabled-by-image": return "image environment disables this tool's cache"
        case "user-mount": return "user volume/bind mount overlaps the cache path"
        case "image-prewarmed": return "image already contains a prewarmed cache"
        case "not-installed": return "tool binary/home not found in image (use --cache +<tool> to force)"
        case "reserved-path": return "/micropod/cache overlaps a user mount or image directory"
        case "probe-failed": return "image probe failed; check `micropod telemetry issues`"
        case "not-selected": return "excluded by machine cache policy or --cache flag"
        case "busy-exclusive": return "another running container holds exclusive lock (e.g. yarn v1)"
        case "store-failed": return "store setup or lock failed; check guest logs"
        case "cache-disk-unavailable":
            return
                "the persistent cache disk (caches.ext4) is missing or did not mount this boot; "
                + "containers run uncached until it is repaired (`micropod cache status`)"
        case "policy-off": return "machine cache policy mode is off (`micropod cache policy --mode auto`)"
        case "label-off": return "disabled via io.micropod.cache=off label"
        case "env-off": return "disabled via MICROPOD_CACHE=off"
        case "image-off": return "disabled by image MICROPOD_CACHE=off"
        case "rootless": return "private rootless containers do not attach shared caches"
        case "no-scope": return "no default scope set; pass --cache-scope <name> or set --default-scope"
        default: return reason
        }
    }

    private static func padRight(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private static func padLeft(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    private static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
