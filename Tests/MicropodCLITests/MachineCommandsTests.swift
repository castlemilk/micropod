import XCTest

@testable import MicropodCLI

/// `micropod machine …` argument handling: routing past the global flags,
/// and sizes and counts that must be usage errors rather than traps.
final class MachineCommandsTests: XCTestCase {
    func testGlobalFlagsAnywhereStillRouteToTheHVFMachine() throws {
        func route(_ argv: [String]) -> [String]? { MachineCommands.route(argv)?.args }
        XCTAssertEqual(route(["machine", "status"]), ["status"])
        XCTAssertEqual(route(["--no-color", "machine", "status"]), ["status"])
        XCTAssertEqual(
            route(["--cli", "/x/container", "machine", "install", "--cpus", "2"]), ["install", "--cpus", "2"])
        XCTAssertEqual(route(["machine", "stop", "--no-color"]), ["stop"], "not Apple's `machine stop <name>`")
        XCTAssertEqual(route(["machine", "logs", "-n", "5", "--no-color"]), ["logs", "-n", "5"])
        XCTAssertEqual(MachineCommands.route(["--json", "machine", "status"])?.json, true)
        XCTAssertEqual(MachineCommands.route(["machine", "status"])?.json, false)
        XCTAssertEqual(route(["machine", "buildkit-endpoint"]), ["buildkit-endpoint"])
        XCTAssertNil(route(["--no-color", "machine", "stop", "web"]), "a named machine is Apple's")
        XCTAssertNil(route(["machines", "logs", "web"]))
        XCTAssertNil(route(["ps", "--no-color"]))
        XCTAssertNil(route(["--cli"]))
    }

    func testDiskSizeOverflowIsAUsageError() throws {
        XCTAssertEqual(try MachineCommands.diskBytes("32g"), 32 << 30)
        XCTAssertEqual(try MachineCommands.diskBytes("40960M"), 40960 << 20)
        for bad in ["20000000000g", "18446744073709551615m", "0g", "-1g", "12", "g", "1.5g"] {
            XCTAssertThrowsError(try MachineCommands.diskBytes(bad), bad) { error in
                XCTAssertTrue(error is UsageError, "\(bad): \(error)")
            }
        }
    }

    func testLogsTailMustBeANonNegativeCount() throws {
        XCTAssertEqual(try MachineCommands.tailLines(try MachineCommands.parseLogs([])), 100)
        XCTAssertEqual(try MachineCommands.tailLines(try MachineCommands.parseLogs(["-n", "0"])), 0)
        XCTAssertEqual(try MachineCommands.tailLines(try MachineCommands.parseLogs(["--tail", "7"])), 7)
        for bad in [["-n", "-1"], ["--tail=-5"], ["-n", "lots"]] {
            XCTAssertThrowsError(try MachineCommands.tailLines(try MachineCommands.parseLogs(bad)), "\(bad)") { error in
                XCTAssertTrue(error is UsageError, "\(bad): \(error)")
            }
        }
    }
}
