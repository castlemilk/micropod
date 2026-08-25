import Foundation

/// One element of `container network list --format json`.
public struct NetworkListEntry: Codable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let status: Status?

    public struct Configuration: Codable, Sendable {
        public let creationDate: String?
        public let labels: [String: String]?
        public let mode: String?
        public let name: String?
        public let options: [String: JSONValue]?
        public let plugin: String?
    }

    public struct Status: Codable, Sendable {
        public let ipv4Gateway: String?
        public let ipv4Subnet: String?
        public let ipv6Subnet: String?
    }
}

/// One element of `container volume list --format json`.
public struct VolumeListEntry: Codable, Sendable {
    public let id: String
    public let configuration: Configuration

    public struct Configuration: Codable, Sendable {
        public let creationDate: String?
        public let driver: String?
        public let format: String?
        public let labels: [String: String]?
        public let name: String?
        public let options: [String: JSONValue]?
        public let sizeInBytes: Int64?
        public let source: String?
    }
}
