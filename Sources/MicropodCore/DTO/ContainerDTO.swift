import Foundation

/// One element of `container list --all --format json`.
public struct ContainerListEntry: Codable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let status: Status

    public struct Configuration: Codable, Sendable {
        public let id: String?
        public let creationDate: String?
        public let image: ImageReference?
        public let labels: [String: String]?
        public let mounts: [Mount]?
        public let networks: [NetworkAttachment]?
        public let platform: Platform?
        public let publishedPorts: [PublishedPort]?
        public let resources: Resources?
        public let rosetta: Bool?
        public let readOnly: Bool?
        public let runtimeHandler: String?
        public let ssh: Bool?
        public let useInit: Bool?
        public let virtualization: Bool?
        public let initProcess: InitProcess?
    }

    public struct Status: Codable, Sendable {
        public let state: String?
        public let networks: [StatusNetwork]?
        public let exitCode: Int?
    }

    public struct ImageReference: Codable, Sendable {
        public let reference: String?
        public let descriptor: Descriptor?
    }

    public struct Descriptor: Codable, Sendable {
        public let digest: String?
        public let mediaType: String?
        public let size: Int64?
    }

    public struct Mount: Codable, Sendable {
        public let destination: String?
        public let source: String?
        public let options: [String]?
        /// Oneof object, e.g. `{"virtiofs": {}}`; first key names the type.
        public let type: [String: JSONValue]?

        public var typeName: String {
            type?.keys.first ?? "unknown"
        }
    }

    public struct NetworkAttachment: Codable, Sendable {
        public let network: String?
        /// Loose values: the CLI emits mixed types here (e.g. "mtu": 1280).
        public let options: [String: JSONValue]?
    }

    public struct Platform: Codable, Sendable {
        public let architecture: String?
        public let os: String?
        public let variant: String?
    }

    public struct Resources: Codable, Sendable {
        public let cpuOverhead: Int?
        public let cpus: Double?
        public let memoryInBytes: Int64?
    }

    public struct InitProcess: Codable, Sendable {
        public let executable: String?
        public let arguments: [String]?
        public let environment: [String]?
        public let terminal: Bool?
        public let workingDirectory: String?
        public let user: User?
    }

    public struct User: Codable, Sendable {
        public let id: UserID?
    }

    public struct UserID: Codable, Sendable {
        public let uid: Int?
        public let gid: Int?
    }
}

/// Container-status network entry (`.status.networks[]`).
public struct StatusNetwork: Codable, Sendable {
    public let network: String?
    public let hostname: String?
    /// IPv4 address as CIDR, e.g. "192.168.64.8/24".
    public let ipv4Address: String?
    public let ipv4Gateway: String?
    public let ipv6Address: String?
    public let macAddress: String?
    public let mtu: Int?
}

/// Port publication; the CLI emits either flat keys or a nested `port` object.
public struct PublishedPort: Codable, Sendable {
    public var hostPort: Int?
    public var containerPort: Int?
    public var protocolName: String?
    public var hostIP: String?

    private enum CodingKeys: String, CodingKey {
        case hostPort, containerPort
        case protocolName = "protocol"
        case hostIP, hostIp, port
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hostPort = try? c.decodeIfPresent(Int.self, forKey: .hostPort)
        self.containerPort = try? c.decodeIfPresent(Int.self, forKey: .containerPort)
        self.protocolName = try? c.decodeIfPresent(String.self, forKey: .protocolName)
        self.hostIP =
            (try? c.decodeIfPresent(String.self, forKey: .hostIP))
            ?? (try? c.decodeIfPresent(String.self, forKey: .hostIp))
        if let nested = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .port) {
            if self.hostPort == nil { self.hostPort = try? nested.decodeIfPresent(Int.self, forKey: .hostPort) }
            if self.containerPort == nil {
                self.containerPort = try? nested.decodeIfPresent(Int.self, forKey: .containerPort)
            }
            if self.protocolName == nil {
                self.protocolName = try? nested.decodeIfPresent(String.self, forKey: .protocolName)
            }
            if self.hostIP == nil { self.hostIP = try? nested.decodeIfPresent(String.self, forKey: .hostIP) }
        }
    }

    public init(hostPort: Int?, containerPort: Int?, protocolName: String?, hostIP: String?) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
        self.hostIP = hostIP
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hostPort, forKey: .hostPort)
        try c.encodeIfPresent(containerPort, forKey: .containerPort)
        try c.encodeIfPresent(protocolName, forKey: .protocolName)
        try c.encodeIfPresent(hostIP, forKey: .hostIP)
    }
}
