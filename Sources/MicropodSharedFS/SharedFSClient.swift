import Foundation

/// Public protocol the shim/CLI uses to talk to the daemon. The default
/// transport is a unix socket; the daemon also implements the protocol
/// directly (in-process tests use it without a socket).
public protocol SharedFSClient: Sendable {
    func mount(src: URL, readonly: Bool) async throws -> MountInfo
    /// Live shared mount — all containers mounting the same src share one
    /// view directory, with bidirectional FSEvents sync for live writes.
    func mountShared(src: URL, readonly: Bool) async throws -> MountInfo
    func unmount(id: ViewID) async throws
    func inspect(id: ViewID) async throws -> MountInfo
    func sync(id: ViewID) async throws -> SyncResult
    func refresh(id: ViewID) async throws -> MountInfo
    func list() async throws -> [MountInfo]
    func gc() async throws -> GCResult
}

public struct MountInfo: Codable, Sendable, Hashable {
    public let id: ViewID
    public let src: String
    public let viewPath: String
    public let sizeBytes: UInt64
    public let readonly: Bool
    public let createdAt: Date
}

public struct SyncResult: Codable, Sendable {
    public let id: ViewID
    public let synced: [String]
    public let bytesWritten: UInt64
}

public struct GCResult: Codable, Sendable {
    public let chunksRemoved: Int
    public let bytesReclaimed: UInt64
}

/// IPC envelope — one JSON object per line.
struct IPCRequest: Codable {
    let id: String
    let method: String
    let params: [String: AnyCodable]
}

struct IPCResponse: Codable {
    let id: String
    let ok: Bool
    let result: AnyCodable?
    let error: String?
}

/// JSON-friendly value shim — Foundation's `JSONSerialization` accepts
/// `[String: Any]`; we round-trip arbitrary values through `AnyCodable` to
/// keep the protocol simple.
struct AnyCodable: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let a = try? container.decode([AnyCodable].self) {
            self.value = a.map { $0.value }
        } else if let d = try? container.decode([String: AnyCodable].self) {
            self.value = d.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let i as Int64:
            try container.encode(i)
        case let i as UInt:
            try container.encode(i)
        case let i as UInt64:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let a as [Any]:
            try container.encode(a.map(AnyCodable.init))
        case let d as [String: Any]:
            try container.encode(d.mapValues(AnyCodable.init))
        default:
            try container.encodeNil()
        }
    }

    func encodeForJSON() -> Any {
        value
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}
