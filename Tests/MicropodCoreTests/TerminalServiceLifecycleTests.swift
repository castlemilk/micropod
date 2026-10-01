import Darwin
import Foundation
import XCTest

@testable import MicropodCore

final class TerminalServiceLifecycleTests: XCTestCase {
    func testEOFDeliversFinalOutputAndRemovesSession() async throws {
        let fixture = try makeFixture("printf 'hello café\\n'\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try await fixture.service.open(containerID: "fixture", shell: "/bin/sh")
        var output = Data()
        for try await chunk in connection.stream { output.append(chunk) }
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("hello café"))
        try await waitForCleanup(fixture.service)
        try await fixture.service.close(sessionID: connection.sessionID)
        let sessions = await fixture.service.activeSessionCount
        XCTAssertEqual(sessions, 0)
    }

    func testCancellingAnIdleConsumerClosesItsShellAndSession() async throws {
        let fixture = try makeFixture("printf 'ready\\n'\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try await fixture.service.open(containerID: "fixture", shell: "/bin/sh")
        let consumedFirst = expectation(description: "reader attached")
        let consumer = Task {
            var first = true
            for try await _ in connection.stream {
                if first {
                    consumedFirst.fulfill()
                    first = false
                }
            }
        }
        await fulfillment(of: [consumedFirst], timeout: 2)
        consumer.cancel()
        _ = try? await consumer.value
        try await waitForCleanup(fixture.service)
        let sessions = await fixture.service.activeSessionCount
        XCTAssertEqual(sessions, 0)
    }

    func testCloseIsIdempotentAndWakesAnIdleReader() async throws {
        let fixture = try makeFixture("exec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try await fixture.service.open(containerID: "fixture", shell: "/bin/sh")
        try await fixture.service.close(sessionID: connection.sessionID)
        try await fixture.service.close(sessionID: connection.sessionID)
        var count = 0
        for try await _ in connection.stream { count += 1 }
        XCTAssertEqual(count, 0)
        let sessions = await fixture.service.activeSessionCount
        XCTAssertEqual(sessions, 0)
    }

    func testOverloadEndsExplicitlyInsteadOfDiscardingArbitraryTerminalBytes() async throws {
        let fixture = try makeFixture("/usr/bin/head -c 4194304 /dev/zero\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try await fixture.service.open(containerID: "fixture", shell: "/bin/sh")
        try await Task.sleep(for: .milliseconds(400))
        var bytes = 0
        do {
            for try await chunk in connection.stream { bytes += chunk.count }
            XCTFail("Expected an explicit bounded-buffer overload error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("delivery buffer"), "\(error)")
        }
        XCTAssertLessThanOrEqual(bytes, 1024 * 1024)
        try await waitForCleanup(fixture.service)
    }

    private func makeFixture(_ script: String) throws -> (service: TerminalService, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("micropod-pty-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (TerminalService(client: ContainerCLIClient(executableURL: executable)), directory)
    }

    private func waitForCleanup(_ service: TerminalService) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await service.activeSessionCount > 0 {
            guard ContinuousClock.now < deadline else {
                XCTFail("Terminal session survived EOF or cancellation")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
