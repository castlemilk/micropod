import Foundation

/// Loose JSON representation for fields whose exact shape is not part of
/// Micropod's contract (e.g. mount option objects, unknown detail fields).
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

public enum MicropodJSON {
    /// The shared decoder for all `container --format json` output.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    /// Decodes an array of T, tolerating a single object (rare CLI variance).
    public static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> [T] {
        do {
            return try decoder.decode([T].self, from: data)
        } catch {
            if let single = try? decoder.decode(T.self, from: data) {
                return [single]
            }
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MicropodError.decode("\(context): \(error.localizedDescription). Output: \(snippet)")
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MicropodError.decode("\(context): \(error.localizedDescription). Output: \(snippet)")
        }
    }
}
