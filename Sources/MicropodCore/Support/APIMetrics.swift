import Foundation

/// Tiny in-process metrics registry. Counts requests + errors and tracks
/// total request latency (microseconds) keyed by `route` + `method` +
/// `status`. Exposes Prometheus text format at /metrics. No external deps.
///
/// Shared by MicropodAPI and the Docker shim; the shim also reuses it for
/// `container` CLI spawn metrics (see `CLIMetrics`).
public final class APIMetrics: @unchecked Sendable {
    private struct Bucket: Sendable {
        var count: Int = 0
        var errors: Int = 0
        var latencyUs: Int = 0
    }

    private let queue = DispatchQueue(label: "APIMetrics", attributes: .concurrent)
    private var buckets: [String: Bucket] = [:]
    private let startedAt: Date = Date()
    /// Metric name prefix — lets two registries coexist in one exposition
    /// without duplicate HELP/TYPE lines (shim renders API + CLI metrics).
    private let prefix: String

    public init(prefix: String = "micropod_api") {
        self.prefix = prefix
    }

    /// Key separator: labels may contain spaces ("image list") so buckets key
    /// on a unit separator, never a plain space.
    private static let sep = "\u{1F}"

    public func record(route: String, method: String, status: Int, duration: TimeInterval) {
        let key = "\(route)\(Self.sep)\(method)\(Self.sep)\(status)"
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
        lines.append("# HELP \(prefix)_uptime_seconds Seconds since server start")
        lines.append("# TYPE \(prefix)_uptime_seconds gauge")
        lines.append(String(format: "\(prefix)_uptime_seconds %.3f", Date().timeIntervalSince(startedAt)))
        lines.append("# HELP \(prefix)_requests_total Total requests handled")
        lines.append("# TYPE \(prefix)_requests_total counter")
        lines.append("# HELP \(prefix)_errors_total Responses with status >= 400")
        lines.append("# TYPE \(prefix)_errors_total counter")
        lines.append("# HELP \(prefix)_request_duration_microseconds_total Total request latency")
        lines.append("# TYPE \(prefix)_request_duration_microseconds_total counter")

        var snapshot: [(String, Bucket)] = []
        queue.sync { snapshot = self.buckets.map { ($0.key, $0.value) } }
        snapshot.sort { $0.0 < $1.0 }
        for (key, b) in snapshot {
            let parts = key.split(separator: Self.sep, maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let (route, method, statusStr) = (parts[0], parts[1], parts[2])
            let labels = "route=\"\(route)\",method=\"\(method)\",status=\"\(statusStr)\""
            let durLabels = "route=\"\(route)\",method=\"\(method)\""
            lines.append("\(prefix)_requests_total{\(labels)} \(b.count)")
            lines.append("\(prefix)_errors_total{\(labels)} \(b.errors)")
            lines.append("\(prefix)_request_duration_microseconds_total{\(durLabels)} \(b.latencyUs)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Process-wide counter for `container` CLI spawns, recorded inside
/// `ContainerCLIClient.run`. `command` is the command's display name;
/// `status` is the exit code (504 timeout, 499 cancelled).
public enum CLIMetrics {
    public static let shared = APIMetrics(prefix: "micropod_cli")

    static func record(command: String, status: Int, duration: TimeInterval) {
        shared.record(route: command, method: "CLI", status: status, duration: duration)
    }
}
