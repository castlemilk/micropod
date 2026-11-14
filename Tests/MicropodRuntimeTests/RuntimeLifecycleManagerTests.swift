import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

private enum ManagedFixtureFailure: Error { case busy, start, verification }
private actor ManagedDriverFixture: RuntimeLifecycleDriving {
    var calls: [String] = []
    var busy = false
    var startFails = false
    var verificationFails = false
    func configure(busy: Bool = false, startFails: Bool = false, verificationFails: Bool = false) {
        self.busy = busy
        self.startFails = startFails
        self.verificationFails = verificationFails
    }
    func events() -> [String] { calls }
    func stage(root: URL) throws -> ManagedRuntimeReceipt {
        calls.append("stage")
        let release = AppleRuntimeRelease.supported
        let selection = ManagedRuntimeLocation.Selection(
            version: release.version, packageSHA256: release.packageSHA256, incarnation: UUID())
        let receipt = ManagedRuntimeReceipt(selection: selection, files: AppleRuntimeRelease.payloadSHA256)
        try RuntimeDurableFile.write(
            receipt, to: root.appendingPathComponent("versions/" + selection.directoryName + "/micropod-receipt.json"))
        return receipt
    }
    func verifyStaged(_ receipt: ManagedRuntimeReceipt, root: URL) { calls.append("verifyStaged") }
    func assertIdle(executable: URL) throws {
        calls.append("idle")
        if busy { throw ManagedFixtureFailure.busy }
    }
    func status(executable: URL) -> String {
        calls.append("status")
        return "stopped"
    }
    func stop(executable: URL) { calls.append("stop") }
    func start(executable: URL) throws {
        calls.append("start")
        if startFails { throw ManagedFixtureFailure.start }
    }
    func verify(executable: URL, installRoot: URL, stopped: Bool) throws {
        calls.append("verify")
        if verificationFails { throw ManagedFixtureFailure.verification }
    }
}
private actor ManagedRigFixture: RuntimeRigCoordinating {
    let gate: RuntimeAdmission
    var calls: [String] = []
    var gateStates: [String: Bool] = [:]
    var waits = false
    var prepared: CheckedContinuation<Void, Never>?
    var lostCompletion = false
    var foreignVerification = false
    var unavailableBeforeRequest = false
    init(root: URL) { gate = RuntimeAdmission(root: root.appendingPathComponent("admission")) }
    func waitPreparation() { waits = true }
    func releasePreparation() {
        prepared?.resume()
        prepared = nil
    }
    func loseOneCompletion() { lostCompletion = true }
    func changeVerificationOwner() { foreignVerification = true }
    func goOffline() { unavailableBeforeRequest = true }
    func events() -> [String] { calls }
    func states() -> [String: Bool] { gateStates }
    func transition(operation: UUID, action: String, installRoot: URL, localGeneration: UInt64, targetState: String)
        async throws -> RuntimeRigReceipt?
    {
        calls.append(action)
        gateStates[action] = gate.isClosed
        if unavailableBeforeRequest { throw RuntimeRigAdmissionError.unavailable("Coordinator offline before request") }
        if action == "prepare", waits { await withCheckedContinuation { prepared = $0 } }
        if action == "complete", lostCompletion {
            lostCompletion = false
            throw ManagedFixtureFailure.verification
        }
        let phase =
            [
                "prepare": "prepared", "begin": "begun", "verify": "verified", "complete": "completed",
                "abort": "aborting", "abortComplete": "cancelled",
            ][action] ?? "blocked"
        let owner = action == "verify" && foreignVerification ? "foreign-owner" : "fixture-owner"
        let json: [String: Any] = [
            "operation": operation.uuidString, "phase": phase, "hostID": "fixture-host", "owner": owner,
            "generation": 7,
        ]
        return try JSONDecoder().decode(RuntimeRigReceipt.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor
final class RuntimeLifecycleManagerTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func terminal(_ manager: RuntimeLifecycleManager) async throws -> RuntimeLifecycleOperation {
        for _ in 0..<300 {
            if let operation = await manager.status(), operation.isTerminal { return operation }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "RuntimeLifecycleTestTimeout", code: 1)
    }
    func testInstallDrainsBeforeClosingLocalIngressAndVerifiesBeforeRelease() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        let rig = ManagedRigFixture(root: root)
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.begin(.install)
        let result = try await terminal(manager)
        XCTAssertEqual(result.phase, "completed", result.error ?? "")
        let rigCalls = await rig.events()
        let gates = await rig.states()
        let calls = await driver.events()
        XCTAssertEqual(rigCalls, ["prepare", "begin", "verify", "complete"])
        XCTAssertEqual(gates["prepare"], false, "Existing jobs must still be able to call the runtime while draining")
        XCTAssertEqual(gates["begin"], true)
        XCTAssertEqual(gates["verify"], true)
        XCTAssertEqual(gates["complete"], false, "Scheduler reopens only after Micropod handoff")
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(try ManagedRuntimeLocation.selection(at: root), result.selection)
        XCTAssertFalse(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
    }
    func testBusyWorkIsNotStoppedAndBothPreparationHoldsAbort() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        await driver.configure(busy: true)
        let rig = ManagedRigFixture(root: root)
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.begin(.install)
        let result = try await terminal(manager)
        let calls = await driver.events()
        let rigCalls = await rig.events()
        XCTAssertEqual(result.phase, "blocked")
        XCTAssertFalse(calls.contains("start") || calls.contains("stop"))
        XCTAssertEqual(rigCalls, ["prepare", "abort", "abortComplete"])
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
    }
    func testLatePreparationAfterCancellationCannotBeginAnAction() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        let rig = ManagedRigFixture(root: root)
        await rig.waitPreparation()
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.begin(.install)
        for _ in 0..<100 {
            if await rig.events().contains("prepare") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await manager.cancel()
        await rig.releasePreparation()
        let result = try await terminal(manager)
        let calls = await driver.events()
        let rigCalls = await rig.events()
        XCTAssertEqual(result.phase, "cancelled")
        XCTAssertFalse(rigCalls.contains("begin"))
        XCTAssertFalse(calls.contains("start") || calls.contains("stop"))
    }
    func testFailedStartRetainsFenceAndRecoveryOnlyVerifiesWithoutReplaying() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        await driver.configure(startFails: true)
        let rig = ManagedRigFixture(root: root)
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.begin(.install)
        let failed = try await terminal(manager)
        XCTAssertEqual(failed.phase, "recoveryRequired")
        XCTAssertTrue(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
        await driver.configure()
        _ = try await manager.recover()
        let recovered = try await terminal(manager)
        let calls = await driver.events()
        XCTAssertEqual(recovered.phase, "completed", recovered.error ?? "")
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1)
    }
    func testCompetingAppProcessCannotReplaceAnActiveOperationJournal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        let rig = ManagedRigFixture(root: root)
        await rig.waitPreparation()
        let first = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        let second = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        let initial = try await first.begin(.install)
        do {
            _ = try await second.begin(.install)
            XCTFail("Second process acquired runtime management")
        } catch {}
        let persisted = try JSONDecoder().decode(
            RuntimeLifecycleOperation.self, from: Data(contentsOf: root.appendingPathComponent("operation.json")))
        XCTAssertEqual(persisted.id, initial.id)
        await first.cancel()
        for _ in 0..<100 {
            if await rig.events().contains("prepare") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await rig.releasePreparation()
        _ = try await terminal(first)
    }

    func testLostCompletionCanRecoverAcrossAppReplacementWithoutRepeatingRuntimeAction() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        let rig = ManagedRigFixture(root: root)
        await rig.loseOneCompletion()
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.begin(.install)
        let failed = try await terminal(manager)
        XCTAssertEqual(failed.phase, "recoveryRequired")
        XCTAssertEqual(failed.resumePhase, "releasing")
        let replacement = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await replacement.recover()
        let recovered = try await terminal(replacement)
        XCTAssertEqual(recovered.phase, "completed", recovered.error ?? "")
        let calls = await driver.events()
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1)
    }

    func testChangedHostOwnershipNeverReopensAdmission() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        let rig = ManagedRigFixture(root: root)
        await rig.changeVerificationOwner()
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.begin(.install)
        let result = try await terminal(manager)
        XCTAssertEqual(result.phase, "recoveryRequired")
        XCTAssertTrue(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
        let calls = await rig.events()
        XCTAssertFalse(calls.contains("complete"))
    }

    func testOfflineCoordinatorBeforeFirstRequestLeavesNoRecoveryFence() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        let rig = ManagedRigFixture(root: root)
        await rig.goOffline()
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.begin(.install)
        let result = try await terminal(manager)
        XCTAssertEqual(result.phase, "blocked")
        XCTAssertNil(result.localGeneration)
        XCTAssertFalse(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
        let calls = await driver.events()
        XCTAssertFalse(calls.contains("stop") || calls.contains("start"))
        XCTAssertNil(try ManagedRuntimeLocation.selection(at: root))
    }

    func testInterruptedStopNeverReplaysAnUncertainRuntimeAction() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ManagedDriverFixture()
        let rig = ManagedRigFixture(root: root)
        let receipt = try await driver.stage(root: root)
        let id = UUID()
        let gate = RuntimeAdmission(root: root.appendingPathComponent("admission"))
        let generation: UInt64
        do {
            let fence = try gate.begin(operation: id)
            try fence.beginAction()
            generation = fence.fence.generation
        }
        let operation = RuntimeLifecycleOperation(
            id: id, action: .install, phase: "stopping", message: "Interrupted stop", selection: receipt.selection,
            localGeneration: generation)
        try RuntimeDurableFile.write(operation, to: root.appendingPathComponent("operation.json"))
        let manager = RuntimeLifecycleManager(root: root, rig: rig, driver: driver)
        _ = try await manager.recover()
        let result = try await terminal(manager)
        XCTAssertEqual(result.phase, "recoveryRequired")
        XCTAssertTrue(gate.isClosed)
        let calls = await driver.events()
        XCTAssertFalse(calls.contains("stop") || calls.contains("start") || calls.contains("verify"))
    }
}
