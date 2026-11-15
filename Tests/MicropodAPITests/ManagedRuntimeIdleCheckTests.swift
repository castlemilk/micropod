import MicropodCore
import XCTest

@testable import MicropodAPI

final class ManagedRuntimeIdleCheckTests: XCTestCase {
    func testHiddenRunningSandboxStillPreventsAPIShutdown() async throws {
        var sandbox = Micropod_V1_Container()
        sandbox.id = "hidden-sandbox"
        sandbox.state = "running"
        let idle = try await ManagedRuntimeIdleCheck.check(visible: { [] }, ownedSandboxes: { [sandbox] })
        XCTAssertFalse(idle, "Disabling an engine must not authorize killing its live VM")
    }
    func testUnconfirmedOwnedSessionsCannotReportIdle() async {
        do {
            _ = try await ManagedRuntimeIdleCheck.check(
                visible: { [] }, ownedSandboxes: { throw CocoaError(.fileReadUnknown) })
            XCTFail("Unavailable owned-session inventory authorized shutdown")
        } catch {}
    }
}
