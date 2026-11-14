import Darwin
import Foundation
import XCTest

@testable import MicropodCore

final class RuntimeProcessBirthTests: XCTestCase {
    func testKernelIncarnationIsStableAndLiveProcessIsNotReportedExited() throws {
        let birth = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        XCTAssertEqual(birth.uid, geteuid())
        XCTAssertEqual(try RuntimeProcessBirth.read(getpid()), birth)
        XCTAssertFalse(try birth.hasExited())
        XCTAssertThrowsError(try RuntimeProcessBirth.read(-1))
        XCTAssertNil(try RuntimeProcessBirth.read(Int32.max))
    }
    func testReusedPIDFromAnotherBootCannotRetainWorkerOwnership() throws {
        let current = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        var retained = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        retained["bootSession"] = UUID().uuidString
        let previousBoot = try JSONDecoder().decode(
            RuntimeProcessBirth.self, from: JSONSerialization.data(withJSONObject: retained))
        XCTAssertEqual(previousBoot.pid, current.pid)
        XCTAssertTrue(try previousBoot.hasExited())
        XCTAssertFalse(try current.hasExited())
    }

    func testCommandEnvironmentIsPassedToChildWithoutChangingParent() async throws {
        let key = "MICROPOD_COMMAND_ENVIRONMENT_TEST"
        let before = ProcessInfo.processInfo.environment[key]
        let output = try await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/printenv")).run(
            .init(arguments: [key], environment: [key: "private-worker-value"]))
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "private-worker-value")
        XCTAssertEqual(ProcessInfo.processInfo.environment[key], before)
    }
}
