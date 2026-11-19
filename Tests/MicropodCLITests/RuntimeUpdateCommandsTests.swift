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
}
