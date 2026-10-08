import Foundation
import MicropodCore
import Observation

/// Read-only observations. File allocation is deliberately not aggregated:
/// APFS goldens and attempt clones may share extents.
struct CICacheVolume: Identifiable, Equatable, Sendable {
    let id: String
    let project: String
    let owner: String
    let ecosystem: String
    let source: String
    let capacityBytes: UInt64?
    let allocatedBytes: UInt64?
    let activeContainers: [String]?

    var activityLabel: String {
        guard let activeContainers else { return "Active use unknown" }
        return activeContainers.isEmpty
            ? "No active reference observed" : "Active in \(activeContainers.count) container(s)"
    }
}

struct CICacheSelection: Equatable, Sendable {
    var project: String = ""
    var owner: String = ""

    func includes(_ volume: CICacheVolume) -> Bool {
        (project.isEmpty || project == volume.project) && (owner.isEmpty || owner == volume.owner)
    }
}

struct CICacheRead: Sendable {
    let volumes: [Micropod_V1_Volume]
    let containers: [Micropod_V1_Container]?
    let truncated: Bool
}

protocol CICacheInventoryReading: Sendable {
    func read() async throws -> CICacheRead
}

struct RuntimeCICacheReader: CICacheInventoryReading {
    let volumes: any VolumeServing
    let containers: any ContainerServing
    static let limit = 512

    func read() async throws -> CICacheRead {
        async let volumeList = volumes.list()
        async let containerList = try? containers.list()
        let (listed, references) = try await (volumeList, containerList)
        return Self.bounded(volumes: listed, containers: references)
    }

    static func bounded(volumes: [Micropod_V1_Volume], containers: [Micropod_V1_Container]?) -> CICacheRead {
        let truncated = volumes.count > Self.limit || (containers?.count ?? 0) > Self.limit
        return CICacheRead(
            volumes: Array(volumes.prefix(Self.limit)),
            containers: truncated ? nil : containers,
            truncated: truncated)
    }
}

struct CICacheInventorySnapshot: Sendable {
    let measuredAt: Date
    let sourceID: String
    let volumes: [CICacheVolume]
    let referencesAvailable: Bool
    let truncated: Bool

    init(read: CICacheRead, sourceID: String, measuredAt: Date) {
        self.measuredAt = measuredAt
        self.sourceID = sourceID
        self.referencesAvailable = read.containers != nil
        self.truncated = read.truncated
        // Inspect only curated mount metadata; never guest data, logs or env.
        self.volumes = read.volumes.filter {
            $0.format.lowercased() == "ext4"
                && ($0.labels["cuttle.kind"] == "cache" || $0.id.hasPrefix("cf-cache-"))
        }.map { volume in
            let active = read.containers.map { containers in
                containers.filter { container in
                    ["running", "starting", "stopping"].contains(container.state.lowercased())
                        && container.mounts.contains { mount in
                            Self.references(mount.source, volume: volume, containerID: container.id)
                        }
                }.map(\.id).sorted()
            }
            return CICacheVolume(
                id: volume.id, project: volume.labels["cuttle.project"] ?? "",
                owner: volume.labels["cuttle.owner"] ?? "",
                ecosystem: volume.labels["cuttle.ecosystem"] ?? volume.labels["cuttle.scope"] ?? "",
                source: volume.source,
                capacityBytes: volume.sizeBytes > 0 ? volume.sizeBytes : nil,
                // Proto3 zero does not distinguish an omitted sample from zero
                // allocation. Stay conservative until the runtime supplies presence.
                allocatedBytes: volume.allocatedBytes > 0 ? volume.allocatedBytes : nil,
                activeContainers: active)
        }.sorted {
            if $0.allocatedBytes != $1.allocatedBytes {
                return ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0)
            }
            return $0.id < $1.id
        }
    }

    private static func references(_ source: String, volume: Micropod_V1_Volume, containerID: String) -> Bool {
        if source == volume.id || (!volume.source.isEmpty && source == volume.source) { return true }
        // A golden can be in use without an open handle on the golden itself.
        // Match the complete clone path suffix, not a substring of its name.
        return source.hasSuffix("/volume-clones/\(containerID)/\(volume.id).img")
    }

    func selected(_ selection: CICacheSelection) -> [CICacheVolume] {
        volumes.filter(selection.includes)
    }

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(measuredAt) > 90 || measuredAt.timeIntervalSince(now) > 5
    }
}

struct CICacheCounter: Decodable, Sendable {
    let name: String
    let type: String
    let value: Double
    let capturedAt: String?
    let attributes: [String: String]?
}

struct CICacheTelemetry: Sendable {
    static let endpoint = URL(string: "http://127.0.0.1:5555/cache")!
    let receivedAt: Date
    let counters: [CICacheCounter]

    static func decode(_ data: Data, receivedAt: Date) throws -> Self {
        struct Envelope: Decodable {
            let ok: Bool
            let metrics: [CICacheCounter]
        }
        guard data.count <= 131_072 else { throw CICacheReadError.invalidCounters }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.ok, envelope.metrics.count <= 1024,
            envelope.metrics.allSatisfy({ $0.value.isFinite && $0.value >= 0 })
        else { throw CICacheReadError.invalidCounters }
        return Self(receivedAt: receivedAt, counters: envelope.metrics)
    }

    /// The endpoint does not assert rig/owner identity. Never join it to an
    /// owner selection. Project-less counters are hidden under a project filter.
    func observations(for selection: CICacheSelection) -> [CICacheCounterObservation] {
        guard selection.owner.isEmpty else { return [] }
        let definitions: [(String, String, String, String)] =
            selection.project.isEmpty
            ? [
                ("Volume resolutions", "cache_volume_total", "outcome", "hit"),
                ("Store resolutions", "cache_store_total", "outcome", "hit"),
                ("Dependency proxy", "depcache_requests_total", "tier", "local"),
            ]
            : [("Volume resolutions", "cache_volume_total", "outcome", "hit")]
        return definitions.compactMap { label, name, attribute, value in
            let matching = counters.filter {
                $0.name == name && $0.type == "counter" && $0.attributes?[attribute] == value
                    && (selection.project.isEmpty || $0.attributes?["project"] == selection.project)
            }
            guard !matching.isEmpty else { return nil }  // absent is unavailable, not zero
            let total = matching.reduce(0) { $0 + $1.value }
            guard total.isFinite else { return nil }
            let dates = matching.compactMap { Self.date($0.capturedAt) }
            return CICacheCounterObservation(
                label: label, hits: total, capturedAt: dates.count == matching.count ? dates.min() : nil)
        }
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

struct CICacheCounterObservation: Sendable {
    let label: String
    let hits: Double
    let capturedAt: Date?

    func freshness(at now: Date) -> String {
        guard let capturedAt else { return "Sample time unknown" }
        if capturedAt.timeIntervalSince(now) > 5 { return "Sample time invalid" }
        return now.timeIntervalSince(capturedAt) > 90 ? "Stale sample" : "Recent sample"
    }
}

enum CICacheByteFormat {
    static func string(_ value: UInt64?) -> String {
        guard let value else { return "Unknown" }
        guard value <= UInt64(Int64.max) else { return "\(value.formatted()) bytes" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

enum CICacheReadError: Error { case invalidCounters, unavailable }

protocol CICacheTelemetryReading: Sendable {
    func read() async throws -> CICacheTelemetry
}

/// Fixed loopback, no redirects, credentials, cookies, cache or mutations.
private final class CacheCounterRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

struct LocalCICacheTelemetryReader: CICacheTelemetryReading {
    func read() async throws -> CICacheTelemetry {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(
            configuration: configuration, delegate: CacheCounterRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: CICacheTelemetry.endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CICacheReadError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 131_072 else { throw CICacheReadError.invalidCounters }
            try Task.checkCancellation()
            data.append(byte)
        }
        return try CICacheTelemetry.decode(data, receivedAt: Date())
    }
}

@MainActor @Observable
final class CICacheStore {
    private(set) var inventory: CICacheInventorySnapshot?
    private(set) var telemetry: CICacheTelemetry?
    private(set) var inventoryError: String?
    private(set) var telemetryError: String?
    private(set) var isRefreshing = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var sourceID: String?
    @ObservationIgnored private var isPreview = false

    func refresh(
        reader: any CICacheInventoryReading, sourceID: String,
        telemetryReader: any CICacheTelemetryReading = LocalCICacheTelemetryReader()
    ) async {
        guard !isPreview, !Task.isCancelled else { return }
        if self.sourceID != sourceID {
            cancelRefresh()
            self.sourceID = sourceID
            inventory = nil
            telemetry = nil
            inventoryError = nil
            telemetryError = nil
        }
        if let task {
            await task.value
            return
        }
        let epoch = self.epoch
        isRefreshing = true
        let task = Task { [weak self] in
            async let inventoryResult = Self.inventoryResult(reader)
            async let telemetryResult = Self.telemetryResult(telemetryReader)
            let (inventoryRead, telemetryRead) = await (inventoryResult, telemetryResult)
            guard let self, !Task.isCancelled, self.epoch == epoch else { return }
            switch inventoryRead {
            case .success(let read):
                inventory = CICacheInventorySnapshot(read: read, sourceID: sourceID, measuredAt: Date())
                inventoryError = nil
            case .failure:
                inventoryError = "Named-volume inventory unavailable. Any retained rows are an earlier observation."
            }
            switch telemetryRead {
            case .success(let result):
                telemetry = result
                telemetryError = nil
            case .failure:
                telemetryError = "Local runner counters unavailable. Any retained counters are an earlier observation."
            }
            isRefreshing = false
            self.task = nil
        }
        self.task = task
        await task.value
    }

    nonisolated private static func inventoryResult(_ reader: any CICacheInventoryReading) async -> Result<
        CICacheRead, Error
    > {
        do { return .success(try await reader.read()) } catch { return .failure(error) }
    }

    nonisolated private static func telemetryResult(_ reader: any CICacheTelemetryReading) async -> Result<
        CICacheTelemetry, Error
    > {
        do { return .success(try await reader.read()) } catch { return .failure(error) }
    }

    func cancelRefresh() {
        epoch &+= 1
        task?.cancel()
        task = nil
        isRefreshing = false
    }

    func applyForPreview(
        _ inventory: CICacheInventorySnapshot?, telemetry: CICacheTelemetry? = nil, error: String? = nil
    ) {
        cancelRefresh()
        isPreview = true
        self.inventory = inventory
        self.telemetry = telemetry
        inventoryError = error
    }
}
