import Foundation

/// One element of `container image list --format json --verbose`.
public struct ImageListEntry: Codable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let variants: [Variant]

    public struct Configuration: Codable, Sendable {
        public let creationDate: String?
        public let name: String?
        public let descriptor: Descriptor?
    }

    public struct Descriptor: Codable, Sendable {
        public let digest: String?
        public let mediaType: String?
        public let size: Int64?
    }

    public struct Variant: Codable, Sendable {
        public let config: VariantConfig?
        public let digest: String?
        /// Object form in current CLI output; older builds emitted a
        /// "linux/amd64" string — both are tolerated.
        public let platform: Platform?
        public let size: Int64?

        public struct Platform: Codable, Sendable {
            public let architecture: String?
            public let os: String?
            public let variant: String?
        }

        public init(config: VariantConfig?, digest: String?, platform: Platform?, size: Int64?) {
            self.config = config
            self.digest = digest
            self.platform = platform
            self.size = size
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.config = try? container.decodeIfPresent(VariantConfig.self, forKey: .config)
            self.digest = try? container.decodeIfPresent(String.self, forKey: .digest)
            self.size = try? container.decodeIfPresent(Int64.self, forKey: .size)
            if let object = try? container.decodeIfPresent(Platform.self, forKey: .platform) {
                self.platform = object
            } else if let legacy = try? container.decodeIfPresent(String.self, forKey: .platform) {
                let parts = legacy.split(separator: "/")
                self.platform = Platform(
                    architecture: parts.count > 1 ? String(parts[1]) : nil,
                    os: parts.count > 0 ? String(parts[0]) : nil,
                    variant: nil)
            } else {
                self.platform = nil
            }
        }
    }

    public struct VariantConfig: Codable, Sendable {
        public let architecture: String?
        public let os: String?
        public let created: String?
        public let rootfs: RootFS?
    }

    public struct RootFS: Codable, Sendable {
        public let type: String?
        public let diffIDs: [String]?
    }
}

/// One element of `container registry list --format json`.
public struct RegistryEntry: Codable, Sendable {
    public let server: String?
    public let username: String?
    public let name: String?
    public let scheme: String?

    public var displayName: String {
        server ?? name ?? "unknown registry"
    }
}
