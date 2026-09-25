import Foundation
import XCTest

@testable import MicropodCore

/// `ConnectCodeMapping` is the single error → Connect wire-code table the
/// Connect mount uses. Transport failures (XPC interrupted/invalid, runtime
/// down) must be `unavailable` so clients retry instead of treating them as
/// server bugs (`internal`).
final class ConnectCodeMappingTests: XCTestCase {
    private func code(_ error: MicropodError) -> String {
        ConnectCodeMapping.code(for: error)
    }

    func testTransportAndRuntimeDownAreUnavailable() {
        XCTAssertEqual(
            code(.transport("com.apple.container.apiserver: Connection interrupted")),
            "unavailable")
        XCTAssertEqual(code(.transport("connection invalidated")), "unavailable")
        XCTAssertEqual(code(.runtimeNotRunning), "unavailable")
        XCTAssertEqual(code(.cliUnavailable("/usr/local/bin/container")), "unavailable")
    }

    func testStructuredCasesKeepTheirCodes() {
        XCTAssertEqual(code(.cliTimeout(command: "container list")), "deadline_exceeded")
        XCTAssertEqual(code(.unsupported("clone commit requires the native backend")), "unimplemented")
        XCTAssertEqual(code(.pullStalled(reference: "alpine:3.20")), "aborted")
    }

    /// The `container` CLI's own runtime-down text (what every apiserver-backed
    /// command prints when the daemon is stopped) is `unavailable`; any other
    /// CLI failure keeps today's classification.
    func testStoppedRuntimeCLIFailureIsUnavailable() {
        let xpcDown = MicropodError.cliFailure(
            command: "container list", exitCode: 1,
            stderr:
                "Error: interrupted: \"XPC connection error: Connection invalid\n"
                + "Ensure container system service has been started with `container system start`.\"\n")
        XCTAssertEqual(code(xpcDown), "unavailable")

        let unregistered = MicropodError.cliFailure(
            command: "container system status", exitCode: 1,
            stderr: "apiserver is not running and not registered with launchd\n")
        XCTAssertEqual(code(unregistered), "unavailable")

        let ordinary = MicropodError.cliFailure(
            command: "container delete", exitCode: 1,
            stderr: "Error: notFound: \"container web not found\"\n")
        XCTAssertEqual(code(ordinary), "not_found", "unrelated CLI failures are not transport errors")
    }

    /// The `container` CLI renders a runtime error as `Error: <code>: "<detail>"`
    /// (ArgumentParser's wrapper around `ContainerizationError`'s description),
    /// so the code is read from that line through the same prefix table the
    /// native backend uses — `exists` is the runtime's own duplicate-id code.
    /// A failure with no such line, or an unknown code, stays `internal`.
    func testCLIFailureStderrClassifiesThroughThePrefixTable() {
        func cli(_ stderr: String, command: String = "container create") -> MicropodError {
            .cliFailure(command: command, exitCode: 1, stderr: stderr)
        }
        XCTAssertEqual(code(cli("Error: exists: \"container with id dup already exists\"\n")), "already_exists")
        XCTAssertEqual(code(cli("Error: alreadyExists: \"container with ID dup already exists\"\n")), "already_exists")
        XCTAssertEqual(code(cli("Error: notFound: \"container with ID web not found\"\n")), "not_found")
        XCTAssertEqual(code(cli("Error: failedPrecondition: \"volume in use\"\n")), "failed_precondition")
        XCTAssertEqual(
            code(cli("Error: invalidArgument: \"container ID a/b is not a valid container ID\"\n")),
            "invalid_argument")
        // A warning line ahead of the error line does not hide the code.
        XCTAssertEqual(
            code(cli("Warning: rosetta is not available\nError: notFound: \"image ghost:1 not found\"\n")),
            "not_found")
        // Not in the table: the runtime's `invalidState`, the mock's plain
        // phrasing, and a guest process's own stderr.
        XCTAssertEqual(code(cli("Error: invalidState: \"container web is not running\"\n")), "internal")
        XCTAssertEqual(code(cli("Error: no such container: web\n", command: "container delete")), "internal")
        XCTAssertEqual(code(cli("sh: notFound: command not found\n", command: "container exec")), "internal")
        XCTAssertEqual(code(cli("", command: "container exec")), "internal")
        // The message keeps its wrapper: only the code is read from stderr.
        XCTAssertEqual(
            cli("Error: exists: \"container with id dup already exists\"\n").localizedDescription,
            "`container create` failed (exit 1): Error: exists: \"container with id dup already exists\"")
    }

    func testIndicatesRuntimeDownMatchesCLISignaturesOnly() {
        XCTAssertTrue(ConnectCodeMapping.indicatesRuntimeDown("XPC connection error: Connection invalid"))
        XCTAssertTrue(ConnectCodeMapping.indicatesRuntimeDown("APISERVER IS NOT RUNNING"))
        XCTAssertTrue(ConnectCodeMapping.indicatesRuntimeDown("{\"status\":\"not running\"}"))
        XCTAssertFalse(
            ConnectCodeMapping.indicatesRuntimeDown("invalidState: container web is not running"),
            "a stopped *container* is not a stopped runtime")
        XCTAssertFalse(ConnectCodeMapping.indicatesRuntimeDown(""))
    }

    /// Upstream runtime errors arrive preformatted as "code: detail".
    func testUpstreamPrefixTable() {
        XCTAssertEqual(code(.message("notFound: container mpc-1 not found")), "not_found")
        XCTAssertEqual(code(.message("alreadyExists: container web exists")), "already_exists")
        // What the apiserver actually sends for a duplicate id over XPC
        // (`ContainerizationError(.exists, …)` — its code prints as `exists`).
        XCTAssertEqual(code(.message("exists: container already exists: web")), "already_exists")
        XCTAssertEqual(code(.message("invalidArgument: bad mount")), "invalid_argument")
        XCTAssertEqual(code(.message("failedPrecondition: volume in use")), "failed_precondition")
        XCTAssertEqual(code(.message("resourceExhausted: no ips")), "resource_exhausted")
        XCTAssertEqual(code(.message("permissionDenied: nope")), "permission_denied")
        XCTAssertEqual(code(.message("unauthenticated: login")), "unauthenticated")
        XCTAssertEqual(code(.message("unavailable: apiserver")), "unavailable")
        XCTAssertEqual(code(.message("runtimeNotRunning: apiserver")), "unavailable")
        XCTAssertEqual(code(.message("deadlineExceeded: slow")), "deadline_exceeded")
        XCTAssertEqual(code(.message("timeout: slow")), "deadline_exceeded")
        XCTAssertEqual(code(.message("something went wrong")), "internal")
        XCTAssertEqual(code(.message("unknownCode: thing")), "internal")
        XCTAssertEqual(code(.decode("bad json")), "internal")
    }

    func testNonMicropodErrorsUseTheirDescription() {
        struct Upstream: LocalizedError {
            let errorDescription: String?
        }
        XCTAssertEqual(
            ConnectCodeMapping.code(for: Upstream(errorDescription: "notFound: image ghost:1")),
            "not_found")
        XCTAssertEqual(ConnectCodeMapping.code(for: Upstream(errorDescription: "boom")), "internal")
        XCTAssertEqual(ConnectCodeMapping.code(for: CancellationError()), "internal")
    }
}
