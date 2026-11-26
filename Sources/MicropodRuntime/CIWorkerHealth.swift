import Darwin
import Foundation
import MicropodCore

extension CIWorker {
    public enum HealthVerdict: String, Codable, Sendable {
        case healthy
        case degraded
        case unhealthy
    }

    public struct HypervisorTelemetry: Codable, Sendable, Equatable {
        public let pid: Int32
        public let state: String
        public let uptimeMs: Double
        public let ipaGranule: String
        public let numVcpus: Int
        public let vcpusOnline: Int
        public let memoryMib: Int
        public let guestCtrlConnected: Bool
        public let clockSyncCount: UInt64
        public let lastClockSyncUnixSecs: UInt64
        public let hostPhysFootprintMib: Double
        public let hostPeakFootprintMib: Double
        public let balloonReclaimedMib: Double
        public let blkReadOps: UInt64
        public let blkWriteOps: UInt64
        public let blkReadBytes: UInt64
        public let blkWriteBytes: UInt64
        public let fsRequests: UInt64
        public let fsBytesRead: UInt64
        public let fsNodes: UInt64?
        public let fsNodesPeak: UInt64?
        public let fsOpenHandles: UInt64?
        public let fsKeepCacheHits: UInt64?
        public let fsRoCacheHits: UInt64?
        public let fsRoCacheMisses: UInt64?
        public let fsNotifyEvents: UInt64?
        public let fsNotifyEpochResets: UInt64?
        public let fsErrors: UInt64?
        public let netTxPackets: UInt64
        public let netTxBytes: UInt64
        public let netRxPackets: UInt64
        public let netRxBytes: UInt64
        public let publishedBinds: UInt64
        public let publishedConns: UInt64
        public let mmioExits: UInt64
        public let wfiExits: UInt64
        public let tracingEnabled: Bool?
        public let sampledUnixSecs: UInt64

        public init(
            pid: Int32, state: String, uptimeMs: Double, ipaGranule: String,
            numVcpus: Int, vcpusOnline: Int, memoryMib: Int, guestCtrlConnected: Bool,
            clockSyncCount: UInt64, lastClockSyncUnixSecs: UInt64,
            hostPhysFootprintMib: Double, hostPeakFootprintMib: Double, balloonReclaimedMib: Double,
            blkReadOps: UInt64, blkWriteOps: UInt64, blkReadBytes: UInt64, blkWriteBytes: UInt64,
            fsRequests: UInt64, fsBytesRead: UInt64,
            fsNodes: UInt64? = nil, fsNodesPeak: UInt64? = nil, fsOpenHandles: UInt64? = nil,
            fsKeepCacheHits: UInt64? = nil, fsRoCacheHits: UInt64? = nil, fsRoCacheMisses: UInt64? = nil,
            fsNotifyEvents: UInt64? = nil, fsNotifyEpochResets: UInt64? = nil, fsErrors: UInt64? = nil,
            netTxPackets: UInt64, netTxBytes: UInt64, netRxPackets: UInt64, netRxBytes: UInt64,
            publishedBinds: UInt64, publishedConns: UInt64, mmioExits: UInt64, wfiExits: UInt64,
            tracingEnabled: Bool? = nil, sampledUnixSecs: UInt64
        ) {
            self.pid = pid
            self.state = state
            self.uptimeMs = uptimeMs
            self.ipaGranule = ipaGranule
            self.numVcpus = numVcpus
            self.vcpusOnline = vcpusOnline
            self.memoryMib = memoryMib
            self.guestCtrlConnected = guestCtrlConnected
            self.clockSyncCount = clockSyncCount
            self.lastClockSyncUnixSecs = lastClockSyncUnixSecs
            self.hostPhysFootprintMib = hostPhysFootprintMib
            self.hostPeakFootprintMib = hostPeakFootprintMib
            self.balloonReclaimedMib = balloonReclaimedMib
            self.blkReadOps = blkReadOps
            self.blkWriteOps = blkWriteOps
            self.blkReadBytes = blkReadBytes
            self.blkWriteBytes = blkWriteBytes
            self.fsRequests = fsRequests
            self.fsBytesRead = fsBytesRead
            self.fsNodes = fsNodes
            self.fsNodesPeak = fsNodesPeak
            self.fsOpenHandles = fsOpenHandles
            self.fsKeepCacheHits = fsKeepCacheHits
            self.fsRoCacheHits = fsRoCacheHits
            self.fsRoCacheMisses = fsRoCacheMisses
            self.fsNotifyEvents = fsNotifyEvents
            self.fsNotifyEpochResets = fsNotifyEpochResets
            self.fsErrors = fsErrors
            self.netTxPackets = netTxPackets
            self.netTxBytes = netTxBytes
            self.netRxPackets = netRxPackets
            self.netRxBytes = netRxBytes
            self.publishedBinds = publishedBinds
            self.publishedConns = publishedConns
            self.mmioExits = mmioExits
            self.wfiExits = wfiExits
            self.tracingEnabled = tracingEnabled
            self.sampledUnixSecs = sampledUnixSecs
        }
    }

    public struct EngineHealth: Codable, Sendable {
        public let vmm: CIWorkerVMM
        public let engine: String
        public let worker: UUID
        public let instance: UUID
        public let boot: UUID
        public let engineVersion: String
        public let cpus: Int
        public let memoryBytes: UInt64
        public let storageDriver: String
        public let cgroupDriver: String
        public let buildkitAvailable: Bool
    }

    public struct KernelHealthSummary: Codable, Sendable {
        public let uptimeSeconds: Double?
        public let memoryBytes: UInt64?
        public let availableBytes: UInt64?
        public let memoryUsedPct: Double?
        public let oomKills: UInt64?
        public let cpuPressureSomeUsec: UInt64?
        public let memoryPressureSomeUsec: UInt64?
        public let ioPressureSomeUsec: UInt64?
    }

    public struct RuntimeNetworkMetrics: Codable, Sendable {
        public struct DriverStats: Codable, Sendable {
            public let attachAttempts: UInt64
            public let attachErrors: UInt64
            public let attachUsecTotal: UInt64
        }
        public struct PublishedTCP: Codable, Sendable {
            public let kernelLeases: UInt64
            public let macvlanLeases: UInt64
            public let relayLeases: UInt64
            public let rootlessLeases: UInt64
        }
        public struct LinkCounters: Codable, Sendable {
            public let rxBytes: UInt64
            public let txBytes: UInt64
            public let rxDropped: UInt64
            public let txDropped: UInt64
            public let rxErrors: UInt64
            public let txErrors: UInt64
        }
        public let dnsLocalAnswers: UInt64
        public let dnsNameMisses: UInt64
        public let dnsForwarded: UInt64
        public let dnsUpstreamFailures: UInt64
        public let dnsOverloadDrops: UInt64
        public let publishedTcp: PublishedTCP?
        public let bridge: DriverStats?
        public let macvlan: DriverStats?
        public let ipvlan: DriverStats?
        public let macvlanQuarantinedPorts: UInt64?
        public let publishedLink: LinkCounters?
    }

    public struct DockerRouteMetrics: Codable, Sendable, Equatable {
        public let count: UInt64
        public let errors: UInt64
        public let durationUsecTotal: Int64
        public let maxDurationUsec: Int64
    }

    public struct DockerAPIMetrics: Codable, Sendable, Equatable {
        public let requestsTotal: UInt64
        public let errors4xx: UInt64
        public let errors5xx: UInt64
        public let conflicts409: UInt64
        public let notImplemented501: UInt64
        public let slowRequestsTotal: UInt64
        public let durationUsecTotal: Int64
        public let maxDurationUsec: Int64
        public let routes: [String: DockerRouteMetrics]?
    }

    public struct ReaperMetrics: Codable, Sendable, Equatable {
        public let activeSessions: Int64
        public let sessionsStarted: UInt64
        public let sessionsClosed: UInt64
        public let requestsTotal: UInt64
        public let containersReaped: UInt64
        public let networksReaped: UInt64
        public let volumesReaped: UInt64
        public let reapErrors: UInt64
        public let reapDenied: UInt64
        public let reapDurationUsecTotal: Int64
        public let maxReapDurationUsec: Int64
        public let lastReapUnixSecs: Int64
    }

    public struct RuntimeIssue: Codable, Sendable, Equatable {
        public let tsUnixNs: Int64
        public let kind: String
        public let source: String
        public let method: String
        public let route: String
        public let status: Int
        public let durationMs: Double
        public let message: String?
    }

    public struct RuntimeEngineMetrics: Codable, Sendable {
        public let containersCreated: UInt64
        public let runsFinished: UInt64
        public let runtimeFailures: UInt64
        public let imageCacheHits: UInt64
        public let preparedPodsUsed: UInt64
        public let sharedCacheAttachments: UInt64
        public let podMsTotal: Int64
        public let createMsTotal: Int64
        public let startMsTotal: Int64
        public let startParallelismLimit: Int
        public let setupSlotsInUse: Int
        public let setupWaitUsecTotal: Int64
        public let network: RuntimeNetworkMetrics?
        public let api: DockerAPIMetrics?
        public let reaper: ReaperMetrics?
        public let recentIssues: [RuntimeIssue]?
        public let cacheAttach: [String: UInt64]?
        public let cacheSkip: [String: UInt64]?
        public let cacheProbes: UInt64?
        public let cacheProbeFailures: UInt64?
        public let cacheProbeMs: Int64?
        public let cacheEvictions: UInt64?
        public let cacheEvictedUnits: UInt64?
        public let cacheEvictedFiles: UInt64?
        public let cacheEvictedBytes: UInt64?
        public let cacheLastSweepUnix: Int64?

        public init(
            containersCreated: UInt64, runsFinished: UInt64, runtimeFailures: UInt64,
            imageCacheHits: UInt64, preparedPodsUsed: UInt64, sharedCacheAttachments: UInt64,
            podMsTotal: Int64, createMsTotal: Int64, startMsTotal: Int64,
            startParallelismLimit: Int, setupSlotsInUse: Int, setupWaitUsecTotal: Int64,
            network: RuntimeNetworkMetrics?, api: DockerAPIMetrics?, reaper: ReaperMetrics?,
            recentIssues: [RuntimeIssue]?,
            cacheAttach: [String: UInt64]? = nil, cacheSkip: [String: UInt64]? = nil,
            cacheProbes: UInt64? = nil, cacheProbeFailures: UInt64? = nil, cacheProbeMs: Int64? = nil,
            cacheEvictions: UInt64? = nil, cacheEvictedUnits: UInt64? = nil,
            cacheEvictedFiles: UInt64? = nil, cacheEvictedBytes: UInt64? = nil,
            cacheLastSweepUnix: Int64? = nil
        ) {
            self.containersCreated = containersCreated
            self.runsFinished = runsFinished
            self.runtimeFailures = runtimeFailures
            self.imageCacheHits = imageCacheHits
            self.preparedPodsUsed = preparedPodsUsed
            self.sharedCacheAttachments = sharedCacheAttachments
            self.podMsTotal = podMsTotal
            self.createMsTotal = createMsTotal
            self.startMsTotal = startMsTotal
            self.startParallelismLimit = startParallelismLimit
            self.setupSlotsInUse = setupSlotsInUse
            self.setupWaitUsecTotal = setupWaitUsecTotal
            self.network = network
            self.api = api
            self.reaper = reaper
            self.recentIssues = recentIssues
            self.cacheAttach = cacheAttach
            self.cacheSkip = cacheSkip
            self.cacheProbes = cacheProbes
            self.cacheProbeFailures = cacheProbeFailures
            self.cacheProbeMs = cacheProbeMs
            self.cacheEvictions = cacheEvictions
            self.cacheEvictedUnits = cacheEvictedUnits
            self.cacheEvictedFiles = cacheEvictedFiles
            self.cacheEvictedBytes = cacheEvictedBytes
            self.cacheLastSweepUnix = cacheLastSweepUnix
        }
    }

    private struct RawCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// Decodes snake_case Go `/micropod/metrics` JSON (including digit-prefixed segments like
    /// `errors_4xx` and `conflicts_409`) while preserving verbatim dictionary keys under `routes`,
    /// `cache_attach`, and `cache_skip` and keeping camelCase JSON output when `HealthReport` is re-encoded.
    static func makeRuntimeMetricsDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            let last = codingPath.last!
            if codingPath.count >= 2 {
                let parent = codingPath[codingPath.count - 2].stringValue
                if parent == "routes" || parent == "cache_attach" || parent == "cache_skip" {
                    return last
                }
            }
            let parts = last.stringValue.split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count > 1 else { return last }
            var out = String(parts[0])
            for seg in parts.dropFirst() {
                if let first = seg.first {
                    out.append(contentsOf: String(first).uppercased())
                    out.append(contentsOf: seg.dropFirst())
                }
            }
            return RawCodingKey(stringValue: out)
        }
        return decoder
    }

    public struct StorageSummary: Codable, Sendable {
        public let totalBytes: UInt64
        public let usedBytes: UInt64
        public let availableBytes: UInt64
    }

    public struct WorkloadItem: Codable, Sendable {
        public let id: String
        public let name: String
        public let image: String
        public let state: String
        public let status: String
        public let ports: [String]
        public let cpuPct: Double?
        public let cpuUsageNs: UInt64?
        public let cpuUserNs: UInt64?
        public let cpuKernelNs: UInt64?
        public let cpuThrottledPeriods: UInt64?
        public let cpuThrottledNs: UInt64?
        public let memoryUsageBytes: UInt64?
        public let memoryWorkingSetBytes: UInt64?
        public let memoryPeakBytes: UInt64?
        public let memoryLimitBytes: UInt64?
        public let memoryOomKills: UInt64?
        public let pids: UInt64?
        public let pidsLimit: UInt64?
        public let blkReadBytes: UInt64?
        public let blkWriteBytes: UInt64?
        public let blkReadOps: UInt64?
        public let blkWriteOps: UInt64?
        public let netRxBytes: UInt64?
        public let netTxBytes: UInt64?
        public let psiCpuSomeUsec: UInt64?
        public let psiMemorySomeUsec: UInt64?
        public let psiIoSomeUsec: UInt64?
    }

    public struct WorkloadSummary: Codable, Sendable {
        public let runningCount: Int
        public let totalCount: Int
        public let items: [WorkloadItem]
    }

    public struct HealthReport: Codable, Sendable {
        public let verdict: HealthVerdict
        public let warnings: [String]
        public let timestamp: Date
        public let engine: EngineHealth
        public let runtimeEngine: RuntimeEngineMetrics?
        public let storage: StorageSummary?
        public let hypervisor: HypervisorTelemetry?
        public let kernel: KernelHealthSummary?
        public let workloads: WorkloadSummary
        public let cacheStores: [CacheStoreMetrics]
        public let cacheInventory: HVFCacheInspection?
        public let nativeOCI: NativeOCIMetrics?
    }

    /// Perform a live HTTP/1.1 request over the VMM's owner-only Unix telemetry socket (zero metric files!).
    static func queryUnixHTTP(
        socketPath: String, method: String = "GET", path: String, timeoutMs: Int = 2000
    ) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: maxLen) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        let connectRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRC == 0 else { return nil }

        let extraHeader = method == "POST" ? "Content-Length: 0\r\n" : ""
        let req = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\(extraHeader)Connection: close\r\n\r\n"
        let reqBytes = Array(req.utf8)
        let written = reqBytes.withUnsafeBytes { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        guard written == reqBytes.count else { return nil }

        var raw = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                raw.append(contentsOf: chunk[0..<n])
            } else {
                break
            }
        }
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep) else { return nil }
        let header = String(decoding: raw[..<range.lowerBound], as: UTF8.self)
        guard header.hasPrefix("HTTP/1.1 200") || header.hasPrefix("HTTP/1.0 200") else { return nil }
        let body = Data(raw[range.upperBound...])
        if header.lowercased().contains("transfer-encoding: chunked") {
            return decodeChunkedHTTPBody(body)
        }
        return body
    }

    static func decodeChunkedHTTPBody(_ data: Data) -> Data? {
        var out = Data()
        var idx = data.startIndex
        let crlf = Data("\r\n".utf8)
        while idx < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: idx..<data.endIndex) else { break }
            let sizeText =
                String(decoding: data[idx..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let chunkSize = Int(sizeText, radix: 16) else { return nil }
            idx = lineEnd.upperBound
            if chunkSize == 0 {
                return out
            }
            guard idx + chunkSize <= data.endIndex else { return nil }
            out.append(data[idx..<(idx + chunkSize)])
            idx += chunkSize
            if idx + 2 <= data.endIndex && data[idx..<(idx + 2)] == crlf {
                idx += 2
            }
        }
        return out
    }

    public func tracingStatus() throws -> Data {
        let obs = (try? ObservabilityConfig.load(environment: resourceEnvironment)) ?? ObservabilityConfig()
        guard
            let body = Self.queryUnixHTTP(
                socketPath: telemetrySocket.path, method: "GET", path: "/v1/tracing/status",
                timeoutMs: obs.health.vmmTimeoutMs)
        else {
            throw MicropodError.message("HVF telemetry socket is unreachable at \(telemetrySocket.path)")
        }
        return body
    }

    public func setLiveTracing(enabled: Bool) throws -> Data {
        let obs = (try? ObservabilityConfig.load(environment: resourceEnvironment)) ?? ObservabilityConfig()
        let path = enabled ? "/v1/tracing/enable" : "/v1/tracing/disable"
        guard
            let body = Self.queryUnixHTTP(
                socketPath: telemetrySocket.path, method: "POST", path: path,
                timeoutMs: obs.health.vmmTimeoutMs)
        else {
            throw MicropodError.message("HVF telemetry socket is unreachable at \(telemetrySocket.path)")
        }
        return body
    }

    public func clearLiveTraces() throws -> Data {
        let obs = (try? ObservabilityConfig.load(environment: resourceEnvironment)) ?? ObservabilityConfig()
        // Best-effort clear of guest Docker API trace ring as well.
        _ = Self.queryUnixHTTP(
            socketPath: dockerSocket.path, method: "POST", path: "/\(Self.apiVersion)/micropod/traces/clear",
            timeoutMs: obs.health.vmmTimeoutMs)
        guard
            let body = Self.queryUnixHTTP(
                socketPath: telemetrySocket.path, method: "POST", path: "/v1/tracing/clear",
                timeoutMs: obs.health.vmmTimeoutMs)
        else {
            throw MicropodError.message("HVF telemetry socket is unreachable at \(telemetrySocket.path)")
        }
        return body
    }

    public func tracesOTLPJSON() throws -> Data {
        let obs = (try? ObservabilityConfig.load(environment: resourceEnvironment)) ?? ObservabilityConfig()
        var mergedResourceSpans: [[String: Any]] = []
        if let vmmBody = Self.queryUnixHTTP(
            socketPath: telemetrySocket.path, method: "GET", path: "/v1/traces",
            timeoutMs: obs.health.vmmTimeoutMs),
            let root = try? JSONSerialization.jsonObject(with: vmmBody) as? [String: Any],
            let rs = root["resourceSpans"] as? [[String: Any]]
        {
            mergedResourceSpans.append(contentsOf: rs)
        }
        if let guestBody = Self.queryUnixHTTP(
            socketPath: dockerSocket.path, method: "GET", path: "/\(Self.apiVersion)/micropod/traces",
            timeoutMs: obs.health.vmmTimeoutMs),
            let root = try? JSONSerialization.jsonObject(with: guestBody) as? [String: Any],
            let rs = root["resourceSpans"] as? [[String: Any]]
        {
            mergedResourceSpans.append(contentsOf: rs)
        }
        guard !mergedResourceSpans.isEmpty else {
            throw MicropodError.message("Neither HVF telemetry socket nor guest Docker API trace endpoint is reachable")
        }
        return try JSONSerialization.data(
            withJSONObject: ["resourceSpans": mergedResourceSpans], options: [.sortedKeys])
    }

    static func fetchHypervisorTelemetry(socket: URL, timeoutMs: Int = 2000) -> HypervisorTelemetry? {
        guard let body = queryUnixHTTP(socketPath: socket.path, path: "/healthz", timeoutMs: timeoutMs) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(HypervisorTelemetry.self, from: body)
    }

    static func fetchHypervisorPrometheus(socket: URL, timeoutMs: Int = 2000) -> String? {
        guard let body = queryUnixHTTP(socketPath: socket.path, path: "/metrics", timeoutMs: timeoutMs) else {
            return nil
        }
        return String(decoding: body, as: UTF8.self)
    }

    static func evaluateHealth(
        vmm: CIWorkerVMM,
        hypervisor: HypervisorTelemetry?,
        kernel: KernelHealthSummary?,
        nativeOCI: NativeOCIMetrics?,
        runtimeEngine: RuntimeEngineMetrics? = nil,
        cacheInventory: HVFCacheInspection? = nil,
        thresholds: ObservabilityConfig.HealthThresholds = .init()
    ) -> (verdict: HealthVerdict, warnings: [String]) {
        var verdict: HealthVerdict = .healthy
        var warnings: [String] = []
        func escalate(_ level: HealthVerdict, _ message: String) {
            warnings.append(message)
            if level == .unhealthy || (level == .degraded && verdict == .healthy) {
                verdict = level
            }
        }

        if vmm == .hvf {
            if let hv = hypervisor {
                if hv.state != "running" {
                    escalate(.unhealthy, "HVF hypervisor state is '\(hv.state)'")
                }
                if !hv.guestCtrlConnected {
                    escalate(.degraded, "HVF guest control channel (vsock 2379) is disconnected")
                }
                if hv.vcpusOnline < hv.numVcpus {
                    escalate(.degraded, "Only \(hv.vcpusOnline)/\(hv.numVcpus) vCPUs are online")
                }
                if let fsErr = hv.fsErrors, fsErr > 0 {
                    escalate(.degraded, "Virtio-FS reported \(fsErr) non-routine host error(s)")
                }
                if let epochs = hv.fsNotifyEpochResets, epochs > 0 {
                    escalate(.degraded, "Virtio-FS notification queue triggered \(epochs) epoch reset(s)")
                }
            } else {
                escalate(.degraded, "HVF live telemetry socket is unreachable")
            }
        }

        if let k = kernel {
            if let oom = k.oomKills, oom > 0 {
                escalate(.degraded, "Guest kernel recorded \(oom) OOM kill(s) since boot")
            }
            if let usedPct = k.memoryUsedPct, usedPct >= thresholds.memoryWarnPct {
                escalate(.degraded, "Guest memory utilization is high (\(String(format: "%.1f", usedPct))%)")
            }
        }

        if let oci = nativeOCI, oci.draining {
            escalate(.degraded, "Native OCI worker is currently draining")
        }

        if let re = runtimeEngine {
            if re.runtimeFailures > 0 {
                escalate(.degraded, "Guest runtime engine recorded \(re.runtimeFailures) container failure(s)")
            }
            if let api = re.api, api.errors5xx > 0 {
                escalate(.degraded, "Docker API returned \(api.errors5xx) server error(s) (5xx)")
            }
            if let reaper = re.reaper, reaper.reapErrors > 0 {
                escalate(.degraded, "Ryuk session reaper recorded \(reaper.reapErrors) cleanup error(s)")
            }
            if let net = re.network {
                if let quarantined = net.macvlanQuarantinedPorts, quarantined > 0 {
                    escalate(.degraded, "Published-port macvlan has \(quarantined) quarantined port(s)")
                }
                if net.dnsOverloadDrops > 0 {
                    escalate(.degraded, "Guest DNS dropped \(net.dnsOverloadDrops) query(s) due to overload")
                }
            }
            if let probeFails = re.cacheProbeFailures, probeFails > 0 {
                escalate(.degraded, "Guest cache image probe failed \(probeFails) time(s)")
            }
            if let storeFails = re.cacheSkip?["store-failed"], storeFails > 0 {
                escalate(.degraded, "Guest cache skipped \(storeFails) attachment(s) due to store-failed")
            }
        }

        if let budget = cacheInventory?.budget, let pct = budget.utilizationPct, pct >= 85.0 {
            escalate(.degraded, "Guest cache budget utilization is high (\(String(format: "%.1f", pct))%)")
        }

        // A cache disk that should be mounted but is not turns shared caches
        // off for the whole boot: every container runs uncached.
        if let why = cacheInventory?.sharedCachesOffReason {
            escalate(.degraded, "Guest shared caches are off this boot (cache-disk-unavailable): \(why)")
        } else if let noDisk = runtimeEngine?.cacheSkip?["cache-disk-unavailable"], noDisk > 0 {
            escalate(
                .degraded, "Guest cache skipped \(noDisk) attachment(s) due to cache-disk-unavailable")
        }

        return (verdict, warnings)
    }

    /// Unified engine, hypervisor, guest kernel, cache store, and live workload health snapshot
    /// queried live over Unix sockets (zero metric files on disk).
    public func health() async throws -> HealthReport {
        let obs = (try? ObservabilityConfig.load(environment: resourceEnvironment)) ?? ObservabilityConfig()
        let current = try await status()
        let api = DockerClient(endpoint: .unix(dockerSocket.path), apiVersion: Self.apiVersion)

        async let containersReq = api.request("GET", "/containers/json", query: ["all": "1"], timeout: .seconds(5))
        async let volumesReq = api.request("GET", "/volumes", timeout: .seconds(5))
        async let buildkitReq = api.request("GET", "/micropod/buildkit", timeout: .seconds(3))
        async let engineMetricsReq = api.request("GET", "/micropod/metrics", timeout: .seconds(3))
        async let storageReq = api.request("GET", "/micropod/storage", timeout: .seconds(3))
        async let cachesReq = api.request("GET", "/micropod/caches", timeout: .seconds(5))
        async let kernelReq: KernelMetrics? = try? await kernelMetrics()
        async let ociReq: NativeOCIMetrics? = try? await nativeMetrics()

        let (containersResp, volumesResp, buildkitResp, engineMetricsResp, storageResp, cachesResp, km, oci) =
            try await (
                containersReq, volumesReq, buildkitReq, engineMetricsReq, storageReq, cachesReq, kernelReq, ociReq
            )

        let metricsDecoder = Self.makeRuntimeMetricsDecoder()
        let snakeDecoder = JSONDecoder()
        snakeDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let runtimeEngineMetrics: RuntimeEngineMetrics? =
            engineMetricsResp.status == 200
            ? try? metricsDecoder.decode(RuntimeEngineMetrics.self, from: engineMetricsResp.body)
            : nil
        let storageSummary: StorageSummary? =
            storageResp.status == 200
            ? try? snakeDecoder.decode(StorageSummary.self, from: storageResp.body)
            : nil
        let cacheInventory: HVFCacheInspection? =
            cachesResp.status == 200
            ? try? JSONDecoder().decode(HVFCacheInspection.self, from: cachesResp.body)
            : nil

        struct RawContainer: Decodable {
            struct Port: Decodable {
                enum CodingKeys: String, CodingKey {
                    case IP, PrivatePort, PublicPort
                    case proto = "Type"
                }
                let IP: String?
                let PrivatePort: Int
                let PublicPort: Int?
                let proto: String?
            }
            struct Mount: Decodable {
                enum CodingKeys: String, CodingKey {
                    case type = "Type"
                    case Name
                }
                let type: String
                let Name: String?
            }
            let Id: String
            let Names: [String]?
            let Image: String
            let State: String
            let Status: String
            let Ports: [Port]?
            let Mounts: [Mount]?
        }
        struct RawStats: Decodable {
            struct CPUStats: Decodable {
                struct Usage: Decodable {
                    let total_usage: UInt64?
                    let usage_in_usermode: UInt64?
                    let usage_in_kernelmode: UInt64?
                }
                struct Throttling: Decodable {
                    let periods: UInt64?
                    let throttled_periods: UInt64?
                    let throttled_time: UInt64?
                }
                let cpu_usage: Usage?
                let system_cpu_usage: UInt64?
                let online_cpus: UInt64?
                let throttling_data: Throttling?
            }
            struct MemStats: Decodable {
                struct Detail: Decodable { let inactive_file: UInt64? }
                struct Events: Decodable {
                    let high: UInt64?
                    let max: UInt64?
                    let oom: UInt64?
                    let oom_kill: UInt64?
                }
                let usage: UInt64?
                let max_usage: UInt64?
                let limit: UInt64?
                let stats: Detail?
                let events: Events?
            }
            struct PidsStats: Decodable {
                let current: UInt64?
                let limit: UInt64?
            }
            struct BlkioEntry: Decodable {
                let op: String
                let value: UInt64
            }
            struct BlkioStats: Decodable {
                let io_service_bytes_recursive: [BlkioEntry]?
                let io_serviced_recursive: [BlkioEntry]?
            }
            struct NetStat: Decodable {
                let rx_bytes: UInt64?
                let tx_bytes: UInt64?
            }
            struct PSIStats: Decodable {
                let cpu_some_usec: UInt64?
                let memory_some_usec: UInt64?
                let io_some_usec: UInt64?
            }
            let cpu_stats: CPUStats?
            let precpu_stats: CPUStats?
            let memory_stats: MemStats?
            let pids_stats: PidsStats?
            let blkio_stats: BlkioStats?
            let networks: [String: NetStat]?
            let psi_stats: PSIStats?
        }
        struct RawVolumeList: Decodable {
            struct Volume: Decodable { let Name: String }
            let Volumes: [Volume]?
        }

        let decoder = JSONDecoder()
        let rawContainers =
            containersResp.status == 200
            ? (try? decoder.decode([RawContainer].self, from: containersResp.body)) ?? []
            : []

        let runningIds = rawContainers.filter { $0.State.lowercased() == "running" }.prefix(16).map(\.Id)
        var statsByID = [String: RawStats]()
        if !runningIds.isEmpty {
            let sockPath = dockerSocket.path
            let ver = Self.apiVersion
            await withTaskGroup(of: (String, RawStats?).self) { group in
                for id in runningIds {
                    group.addTask {
                        let c = DockerClient(endpoint: .unix(sockPath), apiVersion: ver)
                        guard
                            let resp = try? await c.request(
                                "GET", "/containers/\(id)/stats", query: ["stream": "false"], timeout: .seconds(2)
                            ), resp.status == 200,
                            let parsed = try? JSONDecoder().decode(RawStats.self, from: resp.body)
                        else { return (id, nil) }
                        return (id, parsed)
                    }
                }
                for await (id, st) in group {
                    if let st { statsByID[id] = st }
                }
            }
        }

        var attachments = [String: Int]()
        var items: [WorkloadItem] = []
        items.reserveCapacity(rawContainers.count)
        for c in rawContainers {
            let isRunning = c.State.lowercased() == "running"
            if isRunning {
                for name in Set((c.Mounts ?? []).filter { $0.type == "volume" }.compactMap(\.Name)) {
                    attachments[name, default: 0] += 1
                }
            }
            let name = (c.Names?.first ?? c.Id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let ports = (c.Ports ?? []).map { p -> String in
                let proto = p.proto ?? "tcp"
                if let pub = p.PublicPort {
                    let ip = p.IP ?? "127.0.0.1"
                    return "\(ip):\(pub)->\(p.PrivatePort)/\(proto)"
                }
                return "\(p.PrivatePort)/\(proto)"
            }
            let st = statsByID[c.Id]
            var cpuPct: Double?
            if let cur = st?.cpu_stats?.cpu_usage?.total_usage,
                let prev = st?.precpu_stats?.cpu_usage?.total_usage,
                let sysCur = st?.cpu_stats?.system_cpu_usage,
                let sysPrev = st?.precpu_stats?.system_cpu_usage,
                cur >= prev, sysCur > sysPrev
            {
                let cpuDelta = Double(cur - prev)
                let sysDelta = Double(sysCur - sysPrev)
                let ncpu = Double(max(1, st?.cpu_stats?.online_cpus ?? UInt64(current.cpus)))
                cpuPct = ((cpuDelta / sysDelta) * ncpu * 10000.0).rounded() / 100.0
            }
            let usageBytes = st?.memory_stats?.usage
            let workingSetBytes: UInt64? =
                if let u = usageBytes {
                    u >= (st?.memory_stats?.stats?.inactive_file ?? 0)
                        ? u - (st?.memory_stats?.stats?.inactive_file ?? 0) : u
                } else {
                    nil
                }
            let blkBytes = st?.blkio_stats?.io_service_bytes_recursive ?? []
            let blkOps = st?.blkio_stats?.io_serviced_recursive ?? []
            let blkReadB: UInt64? =
                blkBytes.isEmpty ? nil : blkBytes.filter { $0.op == "Read" }.reduce(0) { $0 + $1.value }
            let blkWriteB: UInt64? =
                blkBytes.isEmpty ? nil : blkBytes.filter { $0.op == "Write" }.reduce(0) { $0 + $1.value }
            let blkReadO: UInt64? = blkOps.isEmpty ? nil : blkOps.filter { $0.op == "Read" }.reduce(0) { $0 + $1.value }
            let blkWriteO: UInt64? =
                blkOps.isEmpty ? nil : blkOps.filter { $0.op == "Write" }.reduce(0) { $0 + $1.value }
            let nets = st?.networks ?? [:]
            let netRx: UInt64? = nets.isEmpty ? nil : nets.values.reduce(0) { $0 + ($1.rx_bytes ?? 0) }
            let netTx: UInt64? = nets.isEmpty ? nil : nets.values.reduce(0) { $0 + ($1.tx_bytes ?? 0) }
            items.append(
                WorkloadItem(
                    id: String(c.Id.prefix(12)),
                    name: name,
                    image: c.Image,
                    state: c.State,
                    status: c.Status,
                    ports: ports,
                    cpuPct: cpuPct,
                    cpuUsageNs: st?.cpu_stats?.cpu_usage?.total_usage,
                    cpuUserNs: st?.cpu_stats?.cpu_usage?.usage_in_usermode,
                    cpuKernelNs: st?.cpu_stats?.cpu_usage?.usage_in_kernelmode,
                    cpuThrottledPeriods: st?.cpu_stats?.throttling_data?.throttled_periods,
                    cpuThrottledNs: st?.cpu_stats?.throttling_data?.throttled_time,
                    memoryUsageBytes: usageBytes,
                    memoryWorkingSetBytes: workingSetBytes,
                    memoryPeakBytes: st?.memory_stats?.max_usage,
                    memoryLimitBytes: st?.memory_stats?.limit,
                    memoryOomKills: st?.memory_stats?.events?.oom_kill,
                    pids: st?.pids_stats?.current,
                    pidsLimit: st?.pids_stats?.limit,
                    blkReadBytes: blkReadB,
                    blkWriteBytes: blkWriteB,
                    blkReadOps: blkReadO,
                    blkWriteOps: blkWriteO,
                    netRxBytes: netRx,
                    netTxBytes: netTx,
                    psiCpuSomeUsec: st?.psi_stats?.cpu_some_usec,
                    psiMemorySomeUsec: st?.psi_stats?.memory_some_usec,
                    psiIoSomeUsec: st?.psi_stats?.io_some_usec
                ))
        }
        items.sort { ($0.state == "running" ? 0 : 1, $0.name) < ($1.state == "running" ? 0 : 1, $1.name) }

        let stores =
            (volumesResp.status == 200
            ? (try? decoder.decode(RawVolumeList.self, from: volumesResp.body).Volumes) ?? []
            : [])
            .compactMap { v in Self.cacheStore(v.Name, activeContainers: attachments[v.Name, default: 0]) }
            .sorted { $0.volume < $1.volume }

        let kernelSummary: KernelHealthSummary? = km.map { k in
            let usedPct: Double? =
                if let total = k.memoryBytes, total > 0, let avail = k.availableBytes, avail <= total {
                    ((Double(total - avail) / Double(total)) * 1000.0).rounded() / 10.0
                } else {
                    nil
                }
            return KernelHealthSummary(
                uptimeSeconds: k.uptimeSeconds,
                memoryBytes: k.memoryBytes,
                availableBytes: k.availableBytes,
                memoryUsedPct: usedPct,
                oomKills: k.oomKills,
                cpuPressureSomeUsec: k.cpu.someUsec,
                memoryPressureSomeUsec: k.memory.someUsec,
                ioPressureSomeUsec: k.io.someUsec)
        }

        let hvTelemetry =
            current.vmm == .hvf
            ? Self.fetchHypervisorTelemetry(socket: telemetrySocket, timeoutMs: obs.health.vmmTimeoutMs)
            : nil
        let (verdict, warnings) = Self.evaluateHealth(
            vmm: current.vmm ?? .vz, hypervisor: hvTelemetry, kernel: kernelSummary, nativeOCI: oci,
            runtimeEngine: runtimeEngineMetrics, cacheInventory: cacheInventory, thresholds: obs.health)

        return HealthReport(
            verdict: verdict,
            warnings: warnings,
            timestamp: Date(),
            engine: EngineHealth(
                vmm: current.vmm ?? .vz,
                engine: current.engine,
                worker: current.worker,
                instance: current.instance,
                boot: current.boot,
                engineVersion: current.engineVersion,
                cpus: current.cpus,
                memoryBytes: current.memoryBytes,
                storageDriver: current.storageDriver,
                cgroupDriver: current.cgroupDriver,
                buildkitAvailable: buildkitResp.status == 200
                    && FileManager.default.fileExists(atPath: buildkitSocket.path)
            ),
            runtimeEngine: runtimeEngineMetrics,
            storage: storageSummary,
            hypervisor: hvTelemetry,
            kernel: kernelSummary,
            workloads: WorkloadSummary(
                runningCount: rawContainers.filter { $0.State.lowercased() == "running" }.count,
                totalCount: rawContainers.count,
                items: items
            ),
            cacheStores: stores,
            cacheInventory: cacheInventory,
            nativeOCI: oci)
    }

    private static func promEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Unified Prometheus / OpenMetrics exposition combining live VMM, guest kernel, workload & cache metrics.
    public func prometheusMetrics() async throws -> String {
        let obs = (try? ObservabilityConfig.load(environment: resourceEnvironment)) ?? ObservabilityConfig()
        let report = try await health()
        var lines: [String] = []

        if report.engine.vmm == .hvf,
            let vmmProm = Self.fetchHypervisorPrometheus(socket: telemetrySocket, timeoutMs: obs.health.vmmTimeoutMs)
        {
            lines.append(vmmProm.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let workerLabel = Self.promEscape(report.engine.worker.uuidString)
        let vmmLabel = report.engine.vmm.rawValue
        lines.append("# HELP micropod_engine_health_status 1 for the active engine health verdict.")
        lines.append("# TYPE micropod_engine_health_status gauge")
        for v in [HealthVerdict.healthy, .degraded, .unhealthy] {
            let val = report.verdict == v ? 1 : 0
            lines.append(
                "micropod_engine_health_status{vmm=\"\(vmmLabel)\",worker=\"\(workerLabel)\",verdict=\"\(v.rawValue)\"} \(val)"
            )
        }
        lines.append("# HELP micropod_buildkit_available 1 when BuildKit gRPC is available on the worker.")
        lines.append("# TYPE micropod_buildkit_available gauge")
        lines.append(
            "micropod_buildkit_available{worker=\"\(workerLabel)\"} \(report.engine.buildkitAvailable ? 1 : 0)")

        if let k = report.kernel {
            if let up = k.uptimeSeconds {
                lines.append("# HELP micropod_guest_uptime_seconds Guest Linux kernel uptime in seconds.")
                lines.append("# TYPE micropod_guest_uptime_seconds gauge")
                lines.append("micropod_guest_uptime_seconds{worker=\"\(workerLabel)\"} \(String(format: "%.3f", up))")
            }
            if let mem = k.memoryBytes {
                lines.append("# HELP micropod_guest_memory_bytes Guest Linux total memory in bytes.")
                lines.append("# TYPE micropod_guest_memory_bytes gauge")
                lines.append("micropod_guest_memory_bytes{worker=\"\(workerLabel)\"} \(mem)")
            }
            if let avail = k.availableBytes {
                lines.append("# HELP micropod_guest_memory_available_bytes Guest Linux MemAvailable in bytes.")
                lines.append("# TYPE micropod_guest_memory_available_bytes gauge")
                lines.append("micropod_guest_memory_available_bytes{worker=\"\(workerLabel)\"} \(avail)")
            }
            if let oom = k.oomKills {
                lines.append("# HELP micropod_guest_oom_kills_total Guest Linux OOM kills since boot.")
                lines.append("# TYPE micropod_guest_oom_kills_total counter")
                lines.append("micropod_guest_oom_kills_total{worker=\"\(workerLabel)\"} \(oom)")
            }
            lines.append("# HELP micropod_guest_psi_some_microseconds_total Guest PSI 'some' stall microseconds.")
            lines.append("# TYPE micropod_guest_psi_some_microseconds_total counter")
            if let c = k.cpuPressureSomeUsec {
                lines.append(
                    "micropod_guest_psi_some_microseconds_total{worker=\"\(workerLabel)\",resource=\"cpu\"} \(c)")
            }
            if let m = k.memoryPressureSomeUsec {
                lines.append(
                    "micropod_guest_psi_some_microseconds_total{worker=\"\(workerLabel)\",resource=\"memory\"} \(m)")
            }
            if let io = k.ioPressureSomeUsec {
                lines.append(
                    "micropod_guest_psi_some_microseconds_total{worker=\"\(workerLabel)\",resource=\"io\"} \(io)")
            }
        }

        lines.append("# HELP micropod_workloads_running Number of currently running containers.")
        lines.append("# TYPE micropod_workloads_running gauge")
        lines.append("micropod_workloads_running{worker=\"\(workerLabel)\"} \(report.workloads.runningCount)")
        lines.append("# HELP micropod_workloads_total Total containers present on the worker.")
        lines.append("# TYPE micropod_workloads_total gauge")
        lines.append("micropod_workloads_total{worker=\"\(workerLabel)\"} \(report.workloads.totalCount)")

        let runningItems = report.workloads.items.filter { $0.state.lowercased() == "running" }
        if !runningItems.isEmpty {
            lines.append(
                "# HELP micropod_container_cpu_usage_seconds_total Cumulative container CPU time consumed in seconds (cgroup v2)."
            )
            lines.append("# TYPE micropod_container_cpu_usage_seconds_total counter")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let ns = w.cpuUsageNs {
                    lines.append(
                        "micropod_container_cpu_usage_seconds_total{\(lbl)} \(String(format: "%.6f", Double(ns) / 1_000_000_000.0))"
                    )
                }
            }
            lines.append(
                "# HELP micropod_container_cpu_throttled_seconds_total Cumulative container CPU throttled duration in seconds (cgroup v2)."
            )
            lines.append("# TYPE micropod_container_cpu_throttled_seconds_total counter")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let ns = w.cpuThrottledNs {
                    lines.append(
                        "micropod_container_cpu_throttled_seconds_total{\(lbl)} \(String(format: "%.6f", Double(ns) / 1_000_000_000.0))"
                    )
                }
            }
            lines.append(
                "# HELP micropod_container_memory_usage_bytes Live container memory usage in bytes (cgroup v2).")
            lines.append("# TYPE micropod_container_memory_usage_bytes gauge")
            lines.append("# HELP micropod_workload_memory_usage_bytes Live container memory usage in bytes.")
            lines.append("# TYPE micropod_workload_memory_usage_bytes gauge")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let mem = w.memoryUsageBytes {
                    lines.append("micropod_container_memory_usage_bytes{\(lbl)} \(mem)")
                    lines.append(
                        "micropod_workload_memory_usage_bytes{worker=\"\(workerLabel)\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\"} \(mem)"
                    )
                }
            }
            lines.append(
                "# HELP micropod_container_memory_working_set_bytes Live container non-reclaimable working set memory in bytes."
            )
            lines.append("# TYPE micropod_container_memory_working_set_bytes gauge")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let ws = w.memoryWorkingSetBytes {
                    lines.append("micropod_container_memory_working_set_bytes{\(lbl)} \(ws)")
                }
            }
            lines.append(
                "# HELP micropod_container_memory_peak_bytes Peak container memory footprint in bytes (cgroup v2 memory.peak)."
            )
            lines.append("# TYPE micropod_container_memory_peak_bytes gauge")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let peak = w.memoryPeakBytes {
                    lines.append("micropod_container_memory_peak_bytes{\(lbl)} \(peak)")
                }
            }
            lines.append(
                "# HELP micropod_container_memory_oom_kills_total Per-container cgroup v2 OOM kills (memory.events oom_kill)."
            )
            lines.append("# TYPE micropod_container_memory_oom_kills_total counter")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let oom = w.memoryOomKills {
                    lines.append("micropod_container_memory_oom_kills_total{\(lbl)} \(oom)")
                }
            }
            lines.append(
                "# HELP micropod_container_pids_current Live container process count (cgroup v2 pids.current).")
            lines.append("# TYPE micropod_container_pids_current gauge")
            lines.append("# HELP micropod_workload_pids Live container process count.")
            lines.append("# TYPE micropod_workload_pids gauge")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let pids = w.pids {
                    lines.append("micropod_container_pids_current{\(lbl)} \(pids)")
                    lines.append(
                        "micropod_workload_pids{worker=\"\(workerLabel)\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\"} \(pids)"
                    )
                }
            }
            lines.append(
                "# HELP micropod_container_blkio_bytes_total Per-container block I/O bytes (cgroup v2 io.stat).")
            lines.append("# TYPE micropod_container_blkio_bytes_total counter")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let rb = w.blkReadBytes {
                    lines.append("micropod_container_blkio_bytes_total{\(lbl),op=\"read\"} \(rb)")
                }
                if let wb = w.blkWriteBytes {
                    lines.append("micropod_container_blkio_bytes_total{\(lbl),op=\"write\"} \(wb)")
                }
            }
            lines.append(
                "# HELP micropod_container_network_bytes_total Per-container network bytes transferred (/proc/<pid>/net/dev)."
            )
            lines.append("# TYPE micropod_container_network_bytes_total counter")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let rx = w.netRxBytes {
                    lines.append("micropod_container_network_bytes_total{\(lbl),dir=\"rx\"} \(rx)")
                }
                if let tx = w.netTxBytes {
                    lines.append("micropod_container_network_bytes_total{\(lbl),dir=\"tx\"} \(tx)")
                }
            }
            lines.append(
                "# HELP micropod_container_psi_some_microseconds_total Per-container cgroup v2 PSI 'some' stall microseconds."
            )
            lines.append("# TYPE micropod_container_psi_some_microseconds_total counter")
            for w in runningItems {
                let lbl =
                    "worker=\"\(workerLabel)\",container_id=\"\(Self.promEscape(w.id))\",name=\"\(Self.promEscape(w.name))\",image=\"\(Self.promEscape(w.image))\""
                if let c = w.psiCpuSomeUsec {
                    lines.append("micropod_container_psi_some_microseconds_total{\(lbl),resource=\"cpu\"} \(c)")
                }
                if let m = w.psiMemorySomeUsec {
                    lines.append("micropod_container_psi_some_microseconds_total{\(lbl),resource=\"memory\"} \(m)")
                }
                if let io = w.psiIoSomeUsec {
                    lines.append("micropod_container_psi_some_microseconds_total{\(lbl),resource=\"io\"} \(io)")
                }
            }
        }

        if let re = report.runtimeEngine {
            lines.append(
                "# HELP micropod_runtime_containers_created_total Total containers created by the guest runtime engine since boot."
            )
            lines.append("# TYPE micropod_runtime_containers_created_total counter")
            lines.append("micropod_runtime_containers_created_total{worker=\"\(workerLabel)\"} \(re.containersCreated)")
            lines.append("# HELP micropod_runtime_runs_finished_total Total container runs completed since boot.")
            lines.append("# TYPE micropod_runtime_runs_finished_total counter")
            lines.append("micropod_runtime_runs_finished_total{worker=\"\(workerLabel)\"} \(re.runsFinished)")
            lines.append(
                "# HELP micropod_runtime_failures_total Total container runtime start/execution failures since boot.")
            lines.append("# TYPE micropod_runtime_failures_total counter")
            lines.append("micropod_runtime_failures_total{worker=\"\(workerLabel)\"} \(re.runtimeFailures)")
            lines.append(
                "# HELP micropod_runtime_image_cache_hits_total Total container runs served from warm local image cache."
            )
            lines.append("# TYPE micropod_runtime_image_cache_hits_total counter")
            lines.append("micropod_runtime_image_cache_hits_total{worker=\"\(workerLabel)\"} \(re.imageCacheHits)")
            lines.append(
                "# HELP micropod_runtime_phase_duration_milliseconds_total Cumulative guest container lifecycle phase duration in ms."
            )
            lines.append("# TYPE micropod_runtime_phase_duration_milliseconds_total counter")
            lines.append(
                "micropod_runtime_phase_duration_milliseconds_total{worker=\"\(workerLabel)\",phase=\"pod\"} \(re.podMsTotal)"
            )
            lines.append(
                "micropod_runtime_phase_duration_milliseconds_total{worker=\"\(workerLabel)\",phase=\"create\"} \(re.createMsTotal)"
            )
            lines.append(
                "micropod_runtime_phase_duration_milliseconds_total{worker=\"\(workerLabel)\",phase=\"start\"} \(re.startMsTotal)"
            )
            lines.append("# HELP micropod_runtime_setup_slots_in_use Active concurrent container setup slots.")
            lines.append("# TYPE micropod_runtime_setup_slots_in_use gauge")
            lines.append("micropod_runtime_setup_slots_in_use{worker=\"\(workerLabel)\"} \(re.setupSlotsInUse)")
            lines.append(
                "# HELP micropod_runtime_setup_wait_microseconds_total Cumulative container start admission wait microseconds."
            )
            lines.append("# TYPE micropod_runtime_setup_wait_microseconds_total counter")
            lines.append(
                "micropod_runtime_setup_wait_microseconds_total{worker=\"\(workerLabel)\"} \(re.setupWaitUsecTotal)")
            if let net = re.network {
                lines.append("# HELP micropod_runtime_dns_queries_total Guest embedded DNS queries by outcome.")
                lines.append("# TYPE micropod_runtime_dns_queries_total counter")
                lines.append(
                    "micropod_runtime_dns_queries_total{worker=\"\(workerLabel)\",outcome=\"local\"} \(net.dnsLocalAnswers)"
                )
                lines.append(
                    "micropod_runtime_dns_queries_total{worker=\"\(workerLabel)\",outcome=\"forwarded\"} \(net.dnsForwarded)"
                )
                lines.append(
                    "micropod_runtime_dns_queries_total{worker=\"\(workerLabel)\",outcome=\"miss\"} \(net.dnsNameMisses)"
                )
                lines.append(
                    "micropod_runtime_dns_queries_total{worker=\"\(workerLabel)\",outcome=\"error\"} \(net.dnsUpstreamFailures)"
                )
                if let link = net.publishedLink {
                    lines.append(
                        "# HELP micropod_runtime_published_link_bytes_total Guest published-port link interface bytes.")
                    lines.append("# TYPE micropod_runtime_published_link_bytes_total counter")
                    lines.append(
                        "micropod_runtime_published_link_bytes_total{worker=\"\(workerLabel)\",dir=\"rx\"} \(link.rxBytes)"
                    )
                    lines.append(
                        "micropod_runtime_published_link_bytes_total{worker=\"\(workerLabel)\",dir=\"tx\"} \(link.txBytes)"
                    )
                }
            }
            if let api = re.api {
                lines.append(
                    "# HELP micropod_docker_api_requests_total Total Docker Engine API requests handled by the guest runner."
                )
                lines.append("# TYPE micropod_docker_api_requests_total counter")
                lines.append("micropod_docker_api_requests_total{worker=\"\(workerLabel)\"} \(api.requestsTotal)")
                lines.append(
                    "# HELP micropod_docker_api_errors_total Docker Engine API error responses by status class.")
                lines.append("# TYPE micropod_docker_api_errors_total counter")
                lines.append(
                    "micropod_docker_api_errors_total{worker=\"\(workerLabel)\",class=\"4xx\"} \(api.errors4xx)")
                lines.append(
                    "micropod_docker_api_errors_total{worker=\"\(workerLabel)\",class=\"5xx\"} \(api.errors5xx)")
                lines.append(
                    "micropod_docker_api_errors_total{worker=\"\(workerLabel)\",class=\"409\"} \(api.conflicts409)")
                lines.append(
                    "micropod_docker_api_errors_total{worker=\"\(workerLabel)\",class=\"501\"} \(api.notImplemented501)"
                )
                lines.append(
                    "# HELP micropod_docker_api_slow_requests_total Non-streaming Docker API requests exceeding 50 ms.")
                lines.append("# TYPE micropod_docker_api_slow_requests_total counter")
                lines.append(
                    "micropod_docker_api_slow_requests_total{worker=\"\(workerLabel)\"} \(api.slowRequestsTotal)")
                lines.append(
                    "# HELP micropod_docker_api_duration_microseconds_total Cumulative non-streaming Docker API request duration in microseconds."
                )
                lines.append("# TYPE micropod_docker_api_duration_microseconds_total counter")
                lines.append(
                    "micropod_docker_api_duration_microseconds_total{worker=\"\(workerLabel)\"} \(api.durationUsecTotal)"
                )
                if let routes = api.routes, !routes.isEmpty {
                    lines.append(
                        "# HELP micropod_docker_api_route_requests_total Docker API requests by normalized route.")
                    lines.append("# TYPE micropod_docker_api_route_requests_total counter")
                    lines.append(
                        "# HELP micropod_docker_api_route_duration_microseconds_total Cumulative Docker API latency by normalized route."
                    )
                    lines.append("# TYPE micropod_docker_api_route_duration_microseconds_total counter")
                    for (route, rs) in routes.sorted(by: { $0.key < $1.key }) {
                        let rEsc = Self.promEscape(route)
                        lines.append(
                            "micropod_docker_api_route_requests_total{worker=\"\(workerLabel)\",route=\"\(rEsc)\"} \(rs.count)"
                        )
                        lines.append(
                            "micropod_docker_api_route_duration_microseconds_total{worker=\"\(workerLabel)\",route=\"\(rEsc)\"} \(rs.durationUsecTotal)"
                        )
                    }
                }
            }
            if let reaper = re.reaper {
                lines.append("# HELP micropod_reaper_active_sessions Active Testcontainers Ryuk cleanup sessions.")
                lines.append("# TYPE micropod_reaper_active_sessions gauge")
                lines.append("micropod_reaper_active_sessions{worker=\"\(workerLabel)\"} \(reaper.activeSessions)")
                lines.append("# HELP micropod_reaper_sessions_started_total Total Ryuk cleanup sessions started.")
                lines.append("# TYPE micropod_reaper_sessions_started_total counter")
                lines.append(
                    "micropod_reaper_sessions_started_total{worker=\"\(workerLabel)\"} \(reaper.sessionsStarted)")
                lines.append("# HELP micropod_reaper_reaped_total Resources automatically reaped by Ryuk by kind.")
                lines.append("# TYPE micropod_reaper_reaped_total counter")
                lines.append(
                    "micropod_reaper_reaped_total{worker=\"\(workerLabel)\",kind=\"container\"} \(reaper.containersReaped)"
                )
                lines.append(
                    "micropod_reaper_reaped_total{worker=\"\(workerLabel)\",kind=\"network\"} \(reaper.networksReaped)")
                lines.append(
                    "micropod_reaper_reaped_total{worker=\"\(workerLabel)\",kind=\"volume\"} \(reaper.volumesReaped)")
                lines.append("# HELP micropod_reaper_errors_total Failed or denied Ryuk cleanup operations.")
                lines.append("# TYPE micropod_reaper_errors_total counter")
                lines.append(
                    "micropod_reaper_errors_total{worker=\"\(workerLabel)\",kind=\"error\"} \(reaper.reapErrors)")
                lines.append(
                    "micropod_reaper_errors_total{worker=\"\(workerLabel)\",kind=\"denied\"} \(reaper.reapDenied)")
                lines.append(
                    "# HELP micropod_reaper_duration_microseconds_total Cumulative Ryuk resource delete duration in microseconds."
                )
                lines.append("# TYPE micropod_reaper_duration_microseconds_total counter")
                lines.append(
                    "micropod_reaper_duration_microseconds_total{worker=\"\(workerLabel)\"} \(reaper.reapDurationUsecTotal)"
                )
            }
        }

        if let st = report.storage {
            lines.append("# HELP micropod_storage_bytes Guest ext4 runtime filesystem capacity and usage in bytes.")
            lines.append("# TYPE micropod_storage_bytes gauge")
            lines.append("micropod_storage_bytes{worker=\"\(workerLabel)\",kind=\"total\"} \(st.totalBytes)")
            lines.append("micropod_storage_bytes{worker=\"\(workerLabel)\",kind=\"used\"} \(st.usedBytes)")
            lines.append("micropod_storage_bytes{worker=\"\(workerLabel)\",kind=\"available\"} \(st.availableBytes)")
        }

        if !report.cacheStores.isEmpty {
            lines.append(
                "# HELP micropod_cache_store_active_containers Active containers attached to each cache volume.")
            lines.append("# TYPE micropod_cache_store_active_containers gauge")
            for s in report.cacheStores {
                lines.append(
                    "micropod_cache_store_active_containers{worker=\"\(workerLabel)\",store=\"\(Self.promEscape(s.store))\",scope=\"\(Self.promEscape(s.scope ?? "shared"))\"} \(s.activeContainers)"
                )
            }
        }

        if let inv = report.cacheInventory {
            if let units = inv.units, !units.isEmpty {
                lines.append("# HELP micropod_cache_bytes Disk bytes used by each guest cache store unit.")
                lines.append("# TYPE micropod_cache_bytes gauge")
                lines.append("# HELP micropod_cache_files File count in each guest cache store unit.")
                lines.append("# TYPE micropod_cache_files gauge")
                lines.append("# HELP micropod_cache_in_use 1 when a running container currently pins the cache store.")
                lines.append("# TYPE micropod_cache_in_use gauge")
                lines.append(
                    "# HELP micropod_cache_last_used_timestamp_seconds Last container use timestamp of each cache store."
                )
                lines.append("# TYPE micropod_cache_last_used_timestamp_seconds gauge")
                let reportsDirty = units.contains { $0.dirty != nil }
                if reportsDirty {
                    lines.append(
                        "# HELP micropod_cache_dirty 1 while the crash fence has the cache store marked as possibly holding unsynced writes."
                    )
                    lines.append("# TYPE micropod_cache_dirty gauge")
                }
                for u in units {
                    let lbl =
                        "worker=\"\(workerLabel)\",scope=\"\(Self.promEscape(u.scope))\",tool=\"\(Self.promEscape(u.kind))\",unit=\"\(Self.promEscape(u.unit))\",layer=\"\(Self.promEscape(u.layer))\""
                    lines.append("micropod_cache_bytes{\(lbl)} \(u.bytes)")
                    lines.append("micropod_cache_files{\(lbl)} \(u.files)")
                    lines.append("micropod_cache_in_use{\(lbl)} \(u.inUse ? 1 : 0)")
                    lines.append("micropod_cache_last_used_timestamp_seconds{\(lbl)} \(u.lastUsedUnix)")
                    if let dirty = u.dirty {
                        lines.append("micropod_cache_dirty{\(lbl)} \(dirty ? 1 : 0)")
                    }
                }
            }
            if let budget = inv.budget, budget.maxBytes > 0 {
                lines.append("# HELP micropod_cache_budget_bytes Configured guest cache byte budget ceiling.")
                lines.append("# TYPE micropod_cache_budget_bytes gauge")
                lines.append("micropod_cache_budget_bytes{worker=\"\(workerLabel)\"} \(budget.maxBytes)")
            }
            if let discarded = inv.discardedAtStart {
                lines.append(
                    "# HELP micropod_cache_discarded_at_start Cache store units the engine discarded at its start after an unclean stop."
                )
                lines.append("# TYPE micropod_cache_discarded_at_start gauge")
                lines.append("micropod_cache_discarded_at_start{worker=\"\(workerLabel)\"} \(discarded.count)")
            }
        }
        if let re = report.runtimeEngine {
            if let attaches = re.cacheAttach, !attaches.isEmpty {
                lines.append("# HELP micropod_cache_attach_total Cumulative cache attachments by tool.")
                lines.append("# TYPE micropod_cache_attach_total counter")
                for (tool, count) in attaches.sorted(by: { $0.key < $1.key }) {
                    lines.append(
                        "micropod_cache_attach_total{worker=\"\(workerLabel)\",tool=\"\(Self.promEscape(tool))\"} \(count)"
                    )
                }
            }
            if let skips = re.cacheSkip, !skips.isEmpty {
                lines.append("# HELP micropod_cache_skip_total Cumulative cache attach skips by reason.")
                lines.append("# TYPE micropod_cache_skip_total counter")
                for (reason, count) in skips.sorted(by: { $0.key < $1.key }) {
                    lines.append(
                        "micropod_cache_skip_total{worker=\"\(workerLabel)\",reason=\"\(Self.promEscape(reason))\"} \(count)"
                    )
                }
            }
            if let probes = re.cacheProbes {
                lines.append("# HELP micropod_cache_probes_total Image fact probes executed for cache planning.")
                lines.append("# TYPE micropod_cache_probes_total counter")
                lines.append("micropod_cache_probes_total{worker=\"\(workerLabel)\"} \(probes)")
            }
            if let probeFails = re.cacheProbeFailures {
                lines.append("# HELP micropod_cache_probe_failures_total Failed image fact probes.")
                lines.append("# TYPE micropod_cache_probe_failures_total counter")
                lines.append("micropod_cache_probe_failures_total{worker=\"\(workerLabel)\"} \(probeFails)")
            }
            if let probeMs = re.cacheProbeMs {
                lines.append(
                    "# HELP micropod_cache_probe_duration_milliseconds_total Cumulative image fact probe duration in ms."
                )
                lines.append("# TYPE micropod_cache_probe_duration_milliseconds_total counter")
                lines.append("micropod_cache_probe_duration_milliseconds_total{worker=\"\(workerLabel)\"} \(probeMs)")
            }
            if let evictions = re.cacheEvictions {
                lines.append("# HELP micropod_cache_evictions_total Completed cache prune/janitor eviction sweeps.")
                lines.append("# TYPE micropod_cache_evictions_total counter")
                lines.append("micropod_cache_evictions_total{worker=\"\(workerLabel)\"} \(evictions)")
            }
            if let evictedBytes = re.cacheEvictedBytes {
                lines.append(
                    "# HELP micropod_cache_evicted_bytes_total Cumulative cache bytes freed by eviction sweeps.")
                lines.append("# TYPE micropod_cache_evicted_bytes_total counter")
                lines.append("micropod_cache_evicted_bytes_total{worker=\"\(workerLabel)\"} \(evictedBytes)")
            }
        }

        if let oci = report.nativeOCI {
            lines.append("# HELP micropod_oci_active_sessions Active native OCI job sessions.")
            lines.append("# TYPE micropod_oci_active_sessions gauge")
            lines.append("micropod_oci_active_sessions{worker=\"\(workerLabel)\"} \(oci.activeSessions)")
            if let hits = oci.prepareHits {
                lines.append("# HELP micropod_oci_prepare_hits_total Prepared pod pool hits.")
                lines.append("# TYPE micropod_oci_prepare_hits_total counter")
                lines.append("micropod_oci_prepare_hits_total{worker=\"\(workerLabel)\"} \(hits)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Spec-compliant OpenTelemetry OTLP/JSON `ExportMetricsServiceRequest` combining engine,
    /// hypervisor, guest kernel, workload, and cache telemetry.
    public func otlpMetricsJSON() async throws -> Data {
        let obs = (try? ObservabilityConfig.load(environment: resourceEnvironment)) ?? ObservabilityConfig()
        let report = try await health()
        let tsNano = String(UInt64(report.timestamp.timeIntervalSince1970 * 1_000_000_000.0))

        func attr(_ key: String, _ value: String) -> [String: Any] {
            ["key": key, "value": ["stringValue": value]]
        }
        func gaugeInt(_ name: String, _ unit: String, _ value: Int64, attrs: [[String: Any]] = []) -> [String: Any] {
            var dp: [String: Any] = ["timeUnixNano": tsNano, "asInt": String(value)]
            if !attrs.isEmpty { dp["attributes"] = attrs }
            return ["name": name, "unit": unit, "gauge": ["dataPoints": [dp]]]
        }
        func sumInt(_ name: String, _ unit: String, _ value: UInt64, attrs: [[String: Any]] = []) -> [String: Any] {
            var dp: [String: Any] = ["timeUnixNano": tsNano, "asInt": String(value)]
            if !attrs.isEmpty { dp["attributes"] = attrs }
            return [
                "name": name, "unit": unit,
                "sum": ["aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [dp]],
            ]
        }

        var metrics: [[String: Any]] = [
            gaugeInt(
                "micropod.engine.healthy", "1", report.verdict == .healthy ? 1 : 0,
                attrs: [attr("verdict", report.verdict.rawValue)]),
            gaugeInt("micropod.buildkit.available", "1", report.engine.buildkitAvailable ? 1 : 0),
            gaugeInt("micropod.workloads.running", "{container}", Int64(report.workloads.runningCount)),
            gaugeInt("micropod.workloads.total", "{container}", Int64(report.workloads.totalCount)),
            gaugeInt("micropod.cache.stores.count", "{store}", Int64(report.cacheStores.count)),
        ]
        if let hv = report.hypervisor {
            metrics.append(gaugeInt("micropod.vmm.vcpus.online", "{cpu}", Int64(hv.vcpusOnline)))
            metrics.append(gaugeInt("micropod.vmm.guest_ctrl.connected", "1", hv.guestCtrlConnected ? 1 : 0))
            metrics.append(
                gaugeInt("micropod.vmm.host.phys_footprint_bytes", "By", Int64(hv.hostPhysFootprintMib * 1024 * 1024)))
            metrics.append(sumInt("micropod.vmm.blk.write_ops", "{op}", hv.blkWriteOps))
            metrics.append(sumInt("micropod.vmm.virtiofs.requests", "{request}", hv.fsRequests))
            if let kch = hv.fsKeepCacheHits {
                metrics.append(sumInt("micropod.vmm.virtiofs.keep_cache_hits", "{hit}", kch))
            }
            if let ne = hv.fsNotifyEvents {
                metrics.append(sumInt("micropod.vmm.virtiofs.notify_events", "{event}", ne))
            }
            if let fe = hv.fsErrors {
                metrics.append(sumInt("micropod.vmm.virtiofs.errors", "{error}", fe))
            }
            metrics.append(sumInt("micropod.vmm.published.conns", "{connection}", hv.publishedConns))
        }
        if let k = report.kernel {
            if let avail = k.availableBytes {
                metrics.append(gaugeInt("micropod.guest.memory.available", "By", Int64(avail)))
            }
            if let oom = k.oomKills {
                metrics.append(sumInt("micropod.guest.oom.kills", "{kill}", oom))
            }
        }
        if let re = report.runtimeEngine {
            metrics.append(sumInt("micropod.runtime.containers.created", "{container}", re.containersCreated))
            metrics.append(sumInt("micropod.runtime.runs.finished", "{run}", re.runsFinished))
            metrics.append(sumInt("micropod.runtime.failures", "{failure}", re.runtimeFailures))
            metrics.append(sumInt("micropod.runtime.image_cache.hits", "{hit}", re.imageCacheHits))
            metrics.append(sumInt("micropod.runtime.start_duration_ms", "ms", UInt64(max(0, re.startMsTotal))))
            metrics.append(gaugeInt("micropod.runtime.setup_slots.in_use", "{slot}", Int64(re.setupSlotsInUse)))
            if let api = re.api {
                metrics.append(sumInt("micropod.docker_api.requests", "{request}", api.requestsTotal))
                metrics.append(sumInt("micropod.docker_api.errors_5xx", "{error}", api.errors5xx))
                metrics.append(sumInt("micropod.docker_api.conflicts_409", "{conflict}", api.conflicts409))
                metrics.append(sumInt("micropod.docker_api.slow_requests", "{request}", api.slowRequestsTotal))
            }
            if let reaper = re.reaper {
                metrics.append(gaugeInt("micropod.reaper.active_sessions", "{session}", reaper.activeSessions))
                metrics.append(sumInt("micropod.reaper.containers_reaped", "{container}", reaper.containersReaped))
                metrics.append(sumInt("micropod.reaper.networks_reaped", "{network}", reaper.networksReaped))
                metrics.append(sumInt("micropod.reaper.volumes_reaped", "{volume}", reaper.volumesReaped))
                metrics.append(sumInt("micropod.reaper.errors", "{error}", reaper.reapErrors))
            }
        }
        if let st = report.storage {
            metrics.append(gaugeInt("micropod.storage.used", "By", Int64(st.usedBytes)))
            metrics.append(gaugeInt("micropod.storage.available", "By", Int64(st.availableBytes)))
        }
        if let inv = report.cacheInventory, let totals = inv.totals {
            metrics.append(gaugeInt("micropod.cache.bytes", "By", Int64(totals.totalBytes)))
            metrics.append(gaugeInt("micropod.cache.l0.bytes", "By", Int64(totals.l0Bytes)))
            metrics.append(gaugeInt("micropod.cache.l1.bytes", "By", Int64(totals.l1Bytes)))
            metrics.append(gaugeInt("micropod.cache.units.in_use", "{unit}", Int64(totals.inUseCount)))
            if let dirty = totals.dirtyCount {
                metrics.append(gaugeInt("micropod.cache.units.dirty", "{unit}", Int64(dirty)))
            }
            if let discarded = inv.discardedAtStart {
                metrics.append(gaugeInt("micropod.cache.units.discarded_at_start", "{unit}", Int64(discarded.count)))
            }
        }
        if let re = report.runtimeEngine {
            if let attaches = re.cacheAttach {
                for (tool, count) in attaches.sorted(by: { $0.key < $1.key }) {
                    metrics.append(
                        sumInt("micropod.cache.attach", "{attach}", count, attrs: [attr("cache.tool", tool)]))
                }
            }
            if let skips = re.cacheSkip {
                for (reason, count) in skips.sorted(by: { $0.key < $1.key }) {
                    metrics.append(
                        sumInt("micropod.cache.skip", "{skip}", count, attrs: [attr("cache.skip_reason", reason)]))
                }
            }
            if let ev = re.cacheEvictions {
                metrics.append(sumInt("micropod.cache.evictions", "{sweep}", ev))
            }
            if let evBytes = re.cacheEvictedBytes {
                metrics.append(sumInt("micropod.cache.evicted_bytes", "By", evBytes))
            }
            if let pf = re.cacheProbeFailures {
                metrics.append(sumInt("micropod.cache.probe_failures", "{failure}", pf))
            }
        }
        for w in report.workloads.items where w.state.lowercased() == "running" {
            let wattrs = [
                attr("container.id", w.id), attr("container.name", w.name), attr("container.image.name", w.image),
            ]
            if let cpuNs = w.cpuUsageNs {
                metrics.append(sumInt("micropod.container.cpu.usage_ns", "ns", cpuNs, attrs: wattrs))
            }
            if let thrNs = w.cpuThrottledNs {
                metrics.append(sumInt("micropod.container.cpu.throttled_ns", "ns", thrNs, attrs: wattrs))
            }
            if let mem = w.memoryUsageBytes {
                metrics.append(gaugeInt("micropod.container.memory.usage", "By", Int64(mem), attrs: wattrs))
            }
            if let peak = w.memoryPeakBytes {
                metrics.append(gaugeInt("micropod.container.memory.peak", "By", Int64(peak), attrs: wattrs))
            }
            if let oom = w.memoryOomKills {
                metrics.append(sumInt("micropod.container.memory.oom_kills", "{kill}", oom, attrs: wattrs))
            }
            if let pids = w.pids {
                metrics.append(gaugeInt("micropod.container.pids.current", "{process}", Int64(pids), attrs: wattrs))
            }
            if let rx = w.netRxBytes {
                metrics.append(sumInt("micropod.container.network.rx", "By", rx, attrs: wattrs))
            }
            if let tx = w.netTxBytes {
                metrics.append(sumInt("micropod.container.network.tx", "By", tx, attrs: wattrs))
            }
            if let rb = w.blkReadBytes {
                metrics.append(sumInt("micropod.container.blkio.read", "By", rb, attrs: wattrs))
            }
            if let wb = w.blkWriteBytes {
                metrics.append(sumInt("micropod.container.blkio.write", "By", wb, attrs: wattrs))
            }
        }

        var resourceAttrs: [[String: Any]] = [
            attr("service.name", obs.serviceName),
            attr("micropod.vmm", report.engine.vmm.rawValue),
            attr("micropod.worker.id", report.engine.worker.uuidString),
            attr("micropod.instance.id", report.engine.instance.uuidString),
        ]
        for (k, v) in obs.otlp.resourceAttributes.sorted(by: { $0.key < $1.key }) {
            resourceAttrs.append(attr(k, v))
        }

        let payload: [String: Any] = [
            "resourceMetrics": [
                [
                    "resource": ["attributes": resourceAttrs],
                    "scopeMetrics": [
                        [
                            "scope": ["name": "micropod.engine", "version": "1.0.0"],
                            "metrics": metrics,
                        ]
                    ],
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
