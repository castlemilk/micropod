import Foundation
import XCTest

@testable import MicropodApp

@MainActor
final class ManagedUpdateAdmissionTests: XCTestCase {
    func testPersistentServicesPinTheirContextAndCannotInheritDesktopDeathWatch() {
        let spec = AgentSpec(
            id: "test", displayName: "test", binaryName: "test", probe: .custom { true },
            enabledDefaultsKey: "test", endpoint: "test")
        let parent = [
            "MICROPOD_PARENT_PID": "123", "UNRELATED_SECRET": "must-not-inherit", "MICROPOD_API_PORT": "45555",
        ]
        let existing = PersistentDesktopAgents.serviceEnvironment(spec: spec, parent: parent, legacyAvailable: true)
        XCTAssertEqual(existing["MICROPOD_RUNTIME_CONTEXT"], "existing")
        XCTAssertEqual(existing["MICROPOD_PARENT_PID"], "")
        XCTAssertNil(existing["UNRELATED_SECRET"])
        XCTAssertEqual(existing["MICROPOD_API_PORT"], "45555")
        let fresh = PersistentDesktopAgents.serviceEnvironment(spec: spec, parent: parent, legacyAvailable: false)
        XCTAssertEqual(fresh["MICROPOD_RUNTIME_CONTEXT"], "managed")
        let explicit = PersistentDesktopAgents.serviceEnvironment(
            spec: spec,
            parent: ["MICROPOD_RUNTIME_CONTEXT": "existing"], legacyAvailable: false)
        XCTAssertEqual(explicit["MICROPOD_RUNTIME_CONTEXT"], "existing")
    }
    func testCandidateBindsOneOfficialVersionedArtifactWithoutCredentialsOrOverrides() {
        let trusted = "https://github.com/castlemilk/micropod/releases/download/v0.13.1/Micropod.dmg"
        func candidate(
            _ url: String, signature: String = Data(repeating: 0, count: 64).base64EncodedString(),
            source: String = String(repeating: "a", count: 40)
        ) -> ManagedUpdateAdmission.Candidate {
            .init(version: "0.13.1", url: URL(string: url)!, signature: signature, bytes: 100, source: source)
        }
        XCTAssertTrue(candidate(trusted).isCompatible)
        for url in [
            trusted.replacingOccurrences(of: "https:", with: "http:"),
            trusted.replacingOccurrences(of: "github.com", with: "other.example"),
            trusted.replacingOccurrences(of: "v0.13.1", with: "v0.13.2"),
            trusted.replacingOccurrences(of: "Micropod.dmg", with: "setup.pkg"),
            trusted.replacingOccurrences(of: "github.com", with: "user@github.com"), trusted + "?alternate=1",
            trusted + "#fragment",
        ] {
            XCTAssertFalse(candidate(url).isCompatible, url)
        }
        XCTAssertFalse(candidate(trusted, signature: "missing").isCompatible)
        XCTAssertFalse(candidate(trusted, source: "master").isCompatible)
    }
}
