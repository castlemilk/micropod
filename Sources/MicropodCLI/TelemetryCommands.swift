import Darwin
import Foundation
import MicropodCore
import MicropodRuntime

enum TelemetryCommands {
    static let help = """
        micropod telemetry — Observability YAML config, live Prometheus/OTLP metrics & on-demand tracing

        Configuration (YAML at ~/.micropod/observability.yaml or $MICROPOD_OBSERVABILITY_CONFIG):
          micropod telemetry init [--force] [PATH]         Create a commented starter observability.yaml
          micropod telemetry show [--path]                 Print active YAML config (or its resolved path)
          micropod telemetry validate [PATH]               Validate observability.yaml schema & values
          micropod telemetry set KEY VALUE                 Update any setting (e.g. tracing.enabled true)
          micropod telemetry enable TARGET                 Enable prometheus | otlp | tracing (+ live VM)
          micropod telemetry disable TARGET                Disable prometheus | otlp | tracing (+ live VM)

        Live Engine & Workload Visibility (zero metric files on disk):
          micropod telemetry health                        Live hypervisor, kernel, cache & workload health JSON
          micropod telemetry issues [--json]               Diagnose recent API errors, slow ops, Ryuk & Virtio-FS issues
          micropod telemetry metrics [--format prometheus|otlp]
                                                           Live unified Prometheus or OTLP/JSON metrics

        On-Demand Distributed Tracing (zero overhead when off; toggle live without restarting the VM):
          micropod telemetry trace status                  Show live VMM tracing state & span counters
          micropod telemetry trace enable                  Enable tracing immediately on the running worker
          micropod telemetry trace disable                 Disable tracing immediately on the running worker
          micropod telemetry trace dump [--summary]        Dump live OTLP/JSON spans (or bottleneck table)
          micropod telemetry trace clear                   Clear buffered spans in the running worker
        """

    static let configAliasHelp = """
        micropod config — Manage Micropod YAML observability configuration

        Usage:
          micropod config init [--force] [PATH]            Create a commented starter observability.yaml
          micropod config show [--path]                    Print active YAML config (or its resolved path)
          micropod config validate [PATH]                  Validate observability.yaml schema & values
          micropod config set KEY VALUE                    Update a key (e.g. prometheus.listen 127.0.0.1:9464)
          micropod config enable prometheus|otlp|tracing   Enable an observability target
          micropod config disable prometheus|otlp|tracing  Disable an observability target

        See `micropod telemetry --help` for live health, metrics, and on-demand tracing commands.
        """

    static func mainConfigAlias(_ args: [String]) async -> Int32 {
        guard let sub = args.first else {
            print(configAliasHelp)
            return ExitCode.usage
        }
        if ["--help", "-h", "help"].contains(sub) {
            print(configAliasHelp)
            return ExitCode.ok
        }
        guard ["init", "show", "validate", "set", "enable", "disable"].contains(sub) else {
            FileHandle.standardError.write(
                Data("micropod config: unknown subcommand '\(sub)' — run `micropod config --help`\n".utf8))
            return ExitCode.usage
        }
        return await main(args)
    }

    static func main(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(help)
            return ExitCode.usage
        }
        if ["--help", "-h", "help"].contains(command) {
            print(help)
            return ExitCode.ok
        }
        let rest = Array(args.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["MICROPOD_CI_ENGINE"] = environment["MICROPOD_CI_ENGINE"] ?? "containerd"
        let worker = CIWorker(environment: environment)

        do {
            switch command {
            case "init":
                return try handleInit(rest, environment: environment)
            case "show":
                return try handleShow(rest, environment: environment)
            case "validate":
                return try handleValidate(rest, environment: environment)
            case "set":
                return try handleSet(rest, environment: environment, worker: worker)
            case "enable", "disable":
                return try handleToggle(command == "enable", rest, environment: environment, worker: worker)
            case "health":
                let report = try await OTLPTracer.withSpan(
                    name: "telemetry.health", environment: environment
                ) {
                    try await worker.health()
                }
                try printJSON(report)
                return report.verdict == .unhealthy ? ExitCode.failure : ExitCode.ok
            case "issues":
                return try await handleIssues(rest, environment: environment, worker: worker)
            case "metrics":
                return try await handleMetrics(rest, environment: environment, worker: worker)
            case "trace", "tracing":
                return try handleTrace(rest, worker: worker)
            default:
                FileHandle.standardError.write(
                    Data("micropod telemetry: unknown command '\(command)' — run `micropod telemetry --help`\n".utf8))
                return ExitCode.usage
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("micropod telemetry: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data("micropod telemetry: \(error.localizedDescription)\n".utf8))
            return ExitCode.failure
        }
    }

    private static func handleInit(_ args: [String], environment: [String: String]) throws -> Int32 {
        var force = false
        var explicitPath: String?
        for arg in args {
            if arg == "--force" || arg == "-f" {
                force = true
            } else if !arg.hasPrefix("-"), explicitPath == nil {
                explicitPath = arg
            } else {
                throw UsageError(message: "usage: micropod telemetry init [--force] [PATH]")
            }
        }
        let target =
            explicitPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? ObservabilityConfig.resolveConfigPath(environment: environment)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path), !force {
            throw MicropodError.message("Config already exists at \(target.path) (pass --force to overwrite)")
        }
        let dir = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let content = ObservabilityConfig.exampleYAML()
        _ = try ObservabilityConfig.parse(yaml: content)
        try Data(content.utf8).write(to: target, options: .atomic)
        print("Wrote observability config to \(target.path)")
        return ExitCode.ok
    }

    private static func handleShow(_ args: [String], environment: [String: String]) throws -> Int32 {
        let path = ObservabilityConfig.resolveConfigPath(environment: environment)
        if args == ["--path"] {
            print(path.path)
            return ExitCode.ok
        }
        guard args.isEmpty else {
            throw UsageError(message: "usage: micropod telemetry show [--path]")
        }
        let cfg = try ObservabilityConfig.load(environment: environment)
        let exists = FileManager.default.fileExists(atPath: path.path)
        print("# source: \(exists ? path.path : "\(path.path) (defaults; run `micropod telemetry init` to save)")")
        print(try cfg.renderYAML(), terminator: "")
        return ExitCode.ok
    }

    private static func handleValidate(_ args: [String], environment: [String: String]) throws -> Int32 {
        guard args.count <= 1 else {
            throw UsageError(message: "usage: micropod telemetry validate [PATH]")
        }
        let target =
            args.first.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? ObservabilityConfig.resolveConfigPath(environment: environment)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw MicropodError.message("Observability YAML config not found: \(target.path)")
        }
        let text = try String(contentsOf: target, encoding: .utf8)
        let cfg = try ObservabilityConfig.parse(yaml: text)
        print(
            "OK: \(target.path) (service=\(cfg.serviceName), prometheus=\(cfg.prometheus.enabled), "
                + "otlp=\(cfg.otlp.enabled), tracing=\(cfg.tracing.enabled))")
        return ExitCode.ok
    }

    private static func handleSet(
        _ args: [String], environment: [String: String], worker: CIWorker
    ) throws -> Int32 {
        guard args.count == 2 else {
            throw UsageError(message: "usage: micropod telemetry set KEY VALUE")
        }
        let key = args[0]
        let value = args[1]
        let path = ObservabilityConfig.resolveConfigPath(environment: environment)
        var cfg = try ObservabilityConfig.loadOrDefault(at: path)
        try cfg.set(key: key, value: value)
        try cfg.save(to: path)
        print("Updated \(key) = \(value) in \(path.path)")
        if key == "tracing.enabled", FileManager.default.fileExists(atPath: worker.telemetrySocket.path) {
            if let _ = try? worker.setLiveTracing(enabled: cfg.tracing.enabled) {
                print("Applied live tracing=\(cfg.tracing.enabled) to running worker (no restart required)")
            }
        }
        return ExitCode.ok
    }

    private static func handleToggle(
        _ enable: Bool, _ args: [String], environment: [String: String], worker: CIWorker
    ) throws -> Int32 {
        guard args.count == 1 else {
            throw UsageError(
                message: "usage: micropod telemetry \(enable ? "enable" : "disable") prometheus|otlp|tracing")
        }
        let target = args[0].lowercased()
        let key: String
        switch target {
        case "prometheus", "prom": key = "prometheus.enabled"
        case "otlp", "otel": key = "otlp.enabled"
        case "tracing", "trace": key = "tracing.enabled"
        default:
            throw UsageError(message: "Target must be prometheus, otlp, or tracing (got '\(args[0])')")
        }
        return try handleSet([key, enable ? "true" : "false"], environment: environment, worker: worker)
    }

    private static func handleMetrics(
        _ args: [String], environment: [String: String], worker: CIWorker
    ) async throws -> Int32 {
        var format = "prometheus"
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--prometheus" {
                format = "prometheus"
            } else if a == "--otlp" {
                format = "otlp"
            } else if a == "--format", i + 1 < args.count {
                format = args[i + 1].lowercased()
                i += 1
            } else if a.hasPrefix("--format=") {
                format = String(a.dropFirst("--format=".count)).lowercased()
            } else {
                throw UsageError(message: "usage: micropod telemetry metrics [--format prometheus|otlp]")
            }
            i += 1
        }
        switch format {
        case "prometheus", "prom":
            let text = try await OTLPTracer.withSpan(
                name: "telemetry.metrics", attributes: ["format": "prometheus"], environment: environment
            ) {
                try await worker.prometheusMetrics()
            }
            print(text, terminator: "")
            return ExitCode.ok
        case "otlp", "otel", "json":
            let data = try await OTLPTracer.withSpan(
                name: "telemetry.metrics", attributes: ["format": "otlp"], environment: environment
            ) {
                try await worker.otlpMetricsJSON()
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return ExitCode.ok
        default:
            throw UsageError(message: "--format must be 'prometheus' or 'otlp' (got '\(format)')")
        }
    }

    private static func handleTrace(_ args: [String], worker: CIWorker) throws -> Int32 {
        guard let action = args.first else {
            throw UsageError(message: "usage: micropod telemetry trace status|enable|disable|dump [--summary]|clear")
        }
        switch action {
        case "status":
            let data = try worker.tracingStatus()
            FileHandle.standardOutput.write(data)
            if data.last != 0x0a { FileHandle.standardOutput.write(Data("\n".utf8)) }
            return ExitCode.ok
        case "enable":
            let data = try worker.setLiveTracing(enabled: true)
            FileHandle.standardOutput.write(data)
            if data.last != 0x0a { FileHandle.standardOutput.write(Data("\n".utf8)) }
            return ExitCode.ok
        case "disable":
            let data = try worker.setLiveTracing(enabled: false)
            FileHandle.standardOutput.write(data)
            if data.last != 0x0a { FileHandle.standardOutput.write(Data("\n".utf8)) }
            return ExitCode.ok
        case "clear":
            let data = try worker.clearLiveTraces()
            FileHandle.standardOutput.write(data)
            if data.last != 0x0a { FileHandle.standardOutput.write(Data("\n".utf8)) }
            return ExitCode.ok
        case "dump":
            let summary = args.dropFirst().contains("--summary")
            let data = try worker.tracesOTLPJSON()
            if summary {
                printTraceSummary(data)
            } else {
                FileHandle.standardOutput.write(data)
                if data.last != 0x0a { FileHandle.standardOutput.write(Data("\n".utf8)) }
            }
            return ExitCode.ok
        default:
            throw UsageError(message: "usage: micropod telemetry trace status|enable|disable|dump [--summary]|clear")
        }
    }

    private static func printTraceSummary(_ otlpData: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: otlpData) as? [String: Any],
            let resourceSpans = root["resourceSpans"] as? [[String: Any]]
        else {
            print("No trace spans available.")
            return
        }
        struct Row {
            let name: String
            let durationMs: Double
            let status: String
            let attrs: String
        }
        var rows: [Row] = []
        for rs in resourceSpans {
            for ss in (rs["scopeSpans"] as? [[String: Any]]) ?? [] {
                for sp in (ss["spans"] as? [[String: Any]]) ?? [] {
                    let name = (sp["name"] as? String) ?? "unknown"
                    let start = UInt64((sp["startTimeUnixNano"] as? String) ?? "0") ?? 0
                    let end = UInt64((sp["endTimeUnixNano"] as? String) ?? "0") ?? start
                    let ms = Double(end >= start ? end - start : 0) / 1_000_000.0
                    let code = ((sp["status"] as? [String: Any])?["code"] as? Int) ?? 1
                    let status = code == 2 ? "ERR" : "OK"
                    let attrList: [String] = ((sp["attributes"] as? [[String: Any]]) ?? []).compactMap { a in
                        guard let k = a["key"] as? String,
                            let v = (a["value"] as? [String: Any])?["stringValue"] as? String
                        else { return nil }
                        return "\(k)=\(v)"
                    }
                    rows.append(Row(name: name, durationMs: ms, status: status, attrs: attrList.joined(separator: " ")))
                }
            }
        }
        if rows.isEmpty {
            print("No spans recorded yet. Enable live tracing with: micropod telemetry trace enable")
            return
        }
        rows.sort { $0.durationMs > $1.durationMs }
        func padRight(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
        func padLeft(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
        }
        print("\(padRight("SPAN (slowest first)", 34)) \(padLeft("DURATION", 10))  \(padRight("STAT", 4))  ATTRIBUTES")
        print(String(repeating: "-", count: 78))
        for r in rows {
            let dur = String(format: "%.2f ms", r.durationMs)
            print("\(padRight(r.name, 34)) \(padLeft(dur, 10))  \(padRight(r.status, 4))  \(r.attrs)")
        }
    }

    private static func handleIssues(
        _ args: [String], environment: [String: String], worker: CIWorker
    ) async throws -> Int32 {
        var jsonOut = false
        for a in args {
            if a == "--json" {
                jsonOut = true
            } else {
                throw UsageError(message: "usage: micropod telemetry issues [--json]")
            }
        }
        let report = try await worker.health()
        let issues = report.runtimeEngine?.recentIssues ?? []
        if jsonOut {
            struct IssuesPayload: Encodable {
                let verdict: CIWorker.HealthVerdict
                let warnings: [String]
                let api: CIWorker.DockerAPIMetrics?
                let reaper: CIWorker.ReaperMetrics?
                let fsErrors: UInt64?
                let fsNotifyEvents: UInt64?
                let fsKeepCacheHits: UInt64?
                let cacheAttach: [String: UInt64]?
                let cacheSkip: [String: UInt64]?
                let cacheEvictions: UInt64?
                let cacheEvictedBytes: UInt64?
                let cacheTotals: HVFCacheTotals?
                let recentIssues: [CIWorker.RuntimeIssue]
            }
            try printJSON(
                IssuesPayload(
                    verdict: report.verdict,
                    warnings: report.warnings,
                    api: report.runtimeEngine?.api,
                    reaper: report.runtimeEngine?.reaper,
                    fsErrors: report.hypervisor?.fsErrors,
                    fsNotifyEvents: report.hypervisor?.fsNotifyEvents,
                    fsKeepCacheHits: report.hypervisor?.fsKeepCacheHits,
                    cacheAttach: report.runtimeEngine?.cacheAttach,
                    cacheSkip: report.runtimeEngine?.cacheSkip,
                    cacheEvictions: report.runtimeEngine?.cacheEvictions,
                    cacheEvictedBytes: report.runtimeEngine?.cacheEvictedBytes,
                    cacheTotals: report.cacheInventory?.totals,
                    recentIssues: issues
                ))
            return report.verdict == .unhealthy ? ExitCode.failure : ExitCode.ok
        }

        print(
            "VERDICT: \(report.verdict.rawValue.uppercased()) (warnings=\(report.warnings.count), recent_issues=\(issues.count))"
        )
        for w in report.warnings {
            print("  [WARN] \(w)")
        }
        if let api = report.runtimeEngine?.api {
            let maxMs = Double(api.maxDurationUsec) / 1000.0
            print(
                String(
                    format: "DOCKER API: reqs=%llu 4xx=%llu 5xx=%llu 409=%llu 501=%llu slow(>50ms)=%llu max=%.1fms",
                    api.requestsTotal, api.errors4xx, api.errors5xx, api.conflicts409,
                    api.notImplemented501, api.slowRequestsTotal, maxMs))
        }
        if let r = report.runtimeEngine?.reaper {
            let maxMs = Double(r.maxReapDurationUsec) / 1000.0
            print(
                String(
                    format:
                        "RYUK REAPER: active=%lld started=%llu closed=%llu reaped(c=%llu n=%llu v=%llu) errors=%llu denied=%llu max=%.1fms",
                    r.activeSessions, r.sessionsStarted, r.sessionsClosed,
                    r.containersReaped, r.networksReaped, r.volumesReaped,
                    r.reapErrors, r.reapDenied, maxMs))
        }
        if let hv = report.hypervisor {
            print(
                "VIRTIO-FS: reqs=\(hv.fsRequests) keep_cache_hits=\(hv.fsKeepCacheHits ?? 0) "
                    + "ro_cache=\(hv.fsRoCacheHits ?? 0)/\(hv.fsRoCacheMisses ?? 0) "
                    + "notify_events=\(hv.fsNotifyEvents ?? 0) epoch_resets=\(hv.fsNotifyEpochResets ?? 0) "
                    + "errors=\(hv.fsErrors ?? 0)")
        }
        if let totals = report.cacheInventory?.totals {
            let attachTotal = report.runtimeEngine?.cacheAttach?.values.reduce(0, +) ?? 0
            let skipTotal = report.runtimeEngine?.cacheSkip?.values.reduce(0, +) ?? 0
            let evictions = report.runtimeEngine?.cacheEvictions ?? 0
            let evictedMB = Double(report.runtimeEngine?.cacheEvictedBytes ?? 0) / (1024.0 * 1024.0)
            let totalMB = Double(totals.totalBytes) / (1024.0 * 1024.0)
            let l0MB = Double(totals.l0Bytes) / (1024.0 * 1024.0)
            let l1MB = Double(totals.l1Bytes) / (1024.0 * 1024.0)
            print(
                String(
                    format:
                        "CACHE: total=%.1f MiB (L0=%.1f MiB L1=%.1f MiB) scopes=%d units=%d in_use=%d attach=%llu skip=%llu evictions=%llu (%.1f MiB)",
                    totalMB, l0MB, l1MB, totals.scopeCount, totals.unitCount, totals.inUseCount,
                    attachTotal, skipTotal, evictions, evictedMB))
        }
        if issues.isEmpty {
            print("No recent errors, conflicts, or slow API calls (>50 ms).")
            return ExitCode.ok
        }
        print("")
        print("RECENT ISSUES (newest first):")
        for item in issues.reversed().prefix(25) {
            let msg = (item.message?.isEmpty == false) ? " — \(item.message!)" : ""
            print(
                String(
                    format: "  [%-12s] %-11s %-6s %-26s HTTP %-3d %6.1fms%s",
                    (item.kind as NSString).utf8String!,
                    (item.source as NSString).utf8String!,
                    (item.method as NSString).utf8String!,
                    (item.route as NSString).utf8String!,
                    item.status,
                    item.durationMs,
                    (msg as NSString).utf8String!))
        }
        return report.verdict == .unhealthy ? ExitCode.failure : ExitCode.ok
    }

    private static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
