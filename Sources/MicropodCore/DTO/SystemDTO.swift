import Foundation

/// `container system status --format json`, in either of its shapes:
///   - through 1.4.x, flat: `{status, appRoot, installRoot, logRoot,
///     apiServerVersion, apiServerCommit, apiServerBuild, apiServerAppName}`;
///   - from 1.5.0, nested: `{status, client{version,…}, server{version,
///     build, commit, appName}, host{…}, paths{appRoot, installRoot, logRoot},
///     resources{…}}`.
/// Both read into the flat fields. `apiServerVersion` is the server's
/// version as it reports it (a banner on older releases, the bare release
/// on newer ones). A stopped runtime answers `{"status": …}` alone in both.
public struct SystemStatusResponse: Codable, Sendable {
    public let status: String
    public let appRoot: String?
    public let installRoot: String?
    public let apiServerVersion: String?

    public init(status: String, appRoot: String? = nil, installRoot: String? = nil, apiServerVersion: String? = nil) {
        self.status = status
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.apiServerVersion = apiServerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case status, appRoot, installRoot, apiServerVersion
        case server, paths
    }

    private struct Server: Decodable {
        let version: String?
    }

    private struct Paths: Decodable {
        let appRoot: String?
        let installRoot: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let server = try container.decodeIfPresent(Server.self, forKey: .server)
        let paths = try container.decodeIfPresent(Paths.self, forKey: .paths)
        status = try container.decode(String.self, forKey: .status)
        appRoot = try container.decodeIfPresent(String.self, forKey: .appRoot) ?? paths?.appRoot
        installRoot = try container.decodeIfPresent(String.self, forKey: .installRoot) ?? paths?.installRoot
        apiServerVersion =
            try container.decodeIfPresent(String.self, forKey: .apiServerVersion) ?? server?.version
    }

    /// Always the flat shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(appRoot, forKey: .appRoot)
        try container.encodeIfPresent(installRoot, forKey: .installRoot)
        try container.encodeIfPresent(apiServerVersion, forKey: .apiServerVersion)
    }
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
