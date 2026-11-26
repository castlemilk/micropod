import Darwin
import Foundation
import MicropodCore
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

    // MARK: - Rootless admission

    private typealias Evidence = ManagedUpdateAdmission.RootManagedRuntimeEvidence

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            _ = chmod(dir.appendingPathComponent("sealed").path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func rootlessReceipt() throws -> UpdateContinuityReceipt {
        UpdateContinuityReceipt(
            operation: UUID(), owner: try XCTUnwrap(RuntimeProcessBirth.read(getpid())), sourceVersion: "0.14.0",
            sourceExecutableSHA256: String(repeating: "a", count: 64), sourceAppPath: "/Applications/Micropod.app",
            targetVersion: "0.14.1", targetSourceRevision: String(repeating: "b", count: 40),
            artifactURL: "https://github.com/castlemilk/micropod/releases/download/v0.14.1/Micropod.dmg",
            artifactSignature: Data(repeating: 0, count: 64).base64EncodedString(), artifactBytes: 100,
            runtimeInstance: ManagedUpdateAdmission.rootlessRuntimeInstance, apiConfigurationSHA256: "", services: [])
    }

    /// The receipt as stored, with `change` applied to its JSON.
    private func altered(
        _ receipt: UpdateContinuityReceipt, _ change: (inout [String: Any]) -> Void
    ) throws -> UpdateContinuityReceipt {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        change(&object)
        return try JSONDecoder().decode(
            UpdateContinuityReceipt.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Absence must be observed: no identity, no authority LaunchDaemon and
    /// no root helper. Anything present, or anything that cannot be read, is
    /// not absence.
    func testRootManagedRuntimeAbsenceNeedsPositiveEvidence() throws {
        let dir = try scratch()
        let identity = dir.appendingPathComponent("identity.json")
        let authority = dir.appendingPathComponent("com.skunkworq.micropod.runtime.authority.plist")
        func evidence(helper: () throws -> Bool = { false }) -> Evidence {
            ManagedUpdateAdmission.rootManagedRuntimeEvidence(
                identity: identity, authority: authority, helperIsRunning: helper)
        }
        XCTAssertEqual(evidence(), .absent)
        XCTAssertEqual(
            ManagedUpdateAdmission.rootManagedRuntimeInstallation(identity: identity, authority: authority), .absent)

        try Data("{}".utf8).write(to: identity)
        XCTAssertEqual(evidence(), .present("the runtime identity \(identity.path) exists"))
        try FileManager.default.removeItem(at: identity)
        try FileManager.default.createSymbolicLink(atPath: identity.path, withDestinationPath: "/nonexistent")
        guard case .present = evidence() else { return XCTFail("a dangling identity link is still an identity") }
        try FileManager.default.removeItem(at: identity)

        try Data().write(to: authority)
        guard case .present = evidence() else { return XCTFail("an installed authority is a root-managed runtime") }
        try FileManager.default.removeItem(at: authority)

        XCTAssertEqual(evidence(helper: { true }), .present("a root MicropodRuntimeHost is running"))
        guard case .indeterminate = evidence(helper: { throw MicropodError.message("no process table") }) else {
            return XCTFail("an unreadable process table is not absence")
        }

        let sealed = dir.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(sealed.path, 0), 0)
        let unreadable = ManagedUpdateAdmission.rootManagedRuntimeEvidence(
            identity: sealed.appendingPathComponent("identity.json"), authority: authority, helperIsRunning: { false })
        guard case .indeterminate = unreadable else {
            return XCTFail("an unreadable identity location is not absence: \(unreadable)")
        }
        // This process can read its own process table, so the scan answers.
        XCTAssertNoThrow(try ManagedUpdateAdmission.rootHelperIsRunning())
    }

    /// Before, a user-writable default runtime of hvf or sandbox selected the
    /// rootless branch on its own, skipping the service witness, the runtime
    /// probe and the workload-protocol check even with a root-managed runtime
    /// installed.
    func testTheDefaultRuntimeAloneNeverSelectsRootlessAdmission() {
        for evidence: Evidence in [.present("the runtime identity exists"), .indeterminate("cannot inspect")] {
            for runtime in ["hvf", "sandbox"] {
                XCTAssertThrowsError(
                    try ManagedUpdateAdmission.requireRootlessAdmission(
                        defaultRuntime: runtime, declaresWorkloadProtocol: true, evidence: evidence),
                    "\(runtime) with \(evidence)")
            }
        }
        XCTAssertThrowsError(
            try ManagedUpdateAdmission.requireRootlessAdmission(
                defaultRuntime: "hvf", declaresWorkloadProtocol: false, evidence: .absent),
            "the workload protocol is still required")
        for runtime in ["apple", "docker", "ci", ""] {
            XCTAssertThrowsError(
                try ManagedUpdateAdmission.requireRootlessAdmission(
                    defaultRuntime: runtime, declaresWorkloadProtocol: true, evidence: .absent), runtime)
        }
        for runtime in ["hvf", "sandbox"] {
            XCTAssertNoThrow(
                try ManagedUpdateAdmission.requireRootlessAdmission(
                    defaultRuntime: runtime, declaresWorkloadProtocol: true, evidence: .absent))
        }
    }

    /// Installing, or settling an installation, rechecks what the rootless
    /// admission rested on: a root-managed runtime that appeared meanwhile,
    /// or a replacement without the workload protocol, stops it.
    func testARootlessInstallationRechecksAbsenceAndTheWorkloadProtocol() throws {
        let receipt = try rootlessReceipt()
        XCTAssertNoThrow(
            try ManagedUpdateAdmission.verifyContinuity(receipt, declaresWorkloadProtocol: true, evidence: .absent))
        for evidence: Evidence in [.present("a root MicropodRuntimeHost is running"), .indeterminate("unreadable")] {
            XCTAssertThrowsError(
                try ManagedUpdateAdmission.verifyContinuity(receipt, declaresWorkloadProtocol: true, evidence: evidence)
            ) { XCTAssertTrue("\($0)".contains("did not witness"), "\($0)") }
        }
        XCTAssertThrowsError(
            try ManagedUpdateAdmission.verifyContinuity(receipt, declaresWorkloadProtocol: false, evidence: .absent)
        ) { XCTAssertTrue("\($0)".contains("workload protocol"), "\($0)") }
    }

    /// Before, every rootless receipt went through `verifyServices`, which
    /// needs the root-managed identity: a rootless update could not begin,
    /// abort, settle a rejected download or reopen the desktop.
    func testARootlessReceiptReopensWithoutAManagedRuntimeToWitness() throws {
        let receipt = try rootlessReceipt()
        XCTAssertThrowsError(try receipt.verifyServices())
        XCTAssertNoThrow(try ManagedUpdateAdmission.verifyRetained(receipt))
    }

    func testARootlessReceiptCannotCarryManagedServices() throws {
        let receipt = try rootlessReceipt()
        let birth = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt.owner)) as? [String: Any])
        let witness: [String: Any] = [
            "name": "api-server", "executable": "/Applications/Micropod.app/Contents/MacOS/MicropodAPI",
            "identifier": "com.skunkworq.micropod.api", "team": "WFTX6CN23F",
            "sha256": String(repeating: "c", count: 64), "birth": birth,
        ]
        for forged in [
            try altered(receipt) { $0["services"] = [witness] },
            try altered(receipt) { $0["apiConfigurationSHA256"] = String(repeating: "d", count: 64) },
        ] {
            XCTAssertThrowsError(try ManagedUpdateAdmission.verifyRetained(forged))
            XCTAssertThrowsError(
                try ManagedUpdateAdmission.verifyContinuity(forged, declaresWorkloadProtocol: true, evidence: .absent))
        }
    }

    /// Only the sentinel instance is rootless: every other receipt keeps the
    /// managed service witness, whatever the root-managed evidence says.
    func testAManagedReceiptKeepsItsServiceWitness() throws {
        let managed = try altered(try rootlessReceipt()) { $0["runtimeInstance"] = UUID().uuidString }
        XCTAssertThrowsError(try ManagedUpdateAdmission.verifyRetained(managed))
        XCTAssertThrowsError(
            try ManagedUpdateAdmission.verifyContinuity(managed, declaresWorkloadProtocol: true, evidence: .absent))
    }
}
