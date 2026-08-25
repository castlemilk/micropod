import Foundation

/// Tiny in-process metrics registry. Counts requests + errors and tracks
/// total request latency (microseconds) keyed by `route` + `method` +
/// `status`. Exposes Prometheus text format at /metrics. No external deps.
public final class APIMetrics: @unchecked Sendable {
    private struct Bucket: Sendable {
        var count: Int = 0
        var errors: Int = 0
        var latencyUs: Int = 0
    }

    private let queue = DispatchQueue(label: "APIMetrics", attributes: .concurrent)
    private var buckets: [String: Bucket] = [:]
    private let startedAt: Date = Date()

    public init() {}

    public func record(route: String, method: String, status: Int, duration: TimeInterval) {
        let key = "\(route) \(method) \(status)"
        let us = Int(duration * 1_000_000)
        queue.async(flags: .barrier) {
            var b = self.buckets[key, default: Bucket()]
            b.count += 1
            if status >= 400 { b.errors += 1 }
            b.latencyUs += us
            self.buckets[key] = b
        }
    }

    public func render() -> String {
        var lines: [String] = []
        lines.append("# HELP micropod_api_uptime_seconds Seconds since server start")
        lines.append("# TYPE micropod_api_uptime_seconds gauge")
        lines.append(String(format: "micropod_api_uptime_seconds %.3f", Date().timeIntervalSince(startedAt)))
        lines.append("# HELP micropod_api_requests_total Total HTTP requests handled")
        lines.append("# TYPE micropod_api_requests_total counter")
        lines.append("# HELP micropod_api_errors_total HTTP responses with status >= 400")
        lines.append("# TYPE micropod_api_errors_total counter")
        lines.append("# HELP micropod_api_request_duration_microseconds_total Total request latency")
        lines.append("# TYPE micropod_api_request_duration_microseconds_total counter")

        var snapshot: [(String, Bucket)] = []
        queue.sync { snapshot = self.buckets.map { ($0.key, $0.value) } }
        snapshot.sort { $0.0 < $1.0 }
        for (key, b) in snapshot {
            let parts = key.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let (route, method, statusStr) = (parts[0], parts[1], parts[2])
            let labels = "route=\"\(route)\",method=\"\(method)\",status=\"\(statusStr)\""
            let durLabels = "route=\"\(route)\",method=\"\(method)\""
            lines.append("micropod_api_requests_total{\(labels)} \(b.count)")
            lines.append("micropod_api_errors_total{\(labels)} \(b.errors)")
            lines.append("micropod_api_request_duration_microseconds_total{\(durLabels)} \(b.latencyUs)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
