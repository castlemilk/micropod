import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

/// The app and the rig upgrade now share the retained-service record and
/// launch agent definition. The app's side must read and write exactly what
/// it did before the extraction, so Sparkle desktops see no change.
final class RetainedServiceRecordTests: XCTestCase {
    /// A record as 0.13.x writes it (field order and escaping as on disk).
    private let onDisk = #"""
        {"sourceVersion":"0.13.0","arguments":[],"environment":{"MICROPOD_RUNTIME_CONTEXT":"existing","MICROPOD_PARENT_PID":""},"executable":"\/Users\/me\/.micropod\/services\/payloads\/0.13.0-0ea9\/Micropod.app\/Contents\/MacOS\/micropod-docker-shim","sha256":"d8fc","schema":1,"identifier":"com.skunkworq.micropod.docker-shim"}
        """#

    func testExistingRecordsDecodeAndKeepTheirKeys() throws {
        let record = try JSONDecoder().decode(PersistentDesktopAgents.Record.self, from: Data(onDisk.utf8))
        XCTAssertEqual(record.schema, 1)
        XCTAssertEqual(record.identifier, "com.skunkworq.micropod.docker-shim")
        XCTAssertEqual(record.environment["MICROPOD_RUNTIME_CONTEXT"], "existing")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        let original = try JSONSerialization.jsonObject(with: Data(onDisk.utf8)) as? [String: Any]
        XCTAssertEqual(Set(encoded?.keys ?? [:].keys), Set(original?.keys ?? [:].keys))
    }

    func testLaunchAgentDefinitionIsWhatTheAppRegistered() throws {
        let record = try JSONDecoder().decode(PersistentDesktopAgents.Record.self, from: Data(onDisk.utf8))
        let root = URL(fileURLWithPath: "/Users/me/.micropod/services")
        let configuration = RetainedServiceLaunchAgent.configuration("docker-shim", record: record, servicesRoot: root)
        XCTAssertEqual(
            Set(configuration.keys),
            [
                "Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ThrottleInterval", "EnvironmentVariables",
                "StandardOutPath", "StandardErrorPath", "ProcessType", "Umask",
            ])
        XCTAssertEqual(configuration["Label"] as? String, "com.skunkworq.micropod.service.docker-shim")
        XCTAssertEqual(configuration["ProgramArguments"] as? [String], [record.executable])
        XCTAssertEqual(configuration["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(configuration["KeepAlive"] as? Bool, true)
        XCTAssertEqual(configuration["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(configuration["EnvironmentVariables"] as? [String: String], record.environment)
        XCTAssertEqual(configuration["StandardOutPath"] as? String, "/Users/me/.micropod/services/docker-shim.log")
        XCTAssertEqual(configuration["StandardErrorPath"] as? String, "/Users/me/.micropod/services/docker-shim.log")
        XCTAssertEqual(configuration["ProcessType"] as? String, "Background")
        XCTAssertEqual(configuration["Umask"] as? Int, 0o077)
    }

    func testAgentSpecsUseTheSharedDefinitions() {
        let specs = AgentSupervisor.micropodSpecs(enabled: { _ in false }, onStatus: { _ in }).specsForUI
        for spec in specs {
            XCTAssertEqual(spec.arguments, RetainedServiceLaunchAgent.definition(spec.id).arguments)
            XCTAssertEqual(spec.environment, RetainedServiceLaunchAgent.definition(spec.id).environment)
        }
        XCTAssertEqual(specs.map(\.id).sorted(), RetainedServiceLaunchAgent.ids.sorted())
    }

    func testServiceIdentityIsUnchanged() {
        let identifiers = ["docker-shim", "api-server", "shared-fs"].map { id in
            PersistentDesktopAgents.identifier(
                AgentSpec(
                    id: id, displayName: id, binaryName: id, probe: .custom({ true }), enabledDefaultsKey: id,
                    endpoint: id))
        }
        XCTAssertEqual(
            identifiers,
            ["com.skunkworq.micropod.docker-shim", "com.skunkworq.micropod.api", "com.skunkworq.micropod.sharedfs"])
    }

    func testMovingARecordTakesTheNewReleasesDefinition() throws {
        let record = RetainedServiceRecord(
            schema: 1, sourceVersion: "0.13.0", executable: "/p/0.13.0-x/Micropod.app/Contents/MacOS/micropod-sharedfs",
            identifier: "com.skunkworq.micropod.sharedfs", sha256: "old", arguments: ["--flag"],
            environment: [
                "MICROPOD_GUEST_TOOL": "/p/0.13.0-x/Micropod.app/Contents/Resources/micropod-guest",
                "PATH": "/usr/bin", "OTHER": "/p/0.13.0-x/Micropod.application",
            ])
        let moved = record.moved(
            to: URL(fileURLWithPath: "/p/0.14.1-y/Micropod.app"), sourceVersion: "0.14.1", sha256: "new",
            definition: RetainedServiceDefinition(arguments: ["--serve"], environment: ["MICROPOD_NEW": "1"]))
        XCTAssertEqual(moved.executable, "/p/0.14.1-y/Micropod.app/Contents/MacOS/micropod-sharedfs")
        XCTAssertEqual(
            moved.environment["MICROPOD_GUEST_TOOL"], "/p/0.14.1-y/Micropod.app/Contents/Resources/micropod-guest")
        XCTAssertEqual(moved.environment["PATH"], "/usr/bin")
        XCTAssertEqual(moved.environment["OTHER"], "/p/0.13.0-x/Micropod.application")
        XCTAssertEqual(moved.environment["MICROPOD_NEW"], "1")
        XCTAssertEqual(moved.arguments, ["--serve"], "arguments come from the new release")
        XCTAssertEqual(moved.identifier, record.identifier)
        XCTAssertEqual(moved.sha256, "new")
        XCTAssertEqual(moved.sourceVersion, "0.14.1")
    }
}
