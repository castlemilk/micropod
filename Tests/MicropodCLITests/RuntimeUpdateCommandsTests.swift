import MicropodCore
import XCTest

@testable import MicropodCLI

final class RuntimeUpdateCommandsTests: XCTestCase {
    /// The root helper verifies component manifests with the key the feeds
    /// are signed with; the two copies must never drift.
    func testTheComponentManifestKeyIsTheReleaseKey() {
        XCTAssertEqual(MicropodReleaseSigning.publicKey, SelfUpdate.publicKey)
    }

    func testUpdateIsAnOwnerCommandThatTakesNoPath() async throws {
        do {
            try await RuntimeUpdateCommands.run(["/Applications/Other.app"])
            XCTFail("A positional argument was accepted")
        } catch is UsageError {}
    }

    // `--force` is root's: the CLI says so before sending anything (the
    // helper decides from the peer's audit token regardless), and as root
    // only a forced update is sent.
    func testForceNeedsRootAndRootNeedsForce() async throws {
        XCTAssertNil(RuntimeUpdateCommands.privilegeProblem(force: true, euid: 0))
        XCTAssertNil(RuntimeUpdateCommands.privilegeProblem(force: false, euid: 501))
        XCTAssertTrue(RuntimeUpdateCommands.privilegeProblem(force: true, euid: 501)?.contains("sudo") == true)
        XCTAssertTrue(
            RuntimeUpdateCommands.privilegeProblem(force: false, euid: 0)?.contains("runtime's owner") == true)
        guard geteuid() != 0 else { throw XCTSkip("run as a user") }
        do {
            try await RuntimeUpdateCommands.run(["--force", "--detach"])
            XCTFail("--force ran without root")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("needs root"), error.localizedDescription)
        }
        do {
            try await RuntimeUpdateCommands.run(["--force", "--bootstrap"])
            XCTFail("--force with --bootstrap was accepted")
        } catch is UsageError {}
    }

    func testAForcedRequestPrintsOneLineNamingTheOverriddenCheck() {
        let forced = RuntimeComponentUpdateSummary(
            operation: UUID(), phase: "staging", rollback: false, sourceVersion: "0.13.12", targetVersion: "0.13.13",
            runtimeOperation: nil, reason: nil, forced: true,
            forcedOver: "unprotected: launchd's live authority job could not be read")
        let line = try? XCTUnwrap(RuntimeUpdateCommands.forcedLine(forced))
        XCTAssertEqual(line?.contains("\n"), false)
        XCTAssertTrue(
            line?.hasPrefix("FORCED over \"unprotected: launchd's live authority job could not be read\"") == true,
            line ?? "")
        let ordinary = RuntimeComponentUpdateSummary(
            operation: UUID(), phase: "staging", rollback: false, sourceVersion: "0.13.12", targetVersion: "0.13.13",
            runtimeOperation: nil, reason: nil)
        XCTAssertTrue(RuntimeUpdateCommands.forcedLine(ordinary)?.contains("overrode nothing") == true)
        XCTAssertNil(RuntimeUpdateCommands.forcedLine(nil))
    }

    // Requirement 1: install-authority refuses unless it runs as root, and as
    // root refuses an executable on a path another account can change.
    func testInstallAuthorityNeedsRootAndAProtectedLaunchPath() async throws {
        guard geteuid() != 0 else { throw XCTSkip("run as a user") }
        do {
            try await RuntimeAuthorityCommands.run([])
            XCTFail("install-authority ran without root")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("root"), error.localizedDescription)
        }
        let root = try RuntimeAuthorityCommands.realPath(FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("iap-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("micropod")
        try Data("cli".utf8).write(to: cli)
        let owners: Set<uid_t> = [0, getuid()]
        // The temporary directory's own ancestors belong to root or this user.
        XCTAssertNil(RuntimeAuthorityCommands.launchPathProblem(cli, owners: owners))
        XCTAssertEqual(chmod(bin.path, 0o777), 0)
        XCTAssertNotNil(RuntimeAuthorityCommands.launchPathProblem(cli, owners: owners))
        XCTAssertEqual(chmod(bin.path, 0o755), 0)
        // R2: the production rule is root-owned only, so a path the invoking
        // administrator owns (an unpacked download) is refused.
        let refused = RuntimeAuthorityCommands.launchPathProblem(cli)
        XCTAssertEqual(refused, "\(cli.path) is not owned by root")
        // An ACL granting write is refused like a mode bit.
        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow write", bin.path]
        try acl.run()
        acl.waitUntilExit()
        XCTAssertEqual(acl.terminationStatus, 0)
        XCTAssertEqual(
            RuntimeAuthorityCommands.launchPathProblem(cli, owners: owners), "\(bin.path) carries an ACL")
        XCTAssertTrue(RuntimeAuthorityCommands.instructions.contains("/var/root/micropod-install"))
    }
}
