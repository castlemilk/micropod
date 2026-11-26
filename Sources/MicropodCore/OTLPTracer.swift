import Foundation

/// Lightweight, zero-overhead-when-off OpenTelemetry OTLP/HTTP trace exporter for Micropod CLI
/// and runtime host operations. Active only when `tracing.enabled == true` in `observability.yaml`
/// or `MICROPOD_TRACE=1` is set in the environment.
public enum OTLPTracer {
    public static func isEnabled(
        config: ObservabilityConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let raw = environment["MICROPOD_TRACE"]?.lowercased() {
            if ["1", "true", "yes", "on"].contains(raw) { return true }
            if ["0", "false", "no", "off"].contains(raw) { return false }
        }
        return config.tracing.enabled
    }

    private static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        if bytes.allSatisfy({ $0 == 0 }) { bytes[count - 1] = 1 }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func nowUnixNano() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000.0))
    }

    /// Execute `body` wrapped in an OTLP span if tracing is enabled. When tracing is disabled,
    /// invokes `body()` directly with zero network calls or span allocations.
    public static func withSpan<T>(
        name: String,
        attributes: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        body: () async throws -> T
    ) async throws -> T {
        let config = (try? ObservabilityConfig.load(environment: environment)) ?? ObservabilityConfig()
        guard isEnabled(config: config, environment: environment) else {
            return try await body()
        }
        let startNs = nowUnixNano()
        var spanAttrs = attributes
        var statusOK = true
        do {
            let value = try await body()
            let endNs = max(startNs, nowUnixNano())
            await exportSingleSpan(
                name: name, startNs: startNs, endNs: endNs, attributes: spanAttrs,
                statusOK: statusOK, config: config)
            return value
        } catch {
            statusOK = false
            spanAttrs["error.message"] = error.localizedDescription
            let endNs = max(startNs, nowUnixNano())
            await exportSingleSpan(
                name: name, startNs: startNs, endNs: endNs, attributes: spanAttrs,
                statusOK: statusOK, config: config)
            throw error
        }
    }

    private static func exportSingleSpan(
        name: String,
        startNs: UInt64,
        endNs: UInt64,
        attributes: [String: String],
        statusOK: Bool,
        config: ObservabilityConfig
    ) async {
        let endpoint = config.effectiveTracesEndpoint
        guard let url = URL(string: endpoint) else { return }

        func attr(_ k: String, _ v: String) -> [String: Any] {
            ["key": k, "value": ["stringValue": v]]
        }

        var resourceAttrs: [[String: Any]] = [
            attr("service.name", config.serviceName),
            attr("telemetry.sdk.name", "micropod-swift"),
        ]
        for (k, v) in config.otlp.resourceAttributes.sorted(by: { $0.key < $1.key }) {
            resourceAttrs.append(attr(k, v))
        }
        let spanAttrs = attributes.sorted(by: { $0.key < $1.key }).map { attr($0.key, $0.value) }
        let span: [String: Any] = [
            "traceId": randomHex(bytes: 16),
            "spanId": randomHex(bytes: 8),
            "name": name,
            "kind": 1,
            "startTimeUnixNano": String(startNs),
            "endTimeUnixNano": String(endNs),
            "attributes": spanAttrs,
            "status": ["code": statusOK ? 1 : 2],
        ]
        let payload: [String: Any] = [
            "resourceSpans": [
                [
                    "resource": ["attributes": resourceAttrs],
                    "scopeSpans": [
                        [
                            "scope": ["name": "micropod.cli", "version": "1.0.0"],
                            "spans": [span],
                        ]
                    ],
                ]
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.otlp.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        // Best-effort non-fatal export: tracing must never break a user CLI command.
        _ = try? await URLSession.shared.data(for: req)
    }
}
