import Foundation
import XCTest

@testable import MicropodCore

final class RuntimeDependencyStatusTests: XCTestCase {
    func testReadinessRequiresNativeEvidenceAndQualifiedVersion() throws {
        let running = Micropod_V1_SystemStatus.with {
            $0.status = "running"
            $0.cliVersion = "1.5.0"
        }
        let cases: [(RuntimeDependencyStatus.NativeReadiness, RuntimeDependencyStatus.State)] = [
            (.unobserved, .cliFallback), (.unavailable, .apiUnavailable),
            (.unsupported(version: "1.6.0"), .unsupportedVersion),
            (.ready(version: "1.5.0"), .nativeReady),
        ]
        for (native, expected) in cases {
            let report = RuntimeDependencyStatus(
                cliAvailable: true, cliPath: "/custom/container", status: running,
                native: native, hostSupported: true)
            XCTAssertEqual(report.state, expected)
            XCTAssertEqual(
                try JSONDecoder().decode(RuntimeDependencyStatus.self, from: JSONEncoder().encode(report)), report)
            XCTAssertTrue(report.installerURL.hasPrefix("https://github.com/apple/container/releases/tag/"))
        }
    }

    func testMissingStoppedStartingDegradedAndUnsupportedHostStayDistinct() {
        let stopped = Micropod_V1_SystemStatus.with { $0.status = "stopped" }
        let missing = RuntimeDependencyStatus(
            cliAvailable: false, cliPath: "/custom/missing", status: nil, hostSupported: true)
        XCTAssertEqual(missing.state, .missingCLI)
        XCTAssertEqual(
            RuntimeDependencyStatus(
                cliAvailable: true, cliPath: "", status: stopped, hostSupported: true
            ).state, .stopped)
        XCTAssertEqual(
            RuntimeDependencyStatus(
                cliAvailable: true, cliPath: "", status: stopped, starting: true, hostSupported: true
            ).state, .starting)
        XCTAssertEqual(
            RuntimeDependencyStatus(
                cliAvailable: true, cliPath: "", status: stopped, stopping: true, hostSupported: true
            ).state, .stopping)
        XCTAssertEqual(
            RuntimeDependencyStatus(
                cliAvailable: true, cliPath: "", status: stopped, statusFailed: true, hostSupported: true
            ).state, .degraded)
        XCTAssertEqual(
            RuntimeDependencyStatus(
                cliAvailable: false, cliPath: "", status: nil, hostSupported: false
            ).state, .unsupportedHost)
    }
}
