import XCTest

@testable import MicropodDockerShim

/// Docker-conventional exec exit codes: the Apple CLI reports failed exec
/// spawns as plain failures, so the shim recovers 126/127 from stderr text.
final class ExecExitCodeTests: XCTestCase {
    func testZeroPassesThrough() {
        XCTAssertEqual(ExecSession.dockerExitCode(cliStatus: 0, stderr: ""), 0)
        XCTAssertEqual(
            ExecSession.dockerExitCode(cliStatus: 0, stderr: "failed to find target executable /x"), 0)
    }

    func testMissingBinaryMapsTo127() {
        let stderr =
            "Error: failed to start process abc (cause: \"internalError: \"startProcess: failed to start process: internalError: \"vmexec error: internalError: \"failed to find target executable /bin/sh\"\"\"\")"
        XCTAssertEqual(ExecSession.dockerExitCode(cliStatus: 1, stderr: stderr), 127)
    }

    func testPermissionDeniedMapsTo126() {
        let stderr =
            "Error: failed to exec [/etc/hostname] Error Domain=NSPOSIXErrorDomain Code=13 \"Permission denied\"\nError: failed to start process abc (cause: ...)"
        XCTAssertEqual(ExecSession.dockerExitCode(cliStatus: 1, stderr: stderr), 126)
    }

    func testGenuineExitsPassThrough() {
        for code: Int32 in [1, 2, 7, 42, 125, 137, 143] {
            XCTAssertEqual(
                ExecSession.dockerExitCode(cliStatus: code, stderr: "some output\n"),
                Int(code), "exit \(code) must survive")
            XCTAssertEqual(
                ExecSession.dockerExitCode(cliStatus: code, stderr: ""), Int(code))
        }
    }

    func testStartFailureWithoutMarkerPassesThrough() {
        // Unknown failure text: report what the runtime said, don't invent 127.
        XCTAssertEqual(
            ExecSession.dockerExitCode(cliStatus: 3, stderr: "weird failure"), 3)
    }
}
