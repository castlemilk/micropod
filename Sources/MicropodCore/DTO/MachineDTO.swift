import Foundation

/// One element of `container machine list --format json`.
public struct MachineEntry: Codable, Sendable {
    public let name: String
    public let created: String?
    public let ip: String?
    public let cpus: Int?
    public let memory: String?
    public let disk: String?
    public let state: String?
    public let defaultMachine: Bool?

    public init(name: String) {
        self.name = name
        self.created = nil
        self.ip = nil
        self.cpus = nil
        self.memory = nil
        self.disk = nil
        self.state = nil
        self.defaultMachine = nil
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
