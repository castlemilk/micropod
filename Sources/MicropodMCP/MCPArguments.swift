import Foundation
import MicropodCore

// MARK: - Tool parameters

/// One argument a tool accepts. Its kind drives both the tool's advertised
/// `inputSchema` and how a call's value is read: a value of the wrong JSON
/// type is a tool error, never a silent default (`{"dry_run": true}` once
/// read as a string became `false` and pruned for real).
struct MCPParameter: Sendable {
    enum Kind: Sendable, Equatable {
        case string
        /// A JSON boolean, or its string form (true/false, yes/no, on/off, 1/0).
        case boolean
        /// A JSON integer within the bounds, or its decimal string.
        case integer(min: Int64, max: Int64)
        /// A JSON number, or its decimal string.
        case number
        /// Bytes: a JSON integer, or a size string such as 512m or 20g.
        case size
        /// Seconds: a JSON integer, or a duration string such as 90s, 30m, 12h or 14d.
        case duration
        /// One of the listed strings, exactly.
        case choice([String])
        /// Strings: a JSON array (of strings or integers), or one comma-separated string.
        case list
    }

    let name: String
    let kind: Kind
    let summary: String
    var required = false
    /// What an unknown choice is called in the error ("Unknown runtime action …").
    var noun: String?

    static func string(_ name: String, _ summary: String, required: Bool = false) -> MCPParameter {
        MCPParameter(name: name, kind: .string, summary: summary, required: required)
    }

    static func boolean(_ name: String, _ summary: String) -> MCPParameter {
        MCPParameter(name: name, kind: .boolean, summary: summary)
    }

    static func integer(_ name: String, _ summary: String, in range: ClosedRange<Int64>) -> MCPParameter {
        MCPParameter(name: name, kind: .integer(min: range.lowerBound, max: range.upperBound), summary: summary)
    }

    static func number(_ name: String, _ summary: String) -> MCPParameter {
        MCPParameter(name: name, kind: .number, summary: summary)
    }

    static func size(_ name: String, _ summary: String) -> MCPParameter {
        MCPParameter(name: name, kind: .size, summary: summary)
    }

    static func duration(_ name: String, _ summary: String) -> MCPParameter {
        MCPParameter(name: name, kind: .duration, summary: summary)
    }

    static func choice(
        _ name: String, _ values: [String], _ summary: String, required: Bool = false, noun: String? = nil
    ) -> MCPParameter {
        MCPParameter(name: name, kind: .choice(values), summary: summary, required: required, noun: noun)
    }

    static func list(_ name: String, _ summary: String) -> MCPParameter {
        MCPParameter(name: name, kind: .list, summary: summary)
    }

    /// This parameter's JSON Schema.
    var schema: JSONValue {
        var schema: [String: JSONValue] = ["description": .string(summary)]
        switch kind {
        case .string:
            schema["type"] = .string("string")
        case .boolean:
            schema["type"] = .string("boolean")
        case .integer(let min, let max):
            schema["type"] = .string("integer")
            schema["minimum"] = .number(Double(min))
            if max != .max { schema["maximum"] = .number(Double(max)) }
        case .number:
            schema["type"] = .string("number")
        case .size, .duration:
            schema["type"] = .array([.string("integer"), .string("string")])
            schema["minimum"] = .number(0)
        case .choice(let values):
            schema["type"] = .string("string")
            schema["enum"] = .array(values.map(JSONValue.string))
        case .list:
            schema["type"] = .array([.string("array"), .string("string")])
            schema["items"] = .object(["type": .string("string")])
        }
        return .object(schema)
    }
}

/// A tool as `tools/list` advertises it.
struct MCPTool: Sendable {
    let name: String
    let description: String
    var parameters: [MCPParameter] = []

    /// `{type: object, properties, required, additionalProperties: false}`:
    /// a call naming anything else is refused (`MCPArguments`).
    var inputSchema: JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(
                Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) })),
            "additionalProperties": .bool(false),
        ]
        let required = parameters.filter(\.required).map { JSONValue.string($0.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    var listing: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }
}

// MARK: - A call's arguments

/// An argument the call got wrong — reported to the model as a tool error.
struct MCPArgumentError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A tool call's arguments, checked against the tool's parameters before
/// the tool runs: an unknown name, a missing required argument or a value
/// of the wrong type fails the call up front, so nothing downstream ever
/// sees a guessed value. JSON `null` and `""` count as omitted, as an
/// absent key does.
struct MCPArguments: Sendable {
    enum Value: Sendable, Equatable {
        case string(String)
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case bytes(UInt64)
        case list([String])
    }

    let tool: String
    private let values: [String: Value]
    private let declared: Set<String>
    /// Declared arguments given as `""` (which, like null, count as omitted).
    private let emptyStrings: Set<String>

    init(_ raw: [String: JSONValue], for tool: MCPTool) throws {
        let declared = Set(tool.parameters.map(\.name))
        self.tool = tool.name
        self.declared = declared
        let unknown = raw.keys.filter { !declared.contains($0) }.sorted()
        if let first = unknown.first {
            let accepted = tool.parameters.map(\.name)
            throw MCPArgumentError(
                message: "\(tool.name): unknown argument '\(first)' — "
                    + (accepted.isEmpty ? "it takes no arguments" : "it accepts \(accepted.joined(separator: ", "))"))
        }
        var values: [String: Value] = [:]
        emptyStrings = Set(raw.compactMap { key, value in value == .string("") ? key : nil })
        for parameter in tool.parameters {
            if let raw = raw[parameter.name], let value = try Self.read(raw, as: parameter, tool: tool.name) {
                values[parameter.name] = value
            } else if parameter.required {
                throw MCPArgumentError(message: "\(tool.name) requires \(parameter.name)")
            }
        }
        self.values = values
    }

    // MARK: Accessors

    func has(_ key: String) -> Bool { value(key) != nil }

    /// The call gave `key` as `""`: omitted for every accessor, but a tool
    /// for which "" means "clear" can tell it from absent.
    func isEmptyString(_ key: String) -> Bool {
        assert(declared.contains(key), "\(tool) reads undeclared argument '\(key)'")
        return emptyStrings.contains(key)
    }

    /// The string, or "" when omitted.
    func string(_ key: String) -> String { optionalString(key) ?? "" }

    func optionalString(_ key: String) -> String? {
        if case .string(let text)? = value(key) { return text }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let flag)? = value(key) { return flag }
        return nil
    }

    /// The boolean, or false when omitted.
    func flag(_ key: String) -> Bool { bool(key) ?? false }

    /// An `integer` or `duration` (seconds) argument.
    func integer(_ key: String) -> Int64? {
        if case .integer(let number)? = value(key) { return number }
        return nil
    }

    func number(_ key: String) -> Double? {
        if case .number(let number)? = value(key) { return number }
        return nil
    }

    /// A `size` argument, in bytes.
    func bytes(_ key: String) -> UInt64? {
        if case .bytes(let bytes)? = value(key) { return bytes }
        return nil
    }

    /// A `list` argument, or [] when omitted.
    func list(_ key: String) -> [String] {
        if case .list(let items)? = value(key) { return items }
        return []
    }

    private func value(_ key: String) -> Value? {
        assert(declared.contains(key), "\(tool) reads undeclared argument '\(key)'")
        return values[key]
    }

    // MARK: Reading one value

    private static func read(_ raw: JSONValue, as parameter: MCPParameter, tool: String) throws -> Value? {
        if case .null = raw { return nil }
        if case .string(let text) = raw, text.isEmpty { return nil }
        func invalid(_ want: String) -> MCPArgumentError {
            MCPArgumentError(message: "\(tool): \(parameter.name) must be \(want), got \(describe(raw))")
        }
        switch parameter.kind {
        case .string:
            guard case .string(let text) = raw else { throw invalid("a string") }
            return .string(text)

        case .boolean:
            switch raw {
            case .bool(let flag): return .bool(flag)
            case .string(let text):
                switch text.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "yes", "on", "1": return .bool(true)
                case "false", "no", "off", "0": return .bool(false)
                default: throw invalid("a boolean (true or false)")
                }
            default: throw invalid("a boolean (true or false)")
            }

        case .integer(let min, let max):
            let want = max == .max ? "an integer ≥ \(min)" : "an integer from \(min) to \(max)"
            guard let number = integer(raw), (min...max).contains(number) else { throw invalid(want) }
            return .integer(number)

        case .number:
            switch raw {
            case .number(let number) where number.isFinite: return .number(number)
            case .string(let text):
                guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else {
                    throw invalid("a number")
                }
                return .number(number)
            default: throw invalid("a number")
            }

        case .size:
            let want = "a size in bytes, e.g. 1048576, 512m or 20g"
            switch raw {
            case .number:
                guard let number = integer(raw), number >= 0 else { throw invalid(want) }
                return .bytes(UInt64(number))
            case .string(let text):
                guard let bytes = parseSize(text) else { throw invalid(want) }
                return .bytes(bytes)
            default: throw invalid(want)
            }

        case .duration:
            let want = "a duration in seconds, e.g. 3600, 90s, 30m, 12h or 14d"
            switch raw {
            case .number:
                guard let number = integer(raw), number >= 0 else { throw invalid(want) }
                return .integer(number)
            case .string(let text):
                guard let seconds = parseDuration(text) else { throw invalid(want) }
                return .integer(seconds)
            default: throw invalid(want)
            }

        case .choice(let values):
            guard case .string(let text) = raw else { throw invalid("one of \(values.joined(separator: "|"))") }
            guard values.contains(text) else {
                throw MCPArgumentError(
                    message:
                        "Unknown \(parameter.noun ?? parameter.name) '\(text)' — want \(values.joined(separator: "|"))"
                )
            }
            return .string(text)

        case .list:
            let want = "a comma-separated string or an array of strings"
            switch raw {
            case .string(let text):
                return .list(
                    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            case .array(let items):
                return .list(
                    try items.map { item in
                        if case .string(let text) = item { return text }
                        // A port list may come as numbers: [8080, 9090].
                        guard case .number = item, let number = integer(item) else { throw invalid(want) }
                        return String(number)
                    })
            default: throw invalid(want)
            }
        }
    }

    /// An integral JSON number, or a decimal integer string.
    private static func integer(_ raw: JSONValue) -> Int64? {
        switch raw {
        case .number(let number):
            guard number.isFinite, number.rounded() == number else { return nil }
            return Int64(exactly: number)
        case .string(let text):
            return Int64(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static func describe(_ raw: JSONValue) -> String {
        switch raw {
        case .string(let text): return "'\(text)'"
        case .number(let number):
            return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag): return String(flag)
        case .array: return "an array"
        case .object: return "an object"
        case .null: return "null"
        }
    }

    /// Bytes from a whole number with an optional k/m/g/t suffix, in binary
    /// multiples: "1048576", "512m", "20g" ("kb", "kib" and "b" read too).
    static func parseSize(_ raw: String) -> UInt64? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, UInt64)] = [
            ("tib", 1 << 40), ("tb", 1 << 40), ("t", 1 << 40),
            ("gib", 1 << 30), ("gb", 1 << 30), ("g", 1 << 30),
            ("mib", 1 << 20), ("mb", 1 << 20), ("m", 1 << 20),
            ("kib", 1 << 10), ("kb", 1 << 10), ("k", 1 << 10),
            ("b", 1),
        ]
        let (suffix, scale) = units.first { text.hasSuffix($0.0) } ?? ("", 1)
        let digits = text.dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let count = UInt64(digits) else { return nil }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: scale)
        return overflow ? nil : bytes
    }

    /// Seconds from "3600", "90s", "30m", "12h" or "14d".
    static func parseDuration(_ raw: String) -> Int64? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Int64)] = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
        let (suffix, scale) = units.first { text.hasSuffix($0.0) } ?? ("", 1)
        let digits = text.dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let count = Int64(digits) else { return nil }
        let (seconds, overflow) = count.multipliedReportingOverflow(by: scale)
        return overflow ? nil : seconds
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
