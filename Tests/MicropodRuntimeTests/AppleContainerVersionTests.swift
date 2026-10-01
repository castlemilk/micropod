import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Which Apple `container` releases the native backend runs against in auto
/// mode, and the version strings it reads them from: the 1.3.x banner and
/// the bare release 1.4.0 onwards report.
final class AppleContainerVersionTests: XCTestCase {
    private static let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))

    private func health(_ version: String) -> APIServerHealth {
        APIServerHealth(
            apiServerVersion: version, apiServerCommit: "", apiServerBuild: "release",
            apiServerAppName: "container-apiserver", appRoot: nil, installRoot: nil, logRoot: nil)
    }

    private func services(_ health: APIServerHealth?) -> RuntimeServices {
        RuntimeServices(
            kind: .native,
            containers: ContainerService(client: Self.client),
            logs: LogStreamer(client: Self.client),
            stats: StatsSampler(client: Self.client),
            volumes: VolumeService(client: Self.client),
            api: nil, health: health, exitCodes: nil)
    }

    func testSemverReadsTheBannerAndTheBareRelease() {
        XCTAssertEqual(health("container-apiserver version 1.3.1 (build: release, commit: a9a62e2)").semver, "1.3.1")
        XCTAssertEqual(health("container-apiserver version 1.2.2 (build: release, commit: 0190097)").semver, "1.2.2")
        // 1.4.0 onwards: `ReleaseVersion.version()`, no banner.
        XCTAssertEqual(health("1.5.0").semver, "1.5.0")
        XCTAssertEqual(health("1.4.1").semver, "1.4.1")
        // A development build without a bundle version.
        XCTAssertEqual(health("0.0.0").semver, "0.0.0")
        XCTAssertNil(health("unspecified").semver)
        XCTAssertNil(health("").semver)
    }

    func testVerifiedReleaseLines() {
        for version in ["1.3.0", "1.3.1", "1.4.0", "1.4.1", "1.5.0", "1.5.12"] {
            XCTAssertTrue(RuntimeServices.isVerified(semver: version), version)
        }
        // Older, newer and look-alike lines stay on the CLI in auto mode.
        for version in ["1.2.2", "1.6.0", "2.0.0", "1.30.0", "1.50.0", "0.0.0", "11.3.0"] {
            XCTAssertFalse(RuntimeServices.isVerified(semver: version), version)
        }
    }

    func testVersionSupportedFollowsTheHandshake() {
        let banner131 = "container-apiserver version 1.3.1 (build: release, commit: a9a62e2)"
        let banner122 = "container-apiserver version 1.2.2 (build: release, commit: 0190097)"
        XCTAssertTrue(services(health(banner131)).versionSupported)
        XCTAssertTrue(services(health("1.5.0")).versionSupported)
        XCTAssertTrue(services(health("1.4.1")).versionSupported)
        XCTAssertFalse(services(health("1.6.0")).versionSupported)
        XCTAssertFalse(services(health(banner122)).versionSupported)
        XCTAssertFalse(services(health("unspecified")).versionSupported)
        XCTAssertFalse(services(nil).versionSupported)
    }

    /// The route enum mirrors upstream's: 1.4.0 added `containerClean` and
    /// changed no existing raw value.
    func testRouteRawValuesAreTheWireNames() {
        XCTAssertEqual(XPCRoute.containerClean.rawValue, "containerClean")
        XCTAssertEqual(XPCRoute.containerList.rawValue, "containerList")
        XCTAssertEqual(XPCRoute.volumeInspect.rawValue, "volumeInspect")
        XCTAssertEqual(XPCRoute.ping.rawValue, "ping")
        XCTAssertEqual(XPCKeys.apiServerVersion.rawValue, "apiServerVersion")
    }
}
