import Foundation
import XCTest

final class ApplePayloadSecretScanTests: XCTestCase {
    func testHistoricalChecksumExceptionStillRejectsNewCredentialsAtSameLocation() throws {
        let executable = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("gitleaks").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { throw XCTSkip("Real secret scanner is not installed") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let ignore = repo.appendingPathComponent(".gitleaksignore").path
        let original = "88bda58c903de60681c91dbbfc92403a4ee8094c"
        if try run("/usr/bin/git", ["cat-file", "-e", original + "^{commit}"], in: repo) == 0 {
            XCTAssertEqual(
                try run(
                    executable,
                    [
                        "git", "--log-opts=" + original + "^.." + original,
                        "--gitleaks-ignore-path", ignore, "--redact", "--no-banner",
                    ], in: repo), 0)
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let relative = "Sources/MicropodCore/RuntimeManagement/AppleRuntimePayload.swift"
        let payload = fixture.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        let synthetic = "mP4k" + Data((0..<64).map { UInt8(($0 * 37 + 11) % 256) }).base64EncodedString()
        try (String(repeating: "// scanner fixture\n", count: 7) + "let api_key = \"" + synthetic + "\"\n")
            .write(to: payload, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run("/usr/bin/git", ["init", "--quiet"], in: fixture), 0)
        XCTAssertEqual(try run("/usr/bin/git", ["add", "."], in: fixture), 0)
        XCTAssertEqual(
            try run(
                "/usr/bin/git",
                [
                    "-c", "user.name=Scanner Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "synthetic scanner fixture",
                ], in: fixture), 0)
        let report = fixture.appendingPathComponent("report.json")
        XCTAssertEqual(
            try run(
                executable,
                [
                    "git", "--gitleaks-ignore-path", ignore, "--redact", "--no-banner",
                    "--report-format", "json", "--report-path", report.path,
                ], in: fixture), 1)
        let findings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [[String: Any]])
        XCTAssertTrue(
            findings.contains { finding in
                (finding["File"] as? String) == relative && (finding["StartLine"] as? Int) == 8
                    && (finding["RuleID"] as? String) == "generic-api-key" && (finding["Commit"] as? String) != original
            }, "A new credential at the historical checksum's location must remain reportable")
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
