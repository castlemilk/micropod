import Foundation
import XCTest

@testable import MicropodCore

@MainActor
final class SystemVersionRefreshTests: XCTestCase {
    func testSameServiceSeesInstallUpgradeRemovalAndReinstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("container")
        let trace = directory.appendingPathComponent("version-calls")
        let service = SystemService(client: ContainerCLIClient(executableURL: executable))
        func install(_ version: String) throws {
            let script = """
                #!/bin/sh
                echo call >> '\(trace.path)'
                echo '[{"appName":"container","version":"\(version)"}]'
                """
            try Data(script.utf8).write(to: executable, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        do {
            _ = try await service.cliVersion()
            XCTFail("Missing executable must fail")
        } catch {}
        try install("1.4.0")
        let first = try await service.cliVersion()
        let repeated = try await service.cliVersion()
        XCTAssertEqual(first, "1.4.0")
        XCTAssertEqual(repeated, "1.4.0")
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").count, 1)
        try install("1.5.0")
        let upgraded = try await service.cliVersion()
        XCTAssertEqual(upgraded, "1.5.0", "Same-path upgrade must invalidate a warm version cache")
        try FileManager.default.removeItem(at: executable)
        do {
            _ = try await service.cliVersion()
            XCTFail("Removal must not return the previously cached version")
        } catch {}
        try install("1.5.1")
        let reinstalled = try await service.cliVersion()
        XCTAssertEqual(reinstalled, "1.5.1")
    }

    func testEmptyExitOneIsNotEvidenceThatRuntimeIsStopped() async {
        let service = SystemService(client: ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false")))
        do {
            _ = try await service.status()
            XCTFail("An empty exit-1 response cannot authorize automatic startup")
        } catch {}
    }
}
