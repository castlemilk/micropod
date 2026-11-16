import Foundation
import XCTest

@testable import MicropodCore

final class UpdateContinuityTests: XCTestCase {
    func testInstalledDedicatedServiceWitnessesReadOnly() throws {
        guard ProcessInfo.processInfo.environment["MICROPOD_REAL_UPDATE_WITNESS"] == "1" else {
            throw XCTSkip("opt in on an approved dedicated-runtime host; reads identity only")
        }
        let identity = try IsolatedRuntimeIdentity.readRootOwned()
        let configuration = try IsolatedRuntimeAPIConfiguration.read(identity: identity)
        let helpers = try UpdateServiceWitness.processIDs(executableName: "MicropodRuntimeHost").filter {
            try RuntimeProcessBirth.read($0)?.uid == 0 && UpdateServiceWitness.parentPID($0) == 1
        }
        XCTAssertEqual(helpers.count, 1)
        let helper = try XCTUnwrap(helpers.first)
        let apiPath = IsolatedRuntimePolicy.root.appendingPathComponent(
            "tools/" + configuration.toolDirectoryName + "/MicropodAPI"
        ).path
        let enginePath = IsolatedRuntimePolicy.root.appendingPathComponent(
            "apple/versions/" + configuration.selection.directoryName + "/bin/container-apiserver"
        ).path
        let apis = UpdateServiceWitness.processIDs(executable: apiPath)
        let engines = UpdateServiceWitness.processIDs(executable: enginePath)
        XCTAssertEqual(apis.count, 1)
        XCTAssertEqual(engines.count, 1)
        let api = try XCTUnwrap(apis.first)
        let engine = try XCTUnwrap(engines.first)
        let services = [
            try UpdateServiceWitness.capture(
                name: "runtime-setup-helper", pid: helper,
                identifier: IsolatedRuntimePolicy.helperIdentifier),
            try UpdateServiceWitness.capture(
                name: "dedicated-api", pid: api,
                identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier),
            try UpdateServiceWitness.capture(
                name: "dedicated-apple-engine", pid: engine,
                identifier: "com.apple.container.apiserver", team: AppleRuntimeRelease.supported.teamIdentifier),
        ]
        let owner = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        let receipt = UpdateContinuityReceipt(
            operation: UUID(), owner: owner,
            sourceVersion: "0.13.0", sourceExecutableSHA256: String(repeating: "a", count: 64),
            sourceAppPath: "/Applications/Micropod.app", targetVersion: "0.13.4",
            targetSourceRevision: String(repeating: "a", count: 40),
            artifactURL: "https://github.com/castlemilk/micropod/releases/download/v0.13.4/Micropod.dmg",
            artifactSignature: Data(repeating: 0, count: 64).base64EncodedString(), artifactBytes: 1,
            runtimeInstance: identity.instance,
            apiConfigurationSHA256: try UpdateServiceWitness.digest(IsolatedRuntimeAPIConfiguration.fileURL),
            services: services)
        try receipt.verifyServices()
    }

    func testKernelParentIdentityIncludesOtherUsersAndRejectsMissingProcesses() throws {
        // launchd belongs to root, so this catches the cross-uid restriction
        // that same-user subprocess fixtures cannot exercise.
        XCTAssertEqual(try RuntimeProcessBirth.read(1)?.uid, 0)
        XCTAssertEqual(UpdateServiceWitness.parentPID(1), 0)
        XCTAssertEqual(UpdateServiceWitness.parentPID(getpid()), getppid())
        XCTAssertNil(UpdateServiceWitness.parentPID(0))
        XCTAssertNil(UpdateServiceWitness.parentPID(Int32.max))
    }
    func testDesktopGateCannotCloseAcrossAnActiveOperationAndFencesLateCalls() throws {
        let gate = DesktopActivity()
        XCTAssertNil(try gate.claim())  // Other processes do not opt in.
        gate.enable()
        var active = try gate.claim()
        XCTAssertFalse(gate.closeIfIdle())
        XCTAssertNotNil(active)
        active = nil
        XCTAssertTrue(gate.closeIfIdle())
        XCTAssertThrowsError(try gate.claim())
        XCTAssertFalse(gate.closeIfIdle())
        gate.reopen()
        XCTAssertNotNil(try gate.claim())
    }

    func testConcurrentAdmissionAndClosureHaveOneWinner() {
        for _ in 0..<100 {
            let gate = DesktopActivity()
            gate.enable()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                if let claim = try? gate.claim() { withExtendedLifetime(claim) {} }
                group.leave()
            }
            _ = gate.closeIfIdle()
            group.wait()
            if gate.isClosed { XCTAssertThrowsError(try gate.claim()) }
        }
    }

    func testDurableBeginCannotBeRepeatedOrAbortedAfterHandoff() throws {
        let (store, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepare(initial)
        XCTAssertTrue(store.requiresRecovery)
        _ = try store.transition(
            operation: initial.operation, generation: initial.generation, from: .prepared, to: .downloading)
        XCTAssertThrowsError(
            try store.transition(
                operation: initial.operation, generation: initial.generation, from: .prepared, to: .downloading))
        XCTAssertThrowsError(
            try store.transition(
                operation: initial.operation, generation: initial.generation, from: .prepared, to: .aborted))
        XCTAssertEqual(try UpdateContinuityStore(root: store.root).read()?.phase, .downloading)
        XCTAssertThrowsError(try store.prepare(initial))
    }

    func testLostAcknowledgementAndStaleGenerationRetainTheOriginalOwner() throws {
        let (store, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepare(initial)
        _ = try store.transition(
            operation: initial.operation, generation: initial.generation, from: .prepared, to: .downloading)
        _ = try store.transition(
            operation: initial.operation, generation: initial.generation, from: .downloading, to: .installing)
        XCTAssertThrowsError(
            try store.transition(operation: initial.operation, generation: UUID(), from: .installing, to: .succeeded))
        XCTAssertEqual(try store.read()?.owner, initial.owner)
        XCTAssertEqual(try store.read()?.phase, .installing)
        XCTAssertTrue(store.requiresRecovery)
    }

    func testCorruptOrUnsupportedJournalFailsClosed() throws {
        let (store, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepare(initial)
        try Data("{\"schema\":99}".utf8).write(to: store.receiptURL)
        XCTAssertThrowsError(try store.read())
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertThrowsError(try store.prepare(initial))
    }

    func testServiceRolesRejectMissingForgedAndAppOwnedServices() throws {
        let (_, base) = try fixture()
        let identity = IsolatedRuntimeIdentity(
            instance: base.runtimeInstance, ownerUID: base.owner.uid,
            serviceUID: 400, serviceGID: 401, accountGUID: UUID(), groupGUID: UUID())
        let configuration = IsolatedRuntimeAPIConfiguration(
            instance: identity.instance,
            selection: .init(
                version: AppleRuntimeRelease.supported.version,
                packageSHA256: AppleRuntimeRelease.supported.packageSHA256),
            executableSHA256: String(repeating: "d", count: 64))
        func witness(
            _ name: String, _ path: String, _ identifier: String, _ uid: UInt32,
            team: String = IsolatedRuntimePolicy.teamIdentifier
        ) -> UpdateServiceWitness {
            .init(
                name: name, executable: path, identifier: identifier, team: team,
                sha256: configuration.executableSHA256,
                birth: .init(pid: 123, uid: uid, seconds: 1, microseconds: 0, bootSession: base.owner.bootSession),
                endpoint: nil)
        }
        let helper = witness(
            "runtime-setup-helper", "/Applications/Micropod Runtime Setup.app/Contents/MacOS/MicropodRuntimeHost",
            IsolatedRuntimePolicy.helperIdentifier, 0)
        let api = witness(
            "dedicated-api",
            IsolatedRuntimePolicy.root.appendingPathComponent(
                "tools/" + configuration.toolDirectoryName + "/MicropodAPI"
            ).path,
            IsolatedRuntimeAPIConfiguration.executableIdentifier, 400)
        let engine = witness(
            "dedicated-apple-engine",
            IsolatedRuntimePolicy.root.appendingPathComponent(
                "apple/versions/" + configuration.selection.directoryName + "/bin/container-apiserver"
            ).path,
            "com.apple.container.apiserver", 400, team: AppleRuntimeRelease.supported.teamIdentifier)
        func receipt(_ services: [UpdateServiceWitness]) throws -> UpdateContinuityReceipt {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            object["services"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(services))
            return try JSONDecoder().decode(
                UpdateContinuityReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertNoThrow(
            try receipt([helper, api, engine]).verifyRoles(identity: identity, configuration: configuration))
        XCTAssertThrowsError(try receipt([api, engine]).verifyRoles(identity: identity, configuration: configuration))
        XCTAssertThrowsError(
            try receipt([helper, helper, api, engine]).verifyRoles(identity: identity, configuration: configuration))
        let appHelper = witness(
            helper.name, base.sourceAppPath + "/Contents/MacOS/MicropodRuntimeHost", helper.identifier, 0)
        XCTAssertThrowsError(
            try receipt([appHelper, api, engine]).verifyRoles(identity: identity, configuration: configuration))
        let wrongTeam = witness(engine.name, engine.executable, engine.identifier, 400, team: "untrusted")
        XCTAssertThrowsError(
            try receipt([helper, api, wrongTeam]).verifyRoles(identity: identity, configuration: configuration))
    }

    private func fixture() throws -> (UpdateContinuityStore, UpdateContinuityReceipt) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-update-" + UUID().uuidString)
        let birth = try XCTUnwrap(RuntimeProcessBirth.read(ProcessInfo.processInfo.processIdentifier))
        return (
            UpdateContinuityStore(root: root),
            UpdateContinuityReceipt(
                operation: UUID(), owner: birth,
                sourceVersion: "0.13.0", sourceExecutableSHA256: String(repeating: "a", count: 64),
                sourceAppPath: "/Applications/Micropod.app",
                targetVersion: "0.13.1", targetSourceRevision: String(repeating: "c", count: 40),
                artifactURL: "https://github.com/castlemilk/micropod/releases/download/v0.13.1/Micropod.dmg",
                artifactSignature: Data(repeating: 0, count: 64).base64EncodedString(), artifactBytes: 100,
                runtimeInstance: UUID(), apiConfigurationSHA256: String(repeating: "b", count: 64), services: [])
        )
    }
}
