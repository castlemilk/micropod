import XCTest

@testable import MicropodCLI

/// Flag parsing for the `micropod` CLI. Short flags are aliases resolved by
/// the parser, so a command reads one canonical name: `ps -a` used to parse
/// `-a` as a separate flag that `ps` never read, silently listing only
/// running containers.
final class ArgParserTests: XCTestCase {
    func testShortAliasReadsAsLongFlag() throws {
        let parsed = try parseArgs(
            ["-a"], boolFlags: ["--all"], valueFlags: [], aliases: ["-a": "--all"], commandName: "ps")
        XCTAssertTrue(parsed.has("--all"))
        XCTAssertFalse(parsed.has("-a"), "only the canonical name is recorded")
    }

    func testLongFlagStillWorks() throws {
        let parsed = try parseArgs(
            ["--all"], boolFlags: ["--all"], valueFlags: [], aliases: ["-a": "--all"], commandName: "ps")
        XCTAssertTrue(parsed.has("--all"))
    }

    func testAliasedValueFlagTakesSeparateAndInlineValues() throws {
        let aliases = ["-n": "--tail"]
        let separate = try parseArgs(
            ["web", "-n", "5"], boolFlags: [], valueFlags: ["--tail"], aliases: aliases, commandName: "logs")
        XCTAssertEqual(separate.value("--tail"), "5")
        XCTAssertEqual(separate.positionals, ["web"])
        let inline = try parseArgs(
            ["-n=7", "web"], boolFlags: [], valueFlags: ["--tail"], aliases: aliases, commandName: "logs")
        XCTAssertEqual(inline.value("--tail"), "7")
    }

    func testRepeatedAliasedValuesAccumulate() throws {
        let parsed = try parseArgs(
            ["-e", "A=1", "--env", "B=2", "img"], boolFlags: [], valueFlags: ["--env"],
            aliases: ["-e": "--env"], commandName: "run")
        XCTAssertEqual(parsed.values("--env"), ["A=1", "B=2"])
    }

    /// A container command's own flags must survive: `exec web -- grep -i x`
    /// is grep's `-i`, not micropod's `--interactive`.
    func testAliasesNeverRewriteArgumentsAfterDoubleDash() throws {
        let parsed = try parseArgs(
            ["-i", "web", "--", "grep", "-i", "x"], boolFlags: ["--interactive"], valueFlags: [],
            aliases: ["-i": "--interactive"], commandName: "exec")
        XCTAssertTrue(parsed.has("--interactive"))
        XCTAssertEqual(parsed.positionals, ["web", "grep", "-i", "x"])
    }

    func testUnknownFlagErrorUsesTheSpellingGiven() {
        XCTAssertThrowsError(
            try parseArgs(["-z"], boolFlags: ["--all"], valueFlags: [], aliases: ["-a": "--all"], commandName: "ps")
        ) { error in
            XCTAssertEqual((error as? UsageError)?.message, "ps: unknown flag -z")
        }
    }

    func testMissingValueErrorUsesTheSpellingGiven() {
        XCTAssertThrowsError(
            try parseArgs(["-n"], boolFlags: [], valueFlags: ["--tail"], aliases: ["-n": "--tail"], commandName: "logs")
        ) { error in
            XCTAssertEqual((error as? UsageError)?.message, "logs: flag -n requires a value")
        }
    }
}
