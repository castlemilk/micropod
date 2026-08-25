import Foundation

/// `container system status --format json`.
public struct SystemStatusResponse: Codable, Sendable {
    public let status: String
    public let appRoot: String?
    public let installRoot: String?
    public let apiServerVersion: String?
}

/// `container system version --format json`.
public struct SystemVersionEntry: Codable, Sendable {
    public let appName: String
    public let version: String
    public let buildType: String?
    public let commit: String?
}

/// `container system df --format json`.
public struct DiskUsageResponse: Codable, Sendable {
    public let containers: DiskCategoryResponse?
    public let images: DiskCategoryResponse?
    public let volumes: DiskCategoryResponse?

    public struct DiskCategoryResponse: Codable, Sendable {
        public let total: Int64?
        public let active: Int64?
        public let sizeInBytes: Int64?
        public let reclaimable: Int64?
    }
}

/// One element of `container stats --no-stream --format json`.
public struct ContainerStatsEntry: Codable, Sendable {
    public let id: String
    public let cpuUsageUsec: Int64?
    public let memoryUsageBytes: Int64?
    public let memoryLimitBytes: Int64?
    public let networkRxBytes: Int64?
    public let networkTxBytes: Int64?
    public let blockReadBytes: Int64?
    public let blockWriteBytes: Int64?
    public let numProcesses: Int64?
}
