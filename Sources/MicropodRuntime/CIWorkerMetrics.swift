import Foundation
import MicropodCore

extension CIWorker {
    public struct CacheStoreMetrics: Codable, Sendable {
        public let volume: String
        public let scope: String?
        public let store: String
        public let activeContainers: Int
        public let bytes: Int64?
    }

    public struct BuildCacheMetrics: Codable, Sendable {
        public let records: Int
        public let inUseRecords: Int
        public let useCount: Int64
        public let privateRecordBytes: Int64
        public let sharedRecordBytes: Int64
    }

    public struct Metrics: Codable, Sendable {
        public let worker: UUID
        public let boot: UUID
        public let timestamp: Date
        public let runningContainers: Int
        public let cacheStores: [CacheStoreMetrics]
        public let buildCache: BuildCacheMetrics?
        public let lastNetworkRepair: NetworkRepair?
    }

    static func cacheStore(_ name: String, activeContainers: Int, bytes: Int64? = nil) -> CacheStoreMetrics? {
        for store in ["npm", "gomod", "gobuild", "pycache"] {
            if name == "micropod-ci-" + store {
                return .init(volume: name, scope: nil, store: store, activeContainers: activeContainers, bytes: bytes)
            }
            let prefix = "micropod-ci-scoped-"
            let suffix = "-" + store
            if name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count {
                let scope = String(name.dropFirst(prefix.count).dropLast(suffix.count))
                return .init(volume: name, scope: scope, store: store, activeContainers: activeContainers, bytes: bytes)
            }
        }
        return nil
    }

    /// Explicit snapshot of Engine metadata. Never open the payloads or calculate directory sizes
    /// on the job launch path. A volume attachment and a package-manager hit are separate measurements.
    public func metrics(includeUsage: Bool = false) async throws -> Metrics {
        let current = try await status()
        let api = DockerClient(endpoint: .unix(socket.path))
        async let volumesRequest = api.request(
            "GET", includeUsage ? "/system/df" : "/volumes",
            query: includeUsage ? ["type": "volume"] : [:], timeout: includeUsage ? .seconds(120) : .seconds(5))
        async let jobsRequest = api.request("GET", "/containers/json", timeout: .seconds(5))
        let (volumes, jobs) = try await (volumesRequest, jobsRequest)
        struct VolumeList: Decodable {
            struct Volume: Decodable {
                struct Usage: Decodable { let Size: Int64 }
                let Name: String
                let UsageData: Usage?
            }
            let Volumes: [Volume]?
        }
        struct Job: Decodable {
            struct Mount: Decodable {
                enum CodingKeys: String, CodingKey {
                    case type = "Type"
                    case Name
                }
                let type: String
                let Name: String?
            }
            let Mounts: [Mount]
        }
        guard volumes.status == 200, jobs.status == 200 else {
            throw MicropodError.message("Could not read the CI Docker volume and container inventory")
        }
        let decoder = JSONDecoder()
        let running = try decoder.decode([Job].self, from: jobs.body)
        var attachments = [String: Int]()
        for job in running {
            for name in Set(job.Mounts.filter { $0.type == "volume" }.compactMap(\.Name)) {
                attachments[name, default: 0] += 1
            }
        }
        let stores = try (decoder.decode(VolumeList.self, from: volumes.body).Volumes ?? [])
            .compactMap { volume in
                let bytes = volume.UsageData.flatMap { $0.Size >= 0 ? $0.Size : nil }
                return Self.cacheStore(
                    volume.Name, activeContainers: attachments[volume.Name, default: 0], bytes: bytes)
            }
            .sorted { $0.volume < $1.volume }
        let repair = (try? Data(contentsOf: directory.appendingPathComponent("network.json"))).flatMap {
            try? decoder.decode(NetworkRepair.self, from: $0)
        }
        let buildCache = includeUsage ? try await Self.buildCacheMetrics(api) : nil
        guard try await status().instance == current.instance else {
            throw MicropodError.message("The CI worker changed while reading metrics. Retry the snapshot.")
        }
        return Metrics(
            worker: current.worker, boot: current.boot, timestamp: Date(), runningContainers: running.count,
            cacheStores: stores, buildCache: buildCache,
            lastNetworkRepair: repair?.instance == current.instance ? repair : nil)
    }

    private static func buildCacheMetrics(_ api: DockerClient) async throws -> BuildCacheMetrics {
        struct Report: Decodable {
            struct Record: Decodable {
                let Size: Int64
                let UsageCount: Int64
                let InUse: Bool
                let Shared: Bool
            }
            let BuildCache: [Record]?
        }
        let result = try await api.request("GET", "/system/df", query: ["type": "build-cache"])
        guard result.status == 200 else { throw MicropodError.message("Could not read Docker build cache usage") }
        let records = try JSONDecoder().decode(Report.self, from: result.body).BuildCache ?? []
        return BuildCacheMetrics(
            records: records.count, inUseRecords: records.filter(\.InUse).count,
            useCount: records.reduce(0) { $0 + $1.UsageCount },
            privateRecordBytes: records.filter { !$0.Shared }.reduce(0) { $0 + $1.Size },
            sharedRecordBytes: records.filter(\.Shared).reduce(0) { $0 + $1.Size })
    }
}
