import Foundation
import XCTest

@testable import MicropodCore

final class IsolatedRuntimeCommandPolicyTests: XCTestCase {
    func testLifecycleAndRuntimeRetargetingCannotCrossDataPlane() throws {
        for arguments in [
            ["system", "stop"], ["system", "start"], ["plugin", "restart", "container-runtime-linux"],
            ["run", "--app-root=/tmp/other", "alpine"], ["system", "status", "--install-root", "/tmp/other"],
        ] {
            let request = try IsolatedRuntimeCLIRequest(command: .init(arguments: arguments), timeout: .seconds(10))
            XCTAssertThrowsError(try request.command(), "Forwarded forbidden arguments: \(arguments)")
        }
        let status = try IsolatedRuntimeCLIRequest(
            command: .init(arguments: ["system", "status", "--format", "json"]), timeout: .seconds(10),
            acceptingExitCodes: [0, 1])
        XCTAssertEqual(try status.command().arguments, ["system", "status", "--format", "json"])
        XCTAssertThrowsError(
            try IsolatedRuntimeCLIRequest(
                command: .init(arguments: ["run", "alpine"], environment: ["CONTAINER_APP_ROOT": "/tmp/other"]),
                timeout: .seconds(10)))
    }
}
