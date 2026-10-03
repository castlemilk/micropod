import Foundation

/// One element of `container machine list --format json`.
///
/// container 1.x emits `id`/`status`/`ipAddress`/`createdDate` with byte
/// counts for `memory`/`diskSize`; older builds used `name`/`state`/`ip`/
/// `created` with display strings. Both shapes decode into the same entry.
public struct MachineEntry: Codable, Sendable, Identifiable, Equatable {
    public let name: String
    public let created: String?
    public let ip: String?
    public let cpus: Int?
    /// Display string ("8G"); derived from `memoryBytes` on 1.x builds.
    public let memory: String?
    public let disk: String?
    public let memoryBytes: UInt64?
    public let diskBytes: UInt64?
    public let state: String?
    public let defaultMachine: Bool?

    public var id: String { name }
    public var isRunning: Bool { state?.lowercased() == "running" }

    public init(
        name: String, created: String? = nil, ip: String? = nil, cpus: Int? = nil,
        memoryBytes: UInt64? = nil, diskBytes: UInt64? = nil, state: String? = nil,
        defaultMachine: Bool? = nil
    ) {
        self.name = name
        self.created = created
        self.ip = ip
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.memory = memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
        self.disk = diskBytes.map(ByteFormat.string)
        self.state = state
        self.defaultMachine = defaultMachine
    }

    private enum CodingKeys: String, CodingKey {
        case name, created, ip, cpus, memory, disk, memoryBytes, diskBytes, state, defaultMachine
        // container 1.x keys
        case id, createdDate, ipAddress, diskSize, status
        case `default`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .id)
        else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: c.codingPath, debugDescription: "machine entry has neither id nor name"))
        }
        self.name = name
        created =
            try c.decodeIfPresent(String.self, forKey: .created)
            ?? c.decodeIfPresent(String.self, forKey: .createdDate)
        ip =
            try c.decodeIfPresent(String.self, forKey: .ip)
            ?? c.decodeIfPresent(String.self, forKey: .ipAddress)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        state =
            try c.decodeIfPresent(String.self, forKey: .state)
            ?? c.decodeIfPresent(String.self, forKey: .status)
        defaultMachine =
            try c.decodeIfPresent(Bool.self, forKey: .defaultMachine)
            ?? c.decodeIfPresent(Bool.self, forKey: .default)

        // memory: bytes (1.x) or a display string (legacy / re-encoded).
        if let bytes = try? c.decodeIfPresent(UInt64.self, forKey: .memory) {
            memoryBytes = bytes
            memory = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        } else {
            memoryBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryBytes)
            memory = try c.decodeIfPresent(String.self, forKey: .memory) ?? memoryBytes.map(ByteFormat.string)
        }
        let diskSize =
            try c.decodeIfPresent(UInt64.self, forKey: .diskSize)
            ?? c.decodeIfPresent(UInt64.self, forKey: .diskBytes)
        diskBytes = diskSize
        disk = try c.decodeIfPresent(String.self, forKey: .disk) ?? diskSize.map(ByteFormat.string)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(ip, forKey: .ip)
        try c.encodeIfPresent(cpus, forKey: .cpus)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(memoryBytes, forKey: .memoryBytes)
        try c.encodeIfPresent(disk, forKey: .disk)
        try c.encodeIfPresent(diskBytes, forKey: .diskBytes)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(defaultMachine, forKey: .defaultMachine)
    }
}

/// `container system property list --format json`: a flat dict of
/// section name → key/value configuration.
public typealias SystemPropertyListResponse = [String: [String: PropertyValue]]

/// A property value — scalars and booleans appear as JSON strings/numbers.
public enum PropertyValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported property value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        }
    }

    public var displayString: String {
        switch self {
        case .string(let string): string
        case .number(let number): "\(number)"
        case .bool(let bool): bool ? "true" : "false"
        }
    }
}
