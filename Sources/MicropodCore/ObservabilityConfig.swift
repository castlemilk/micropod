import Foundation
import Yams

/// Declarative YAML configuration for Micropod Prometheus, OpenTelemetry (OTLP) metrics,
/// and on-demand distributed tracing.
/// Loaded from `MICROPOD_OBSERVABILITY_CONFIG` or `~/.micropod/observability.yaml` (zero metric files on disk).
public struct ObservabilityConfig: Codable, Sendable, Equatable {
    public static let environmentKey = "MICROPOD_OBSERVABILITY_CONFIG"
    public static let defaultFilename = "observability.yaml"

    public struct Prometheus: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var listen: String?
        public var path: String

        public init(enabled: Bool = true, listen: String? = nil, path: String = "/metrics") {
            self.enabled = enabled
            self.listen = listen
            self.path = path
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            listen = try c.decodeIfPresent(String.self, forKey: .listen)
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/metrics"
        }
    }

    public struct OTLP: Codable, Sendable, Equatable {
        enum CodingKeys: String, CodingKey {
            case enabled
            case endpoint
            case tracesEndpoint = "traces_endpoint"
            case exportIntervalSecs = "export_interval_secs"
            case headers
            case resourceAttributes = "resource_attributes"
        }

        public var enabled: Bool
        public var endpoint: String
        public var tracesEndpoint: String?
        public var exportIntervalSecs: Int
        public var headers: [String: String]
        public var resourceAttributes: [String: String]

        public init(
            enabled: Bool = false,
            endpoint: String = "http://127.0.0.1:4318/v1/metrics",
            tracesEndpoint: String? = nil,
            exportIntervalSecs: Int = 10,
            headers: [String: String] = [:],
            resourceAttributes: [String: String] = [:]
        ) {
            self.enabled = enabled
            self.endpoint = endpoint
            self.tracesEndpoint = tracesEndpoint
            self.exportIntervalSecs = exportIntervalSecs
            self.headers = headers
            self.resourceAttributes = resourceAttributes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? "http://127.0.0.1:4318/v1/metrics"
            tracesEndpoint = try c.decodeIfPresent(String.self, forKey: .tracesEndpoint)
            exportIntervalSecs = try c.decodeIfPresent(Int.self, forKey: .exportIntervalSecs) ?? 10
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            resourceAttributes = try c.decodeIfPresent([String: String].self, forKey: .resourceAttributes) ?? [:]
        }
    }

    public struct Tracing: Codable, Sendable, Equatable {
        enum CodingKeys: String, CodingKey {
            case enabled
            case endpoint
            case sampleRate = "sample_rate"
            case slowOpThresholdMs = "slow_op_threshold_ms"
        }

        public var enabled: Bool
        public var endpoint: String
        public var sampleRate: Double
        public var slowOpThresholdMs: Int

        public init(
            enabled: Bool = false,
            endpoint: String = "http://127.0.0.1:4318/v1/traces",
            sampleRate: Double = 1.0,
            slowOpThresholdMs: Int = 5
        ) {
            self.enabled = enabled
            self.endpoint = endpoint
            self.sampleRate = sampleRate
            self.slowOpThresholdMs = slowOpThresholdMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? "http://127.0.0.1:4318/v1/traces"
            sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 1.0
            slowOpThresholdMs = try c.decodeIfPresent(Int.self, forKey: .slowOpThresholdMs) ?? 5
        }
    }

    public struct HealthThresholds: Codable, Sendable, Equatable {
        enum CodingKeys: String, CodingKey {
            case memoryWarnPct = "memory_warn_pct"
            case vmmTimeoutMs = "vmm_timeout_ms"
        }

        public var memoryWarnPct: Double
        public var vmmTimeoutMs: Int

        public init(memoryWarnPct: Double = 90.0, vmmTimeoutMs: Int = 2000) {
            self.memoryWarnPct = memoryWarnPct
            self.vmmTimeoutMs = vmmTimeoutMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            memoryWarnPct = try c.decodeIfPresent(Double.self, forKey: .memoryWarnPct) ?? 90.0
            vmmTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .vmmTimeoutMs) ?? 2000
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case serviceName = "service_name"
        case prometheus
        case otlp
        case tracing
        case health
    }

    public var schema: Int
    public var serviceName: String
    public var prometheus: Prometheus
    public var otlp: OTLP
    public var tracing: Tracing
    public var health: HealthThresholds

    public init(
        schema: Int = 1,
        serviceName: String = "micropod-engine",
        prometheus: Prometheus = Prometheus(),
        otlp: OTLP = OTLP(),
        tracing: Tracing = Tracing(),
        health: HealthThresholds = HealthThresholds()
    ) {
        self.schema = schema
        self.serviceName = serviceName
        self.prometheus = prometheus
        self.otlp = otlp
        self.tracing = tracing
        self.health = health
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName) ?? "micropod-engine"
        prometheus = try c.decodeIfPresent(Prometheus.self, forKey: .prometheus) ?? Prometheus()
        otlp = try c.decodeIfPresent(OTLP.self, forKey: .otlp) ?? OTLP()
        tracing = try c.decodeIfPresent(Tracing.self, forKey: .tracing) ?? Tracing()
        health = try c.decodeIfPresent(HealthThresholds.self, forKey: .health) ?? HealthThresholds()
    }

    /// Effective OTLP/HTTP traces receiver URL (prefers `tracing.endpoint`, falls back to legacy `otlp.traces_endpoint`).
    public var effectiveTracesEndpoint: String {
        if !tracing.endpoint.isEmpty {
            return tracing.endpoint
        }
        if let legacy = otlp.tracesEndpoint, !legacy.isEmpty {
            return legacy
        }
        return "http://127.0.0.1:4318/v1/traces"
    }

    public static func defaultConfigPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod")
            .appendingPathComponent(defaultFilename)
    }

    public static func resolveConfigPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment[environmentKey], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit).standardizedFileURL
        }
        return defaultConfigPath()
    }

    public static func parse(yaml: String) throws -> ObservabilityConfig {
        let cfg = try YAMLDecoder().decode(ObservabilityConfig.self, from: yaml)
        try cfg.validate()
        return cfg
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ObservabilityConfig {
        let fm = FileManager.default
        if let explicit = environment[environmentKey], !explicit.isEmpty {
            guard fm.fileExists(atPath: explicit) else {
                throw MicropodError.message("Observability YAML config not found: \(explicit)")
            }
            let text = try String(contentsOfFile: explicit, encoding: .utf8)
            return try parse(yaml: text)
        }
        let fallback = defaultConfigPath()
        if fm.fileExists(atPath: fallback.path) {
            let text = try String(contentsOf: fallback, encoding: .utf8)
            return try parse(yaml: text)
        }
        return ObservabilityConfig()
    }

    public static func loadOrDefault(
        at url: URL
    ) throws -> ObservabilityConfig {
        if FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
            return try parse(yaml: text)
        }
        return ObservabilityConfig()
    }

    private static func parseBool(_ raw: String, key: String) throws -> Bool {
        switch raw.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw MicropodError.message("\(key) expects true/false (got '\(raw)')")
        }
    }

    /// Update any configuration key via dot-path (e.g. `tracing.enabled`, `prometheus.listen`,
    /// `otlp.endpoint`, `otlp.resource_attributes.env`) and validate before returning.
    public mutating func set(key: String, value: String) throws {
        var copy = self
        if key.hasPrefix("otlp.resource_attributes.") {
            let attrKey = String(key.dropFirst("otlp.resource_attributes.".count))
            guard !attrKey.isEmpty else {
                throw MicropodError.message("Attribute key cannot be empty")
            }
            if value == "unset" || value == "none" || value.isEmpty {
                copy.otlp.resourceAttributes.removeValue(forKey: attrKey)
            } else {
                copy.otlp.resourceAttributes[attrKey] = value
            }
        } else if key.hasPrefix("otlp.headers.") {
            let hdrKey = String(key.dropFirst("otlp.headers.".count))
            guard !hdrKey.isEmpty else {
                throw MicropodError.message("Header key cannot be empty")
            }
            if value == "unset" || value == "none" || value.isEmpty {
                copy.otlp.headers.removeValue(forKey: hdrKey)
            } else {
                copy.otlp.headers[hdrKey] = value
            }
        } else {
            switch key {
            case "service_name":
                copy.serviceName = value
            case "prometheus.enabled":
                copy.prometheus.enabled = try Self.parseBool(value, key: key)
            case "prometheus.listen":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.prometheus.listen =
                    (trimmed.isEmpty || trimmed == "none" || trimmed == "null" || trimmed == "unset") ? nil : trimmed
            case "prometheus.path":
                copy.prometheus.path = value
            case "otlp.enabled":
                copy.otlp.enabled = try Self.parseBool(value, key: key)
            case "otlp.endpoint":
                copy.otlp.endpoint = value
            case "otlp.export_interval_secs":
                guard let secs = Int(value) else {
                    throw MicropodError.message("\(key) expects an integer (got '\(value)')")
                }
                copy.otlp.exportIntervalSecs = secs
            case "tracing.enabled":
                copy.tracing.enabled = try Self.parseBool(value, key: key)
            case "tracing.endpoint":
                copy.tracing.endpoint = value
            case "tracing.sample_rate":
                guard let rate = Double(value) else {
                    throw MicropodError.message("\(key) expects a number between 0.0 and 1.0 (got '\(value)')")
                }
                copy.tracing.sampleRate = rate
            case "tracing.slow_op_threshold_ms":
                guard let ms = Int(value) else {
                    throw MicropodError.message("\(key) expects an integer milliseconds value (got '\(value)')")
                }
                copy.tracing.slowOpThresholdMs = ms
            case "health.memory_warn_pct":
                guard let pct = Double(value) else {
                    throw MicropodError.message("\(key) expects a number between 50 and 99.9 (got '\(value)')")
                }
                copy.health.memoryWarnPct = pct
            case "health.vmm_timeout_ms":
                guard let ms = Int(value) else {
                    throw MicropodError.message("\(key) expects an integer between 100 and 30000 (got '\(value)')")
                }
                copy.health.vmmTimeoutMs = ms
            default:
                throw MicropodError.message(
                    "Unknown configuration key '\(key)'. Supported keys: service_name, "
                        + "prometheus.{enabled,listen,path}, otlp.{enabled,endpoint,export_interval_secs,resource_attributes.<k>,headers.<k>}, "
                        + "tracing.{enabled,endpoint,sample_rate,slow_op_threshold_ms}, health.{memory_warn_pct,vmm_timeout_ms}"
                )
            }
        }
        try copy.validate()
        self = copy
    }

    public func validate() throws {
        guard schema == 1 else {
            throw MicropodError.message("Unsupported observability.yaml schema \(schema); expected 1")
        }
        guard !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MicropodError.message("observability.yaml service_name cannot be empty")
        }
        guard prometheus.path.hasPrefix("/") else {
            throw MicropodError.message("observability.yaml prometheus.path must start with '/'")
        }
        if let listen = prometheus.listen, !listen.isEmpty {
            guard listen.contains(":") else {
                throw MicropodError.message(
                    "observability.yaml prometheus.listen must be host:port (e.g. 127.0.0.1:9464)")
            }
        }
        if otlp.enabled {
            guard otlp.endpoint.hasPrefix("http://") || otlp.endpoint.hasPrefix("https://") else {
                throw MicropodError.message("observability.yaml otlp.endpoint must be an http:// or https:// URL")
            }
        }
        guard (1...3600).contains(otlp.exportIntervalSecs) else {
            throw MicropodError.message("observability.yaml otlp.export_interval_secs must be between 1 and 3600")
        }
        if !tracing.endpoint.isEmpty {
            guard tracing.endpoint.hasPrefix("http://") || tracing.endpoint.hasPrefix("https://") else {
                throw MicropodError.message("observability.yaml tracing.endpoint must be an http:// or https:// URL")
            }
        }
        guard (0.0...1.0).contains(tracing.sampleRate) else {
            throw MicropodError.message("observability.yaml tracing.sample_rate must be between 0.0 and 1.0")
        }
        guard (0...60000).contains(tracing.slowOpThresholdMs) else {
            throw MicropodError.message("observability.yaml tracing.slow_op_threshold_ms must be between 0 and 60000")
        }
        guard (50.0...99.9).contains(health.memoryWarnPct) else {
            throw MicropodError.message("observability.yaml health.memory_warn_pct must be between 50 and 99.9")
        }
        guard (100...30000).contains(health.vmmTimeoutMs) else {
            throw MicropodError.message("observability.yaml health.vmm_timeout_ms must be between 100 and 30000")
        }
    }

    public func renderYAML() throws -> String {
        try YAMLEncoder().encode(self)
    }

    public func save(to url: URL) throws {
        try validate()
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let yaml = try renderYAML()
        try Data(yaml.utf8).write(to: url, options: .atomic)
    }

    public static func exampleYAML() -> String {
        """
        # Micropod Engine & Workload Observability Configuration
        # Default path: ~/.micropod/observability.yaml (override via MICROPOD_OBSERVABILITY_CONFIG)
        # Manage with: micropod telemetry show | set <key> <value> | enable|disable <target> | validate
        schema: 1
        service_name: micropod-engine

        prometheus:
          enabled: true
          # Optional TCP scrape listener exposed directly by micropod-vmm (in addition to
          # MicropodAPI's unified /metrics endpoint and per-worker Unix telemetry.sock).
          listen: 127.0.0.1:9464
          path: /metrics

        otlp:
          enabled: false
          # OpenTelemetry OTLP/HTTP JSON metrics receiver (e.g. OTel Collector, Grafana Alloy)
          endpoint: http://127.0.0.1:4318/v1/metrics
          export_interval_secs: 10
          headers: {}
          resource_attributes:
            deployment.environment: local

        tracing:
          # Off by default (zero hot-path overhead). Enable here, via MICROPOD_TRACE=1,
          # or dynamically on a live running worker via `micropod telemetry trace enable`.
          enabled: false
          endpoint: http://127.0.0.1:4318/v1/traces
          sample_rate: 1.0
          slow_op_threshold_ms: 5

        health:
          memory_warn_pct: 90
          vmm_timeout_ms: 2000
        """
    }
}
