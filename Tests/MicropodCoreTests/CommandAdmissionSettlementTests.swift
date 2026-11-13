import Darwin
import Foundation
import XCTest

@testable import MicropodCore

@MainActor
final class CommandAdmissionSettlementTests: XCTestCase {
    private func fixture() throws -> (URL, RuntimeAdmission, ContainerCLIClient) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let admission = RuntimeAdmission(root: root)
        try admission.begin(operation: UUID()).releaseAfterVerification()
        return (
            root, admission, ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"), admission: admission)
        )
    }

    func testKnownNonzeroRunReportsFailureAndSettlesAdmission() async throws {
        let (root, admission, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await client.run(.init(arguments: ["-c", "exit 7"]))
            XCTFail("A failed command was reported successful")
        } catch MicropodError.cliFailure(_, let code, _) {
            XCTAssertEqual(code, 7)
        }
        try admission.begin(operation: UUID()).releaseAfterVerification()
    }

    func testKnownNonzeroStreamDeliversOutputAndSettlesAdmission() async throws {
        let (root, admission, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var output = Data()
        do {
            for try await bytes in client.stream(
                .init(arguments: ["-c", "printf settled-output; exit 7"]), reportExitCode: true)
            {
                output.append(bytes)
            }
            XCTFail("A failed stream was reported successful")
        } catch MicropodError.cliFailure(_, let code, _) {
            XCTAssertEqual(code, 7)
        }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "settled-output")
        try admission.begin(operation: UUID()).releaseAfterVerification()
    }

    func testSignalDeathKeepsRunAndStreamUncertain() async throws {
        for streaming in [false, true] {
            let (root, admission, client) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let command = ContainerCommand(arguments: ["-c", "kill -KILL $$"])
                if streaming {
                    for try await _ in client.stream(command) {}
                } else {
                    _ = try await client.run(command)
                }
                XCTFail("Signal death was reported successful")
            } catch MicropodError.cliFailure(_, let code, _) {
                XCTAssertEqual(code, -SIGKILL)
            }
            XCTAssertThrowsError(try admission.begin(operation: UUID()))
        }
    }

    func testCancellationKeepsPendingIntentAfterReap() async throws {
        let (root, admission, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("started")
        let task = Task {
            try await client.run(.init(arguments: ["-c", "touch \"$1\"; exec /bin/sleep 60", "fixture", marker.path]))
        }
        defer { task.cancel() }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation was reported successful")
        } catch is CancellationError {}
        XCTAssertThrowsError(try admission.begin(operation: UUID()))
    }
}
