import Foundation
import MicropodCore
import XCTest

@testable import MicropodMCP

/// Tool arguments are read as their JSON types: a value of the wrong type
/// fails the call, where the old string-only reader turned `true` into ""
/// and so into `false`, and `1000` into "no limit".
final class MCPArgumentsTests: XCTestCase {
    private let tool = MCPTool(
        name: "probe", description: "",
        parameters: [
            .boolean("flag", ""),
            .integer("count", "", in: 1...256),
            .size("bytes", ""),
            .duration("age", ""),
            .choice("mode", ["auto", "off"], ""),
            .choice("action", ["start"], "", noun: "runtime action"),
            .list("items", ""),
            .number("cpus", ""),
            .string("name", ""),
            .string("id", "", required: true),
        ])

    private func read(_ raw: [String: JSONValue]) throws -> MCPArguments {
        var arguments = raw
        if arguments["id"] == nil { arguments["id"] = .string("x") }
        return try MCPArguments(arguments, for: tool)
    }

    private func message(_ raw: [String: JSONValue]) -> String {
        do {
            _ = try read(raw)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func testBooleansAreJSONBooleansOrTheirStringForms() throws {
        XCTAssertEqual(try read(["flag": .bool(true)]).bool("flag"), true)
        XCTAssertEqual(try read(["flag": .bool(false)]).bool("flag"), false)
        XCTAssertEqual(try read(["flag": .string("true")]).bool("flag"), true)
        XCTAssertEqual(try read(["flag": .string("FALSE")]).bool("flag"), false)
        XCTAssertEqual(try read(["flag": .string("yes")]).bool("flag"), true)
        XCTAssertEqual(try read(["flag": .string("off")]).bool("flag"), false)
        XCTAssertNil(try read(["flag": .null]).bool("flag"))
        XCTAssertNil(try read(["flag": .string("")]).bool("flag"), "an empty string counts as omitted")
        XCTAssertNil(try read([:]).bool("flag"))
        for bad: JSONValue in [.number(1), .string("maybe"), .array([.bool(true)]), .object([:])] {
            XCTAssertTrue(
                message(["flag": bad]).contains("flag must be a boolean"), "\(bad): \(message(["flag": bad]))")
        }
    }

    func testIntegersAreWholeNumbersInRange() throws {
        XCTAssertEqual(try read(["count": .number(16)]).integer("count"), 16)
        XCTAssertEqual(try read(["count": .string("32")]).integer("count"), 32)
        for bad: JSONValue in [.number(16.5), .number(0), .number(300), .bool(true), .string("lots"), .string("1e2")] {
            XCTAssertTrue(
                message(["count": bad]).contains("count must be an integer from 1 to 256"),
                "\(bad): \(message(["count": bad]))")
        }
        XCTAssertEqual(try read(["cpus": .number(1.5)]).number("cpus"), 1.5)
        XCTAssertEqual(try read(["cpus": .string("2")]).number("cpus"), 2)
        XCTAssertTrue(message(["cpus": .bool(true)]).contains("cpus must be a number"))
    }

    func testSizesAreBytesOrSizeStrings() throws {
        XCTAssertEqual(try read(["bytes": .number(1000)]).bytes("bytes"), 1000)
        XCTAssertEqual(try read(["bytes": .number(0)]).bytes("bytes"), 0)
        XCTAssertEqual(try read(["bytes": .string("1048576")]).bytes("bytes"), 1 << 20)
        XCTAssertEqual(try read(["bytes": .string("20g")]).bytes("bytes"), 20 << 30)
        XCTAssertEqual(try read(["bytes": .string("20GB")]).bytes("bytes"), 20 << 30)
        XCTAssertEqual(try read(["bytes": .string("512mib")]).bytes("bytes"), 512 << 20)
        XCTAssertEqual(try read(["bytes": .string("4k")]).bytes("bytes"), 4096)
        XCTAssertEqual(try read(["bytes": .string("2t")]).bytes("bytes"), 2 << 40)
        for bad: JSONValue in [
            .number(-1), .number(1.5), .string("-1"), .string("1.5g"), .string("lots"), .string("g"),
            .string("99999999999t"), .bool(true), .array([]),
        ] {
            XCTAssertTrue(
                message(["bytes": bad]).contains("bytes must be a size"), "\(bad): \(message(["bytes": bad]))")
        }
    }

    func testDurationsAreSecondsOrDurationStrings() throws {
        XCTAssertEqual(try read(["age": .number(3600)]).integer("age"), 3600)
        XCTAssertEqual(try read(["age": .string("90s")]).integer("age"), 90)
        XCTAssertEqual(try read(["age": .string("30m")]).integer("age"), 1800)
        XCTAssertEqual(try read(["age": .string("12h")]).integer("age"), 43200)
        XCTAssertEqual(try read(["age": .string("14d")]).integer("age"), 14 * 86400)
        XCTAssertEqual(try read(["age": .string("120")]).integer("age"), 120)
        for bad: JSONValue in [.number(-5), .string("1.5h"), .string("soon"), .bool(false)] {
            XCTAssertTrue(message(["age": bad]).contains("age must be a duration"), "\(bad): \(message(["age": bad]))")
        }
    }

    func testChoicesListsAndStrings() throws {
        XCTAssertEqual(try read(["mode": .string("off")]).string("mode"), "off")
        XCTAssertEqual(message(["mode": .string("Off")]), "Unknown mode 'Off' — want auto|off")
        XCTAssertEqual(message(["action": .string("shell")]), "Unknown runtime action 'shell' — want start")
        XCTAssertTrue(message(["mode": .bool(true)]).contains("mode must be one of auto|off"))
        XCTAssertEqual(try read(["items": .string("a, b,,c")]).list("items"), ["a", "b", "c"])
        XCTAssertEqual(try read(["items": .array([.string("a:/b"), .number(8080)])]).list("items"), ["a:/b", "8080"])
        XCTAssertEqual(try read(["items": .array([])]).list("items"), [])
        XCTAssertTrue(try read(["items": .array([])]).has("items"), "an empty array is a value")
        XCTAssertFalse(try read(["items": .string("")]).has("items"))
        XCTAssertTrue(message(["items": .array([.bool(true)])]).contains("items must be a comma-separated string"))
        XCTAssertTrue(message(["items": .number(1)]).contains("items must be a comma-separated string"))
        XCTAssertEqual(try read(["name": .string("web")]).string("name"), "web")
        XCTAssertEqual(try read([:]).string("name"), "")
        XCTAssertNil(try read([:]).optionalString("name"))
        XCTAssertTrue(message(["name": .number(5)]).contains("name must be a string, got 5"))
    }

    func testUnknownAndMissingArgumentsFailTheCall() {
        XCTAssertEqual(
            message(["dryrun": .bool(true)]),
            "probe: unknown argument 'dryrun' — it accepts flag, count, bytes, age, mode, action, items, cpus, name, id"
        )
        XCTAssertThrowsError(try MCPArguments([:], for: tool)) { error in
            XCTAssertEqual(error.localizedDescription, "probe requires id")
        }
        XCTAssertThrowsError(try MCPArguments(["id": .string("")], for: tool)) { error in
            XCTAssertEqual(error.localizedDescription, "probe requires id")
        }
        let bare = MCPTool(name: "bare", description: "")
        XCTAssertThrowsError(try MCPArguments(["x": .bool(true)], for: bare)) { error in
            XCTAssertEqual(error.localizedDescription, "bare: unknown argument 'x' — it takes no arguments")
        }
        XCTAssertNoThrow(try MCPArguments([:], for: bare))
    }

    /// Every wrong argument is named in the one refusal, not just the first
    /// in parameter order: a caller learns all it has to fix, and a refusal
    /// always names the argument that was wrong.
    func testEveryWrongArgumentIsNamed() {
        let reply = message(["mode": .string("sideways"), "flag": .string("perhaps")])
        XCTAssertEqual(
            reply,
            "probe: flag must be a boolean (true or false), got 'perhaps'; Unknown mode 'sideways' — want auto|off")
        XCTAssertThrowsError(try MCPArguments(["count": .string("lots")], for: tool)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("count") && text.contains("requires id"), text)
        }
        // One problem reads exactly as before.
        XCTAssertEqual(
            message(["flag": .string("perhaps")]), "probe: flag must be a boolean (true or false), got 'perhaps'")
    }

    // MARK: Schemas

    func testEveryToolAdvertisesATypedClosedObjectSchema() throws {
        let tools = MCPToolCatalog.tools
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count, "tool names are unique")
        for tool in tools {
            XCTAssertTrue(MCPToolCatalog.tool(named: tool.name) != nil)
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { return XCTFail("\(tool.name): no object schema") }
            XCTAssertEqual(schema["type"], .string("object"), tool.name)
            XCTAssertEqual(schema["additionalProperties"], .bool(false), tool.name)
            XCTAssertEqual(Set(properties.keys), Set(tool.parameters.map(\.name)), tool.name)
            XCTAssertEqual(properties.count, tool.parameters.count, "\(tool.name): parameter names are unique")
            for (name, property) in properties {
                guard case .object(let fields) = property else { return XCTFail("\(tool.name).\(name)") }
                XCTAssertNotNil(fields["type"], "\(tool.name).\(name) has a type")
                XCTAssertNotNil(fields["description"], "\(tool.name).\(name) has a description")
            }
            let required = tool.parameters.filter(\.required).map { JSONValue.string($0.name) }
            XCTAssertEqual(schema["required"], required.isEmpty ? nil : .array(required), tool.name)
        }
    }

    func testCacheToolSchemasNameTheirJSONTypes() throws {
        func property(_ tool: String, _ name: String) -> [String: JSONValue] {
            guard case .object(let schema)? = MCPToolCatalog.tool(named: tool)?.inputSchema,
                case .object(let properties)? = schema["properties"],
                case .object(let property)? = properties[name]
            else { return [:] }
            return property
        }
        for name in ["apply", "dry_run", "all", "partial_go_build"] {
            XCTAssertEqual(property("cache_prune", name)["type"], .string("boolean"), name)
        }
        XCTAssertEqual(property("cache_prune", "max_bytes")["type"], .array([.string("integer"), .string("string")]))
        XCTAssertEqual(property("cache_policy_set", "shared_l0")["type"], .string("boolean"))
        XCTAssertEqual(property("cache_policy_set", "mode")["enum"], .array([.string("auto"), .string("off")]))
        XCTAssertEqual(property("cache_dedupe", "buckets")["type"], .string("integer"))
        XCTAssertEqual(property("cache_dedupe", "buckets")["maximum"], .number(256))
        XCTAssertEqual(property("runtime_mode", "mode")["enum"], .array([.string("container"), .string("sandbox")]))
    }
}
