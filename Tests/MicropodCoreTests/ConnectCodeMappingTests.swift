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

    /// A `container` CLI failure classifies from the first `Error:` line of
    /// its stderr. `Error: <code>: "<detail>"` reads through the same prefix
    /// table the native backend uses; a failure with no such line, or an
    /// unknown code, stays `internal`.
    func testCLIFailureStderrClassifiesThroughThePrefixTable() {
        func cli(_ stderr: String, command: String = "container create") -> MicropodError {
            .cliFailure(command: command, exitCode: 1, stderr: stderr)
        }
        // The XPC-style spelling of the runtime's duplicate-id code.
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
            cli("Error: container already exists: dup\n").localizedDescription,
            "`container create` failed (exit 1): Error: container already exists: dup")
    }

    /// The real CLI (`container` 1.3.1) prints its duplicate-id refusals as
    /// bare messages — `ContainerizationError.errorDescription` drops the
    /// code — so those phrases classify as `already_exists` on their own:
    /// `container create` says `container already exists: <id>`, `container
    /// run` says `container with id <id> already exists`. This is the answer
    /// a client adopting the container it already created relies on.
    func testCLIDuplicateIDPhrasesAreAlreadyExists() {
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container create --name dup nginx:1.27", exitCode: 1,
                    stderr: "Error: container already exists: dup\n")),
            "already_exists")
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container run --detach --name dup nginx:1.27", exitCode: 1,
                    stderr: "Error: container with id dup already exists\n")),
            "already_exists")
        // Any resource's "already exists" is the same refusal; the phrase
        // elsewhere than the `Error:` line is not read.
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container volume create v", exitCode: 1, stderr: "Error: volume v already exists\n")),
            "already_exists")
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container create --name dup nginx:1.27", exitCode: 1,
                    stderr: "note: container already exists: dup\nError: something else\n")),
            "internal")
    }

    /// Some verbs wrap the runtime's answer: `container delete <missing>`
    /// prints `Error: internalError: "failed to delete container" (cause:
    /// "notFound: "container with ID x not found"")`. The code is read from
    /// the cause — and only for `internalError`, whose own code says
    /// nothing; nested causes are read through to the first classifiable one.
    func testCLIInternalErrorClassifiesFromItsCause() {
        let deleteMissing = MicropodError.cliFailure(
            command: "container delete mpc-1", exitCode: 1,
            stderr:
                "Error: internalError: \"failed to delete container\" "
                + "(cause: \"notFound: \"container with ID mpc-1 not found\"\")\n")
        XCTAssertEqual(code(deleteMissing), "not_found")
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container start mpc-1", exitCode: 1,
                    stderr:
                        "Error: internalError: \"failed to start\" (cause: \"internalError: \"vm\" "
                        + "(cause: \"failedPrecondition: \"volume held\"\")\")\n")),
            "failed_precondition")
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container delete mpc-1", exitCode: 1,
                    stderr: "Error: internalError: \"failed to delete container\" (cause: \"boom\")\n")),
            "internal")
        XCTAssertEqual(
            code(.cliFailure(command: "container delete mpc-1", exitCode: 1, stderr: "Error: internalError: \"x\"\n")),
            "internal")
        // A classifiable outer code is not overridden by its cause.
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container stop mpc-1", exitCode: 1,
                    stderr: "Error: invalidState: \"not running\" (cause: \"notFound: \"x\"\")\n")),
            "internal")
    }

    /// `container exec` relays the guest process's stderr, which may carry
    /// an `Error:` line of its own: an exec failure is never classified from
    /// it. (`execDetailed` reports the exit code and text instead.)
    func testExecFailuresAreNeverClassifiedFromStderr() {
        XCTAssertEqual(
            code(
                .cliFailure(
                    command: "container exec web sh -c 'exit 3'", exitCode: 3,
                    stderr: "Error: notFound: \"config.yaml\"\n")),
            "internal")
        XCTAssertEqual(
            code(.cliFailure(command: "container exec web true", exitCode: 1, stderr: "Error: web already exists\n")),
            "internal")
        XCTAssertTrue(ConnectCodeMapping.isExecCommand("container exec web true"))
        XCTAssertTrue(ConnectCodeMapping.isExecCommand("container exec --detach web true"))
        XCTAssertFalse(ConnectCodeMapping.isExecCommand("container create --name exec nginx:1.27"))
        XCTAssertFalse(ConnectCodeMapping.isExecCommand("exec web"))
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
