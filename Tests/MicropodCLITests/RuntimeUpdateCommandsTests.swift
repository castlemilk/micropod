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
        XCTAssertNil(RuntimeAuthorityCommands.launchPathProblem(cli, allowedOwners: owners))
        XCTAssertEqual(chmod(bin.path, 0o777), 0)
        XCTAssertNotNil(RuntimeAuthorityCommands.launchPathProblem(cli, allowedOwners: owners))
        XCTAssertEqual(chmod(bin.path, 0o755), 0)
        XCTAssertNotNil(RuntimeAuthorityCommands.launchPathProblem(cli, allowedOwners: [0]), "another account's path")
    }
}
