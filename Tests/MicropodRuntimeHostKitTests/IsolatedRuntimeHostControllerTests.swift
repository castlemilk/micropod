import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntimeHostKit

private actor HostDriverFixture: IsolatedRuntimeHostDriving {
    var events: [IsolatedRuntimeAction] = []
    var ready = false
    var failAfterStart = false
    var busy = false
    var prepares = 0
    var rigEvents: [String] = []
    var loseCompletion = false
    var rigCompleted = false
    var pauseNextVerification = false
    var paused: CheckedContinuation<Void, Never>?
    var pauseWaiter: CheckedContinuation<Void, Never>?
    func pauseOneVerification() { pauseNextVerification = true }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resumeVerification() {
        paused?.resume()
        paused = nil
    }
    func rigHistory() -> [String] { rigEvents }
    func loseOneRigCompletion() { loseCompletion = true }
    func rigTransition(
        identity: IsolatedRuntimeIdentity, operation: UUID, action: String, installRoot: URL,
        generation: UInt64, targetState: String
    ) async throws -> RuntimeRigReceipt? {
        rigEvents.append(action)
        if action == "complete" {
            rigCompleted = true
            if loseCompletion {
                loseCompletion = false
                throw CocoaError(.fileReadUnknown)
            }
        }
        let phase =
            rigCompleted
            ? "completed"
            : [
                "drain": "drained", "prepare": "prepared", "begin": "begun",
                "verify": "verified", "abort": "aborting", "abortComplete": "cancelled",
            ][action] ?? "blocked"
        return .init(operation: operation, phase: phase, hostID: "host-a", owner: "owner", generation: 7, reason: nil)
    }
    func prepare(ownerUID: UInt32) throws -> PreparedIsolatedRuntime {
        prepares += 1
        let identity = try ServiceAccountPlan.allocate(ownerUID: ownerUID, occupiedUIDs: [], occupiedGIDs: [])
        return .init(
            identity: identity,
            receipt: .init(
                selection: .init(
                    version: AppleRuntimeRelease.supported.version,
                    packageSHA256: AppleRuntimeRelease.supported.packageSHA256, incarnation: UUID()),
                files: AppleRuntimeRelease.payloadSHA256), workerSHA256: String(repeating: "a", count: 64))
    }
    func failOneStart() { failAfterStart = true }
    func setBusy(_ value: Bool) { busy = value }
    func setReady(_ value: Bool) { ready = value }
    func actions() -> [IsolatedRuntimeAction] { events }
    func preparationCount() -> Int { prepares }
    func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void
    ) async throws -> IsolatedRuntimeObservation {
        events.append(request.action)
        if request.requiresIdle && busy { throw CocoaError(.fileWriteNoPermission) }
        if request.action == .verify, pauseNextVerification {
            pauseNextVerification = false
            await withCheckedContinuation {
                paused = $0
                pauseWaiter?.resume()
                pauseWaiter = nil
            }
        }
        if request.action == .start {
            ready = true
            if failAfterStart {
                failAfterStart = false
                throw CocoaError(.fileReadUnknown)
            }
        }
        if request.action == .stop { ready = false }
        return .init(
            serviceUID: identity.serviceUID, bootstrapDomain: "user/\(identity.serviceUID)",
            state: ready ? "nativeReady" : "stopped", nativeVersion: ready ? "1.5.0" : nil)
    }
}
@MainActor
final class IsolatedRuntimeHostControllerTests: XCTestCase {
    private func terminal(_ controller: IsolatedRuntimeHostController) async throws -> IsolatedRuntimeStatus {
        for _ in 0..<100 {
            let state = try await controller.submit(.init(action: .status), ownerUID: 501)
            if state.isTerminal { return state }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.fileReadUnknown)
    }
    func testBusyWorkloadRefusesBeforeActionAndRecoveryReopensDataPlane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = RuntimeAdmission(root: root.appendingPathComponent("admission"))
        let driver = HostDriverFixture()
        let controller = IsolatedRuntimeHostController(
            driver: driver, journal: root.appendingPathComponent("operation.json"),
            admissionRoot: root.appendingPathComponent("admission"))
        _ = try await controller.submit(.init(action: .install), ownerUID: 501)
        _ = try await terminal(controller)
        _ = try await controller.submit(.init(action: .start), ownerUID: 501)
        _ = try await terminal(controller)
        let before = await driver.actions().filter { $0 == .stop }.count
        await driver.setBusy(true)
        _ = try await controller.submit(.init(action: .stop), ownerUID: 501)
        let refused = try await terminal(controller)
        XCTAssertEqual(refused.phase, "recoveryRequired")
        XCTAssertTrue(admission.isClosed)
        let stopped = await driver.actions().filter { $0 == .stop }.count
        XCTAssertEqual(stopped, before, "No stop may run while work remains active")
        _ = try await controller.submit(.init(action: .verify), ownerUID: 501)
        let recovered = try await terminal(controller)
        XCTAssertEqual(recovered.phase, "blocked", recovered.error ?? "")
        XCTAssertFalse(admission.isClosed, "Work must be able to finish through the data plane")
        withExtendedLifetime(try admission.claim("finish active work")) {}
    }
    func testInstallDoesNotStartRuntimeAndRetiredOperationCannotReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = HostDriverFixture()
        let controller = IsolatedRuntimeHostController(
            driver: driver, journal: root.appendingPathComponent("operation.json"),
            admissionRoot: root.appendingPathComponent("admission"))
        let install = IsolatedRuntimeRequest(action: .install)
        _ = try await controller.submit(install, ownerUID: 501)
        let staged = try await terminal(controller)
        XCTAssertEqual(staged.phase, "completed")
        XCTAssertNil(staged.selection)
        XCTAssertNotNil(staged.pendingSelection)
        let actions = await driver.actions()
        XCTAssertTrue(actions.isEmpty)
        _ = try await controller.submit(.init(action: .start), ownerUID: 501)
        let started = try await terminal(controller)
        XCTAssertEqual(started.nativeVersion, "1.5.0")
        do {
            _ = try await controller.submit(install, ownerUID: 501)
            XCTFail("Retired installation replayed")
        } catch {}
        let prepares = await driver.preparationCount()
        XCTAssertEqual(prepares, 1)
        do {
            _ = try await controller.submit(.init(action: .stop), ownerUID: 502)
            XCTFail("Another user controlled this runtime")
        } catch {}
    }
    func testUnknownStartKeepsFenceAndRecoveryVerifiesWithoutRepeatingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = HostDriverFixture()
        let controller = IsolatedRuntimeHostController(
            driver: driver, journal: root.appendingPathComponent("operation.json"),
            admissionRoot: root.appendingPathComponent("admission"))
        _ = try await controller.submit(.init(action: .install), ownerUID: 501)
        _ = try await terminal(controller)
        await driver.failOneStart()
        _ = try await controller.submit(.init(action: .start), ownerUID: 501)
        let failed = try await terminal(controller)
        XCTAssertEqual(failed.phase, "recoveryRequired")
        XCTAssertTrue(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
        _ = try await controller.submit(.init(action: .verify), ownerUID: 501)
        let recovered = try await terminal(controller)
        XCTAssertEqual(recovered.phase, "completed", recovered.error ?? "")
        XCTAssertFalse(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
        let actions = await driver.actions()
        XCTAssertEqual(actions.filter { $0 == .start }.count, 1)
    }
    func testRigReleaseLostReplyRecoversExactOperationWithoutRepeatingRuntimeAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = HostDriverFixture()
        let controller = IsolatedRuntimeHostController(
            driver: driver, journal: root.appendingPathComponent("operation.json"),
            admissionRoot: root.appendingPathComponent("admission"),
            registration: { .init(identity: $0, hostID: "host-a") })
        _ = try await controller.submit(.init(action: .install), ownerUID: 501)
        _ = try await terminal(controller)
        await driver.loseOneRigCompletion()
        _ = try await controller.submit(.init(action: .start), ownerUID: 501)
        let uncertain = try await terminal(controller)
        XCTAssertEqual(uncertain.phase, "recoveryRequired")
        XCTAssertTrue(uncertain.actionVerified == true)
        XCTAssertFalse(RuntimeAdmission(root: root.appendingPathComponent("admission")).isClosed)
        _ = try await controller.submit(.init(action: .verify), ownerUID: 501)
        let recovered = try await terminal(controller)
        XCTAssertEqual(recovered.phase, "completed", recovered.error ?? "")
        let actions = await driver.actions()
        XCTAssertEqual(actions.filter { $0 == .start }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .stop }.count, 1)
        let rig = await driver.rigHistory()
        XCTAssertEqual(rig, ["drain", "prepare", "begin", "verify", "complete", "verify", "complete"])
    }

    func testReloadedInterruptedStartAfterBootRetainsFenceUntilOutcomeIsVerified() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("operation.json")
        let admissionRoot = root.appendingPathComponent("admission")
        let originalDriver = HostDriverFixture()
        let original = IsolatedRuntimeHostController(
            driver: originalDriver, journal: journal, admissionRoot: admissionRoot)
        _ = try await original.submit(.init(action: .install), ownerUID: 501)
        var retained = try await terminal(original)
        let operation = UUID()
        retained.operation = operation
        retained.action = .start
        retained.phase = "starting"
        retained.actionVerified = false
        // Retained bytes represent the worker from the previous boot, even
        // when macOS has reused its PID for this test process.
        var birth = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    XCTUnwrap(RuntimeProcessBirth.read(getpid())))) as? [String: Any])
        birth["bootSession"] = UUID().uuidString
        retained.workerBirth = try JSONDecoder().decode(
            RuntimeProcessBirth.self, from: JSONSerialization.data(withJSONObject: birth))
        try RuntimeDurableFile.write(retained, to: journal)
        let admission = RuntimeAdmission(root: admissionRoot)
        do {
            let fence = try admission.begin(operation: operation)
            try fence.beginAction()
        }
        let afterBootDriver = HostDriverFixture()
        let restored = IsolatedRuntimeHostController(
            driver: afterBootDriver, journal: journal, admissionRoot: admissionRoot)
        let initial = try await restored.submit(.init(action: .status), ownerUID: 501)
        XCTAssertEqual(initial.phase, "recoveryRequired")
        XCTAssertTrue(admission.isClosed)
        do {
            _ = try await restored.submit(.init(action: .start), ownerUID: 501)
            XCTFail("A new start must not replace an unverified retained operation")
        } catch {}
        _ = try await restored.submit(.init(action: .verify), ownerUID: 501)
        let unknown = try await terminal(restored)
        XCTAssertEqual(unknown.phase, "recoveryRequired")
        XCTAssertEqual(unknown.operation, operation)
        XCTAssertTrue(admission.isClosed)
        let refusedActions = await afterBootDriver.actions()
        XCTAssertEqual(refusedActions, [.verify], "Recovery must inspect, never replay a start")
        await afterBootDriver.setReady(true)
        _ = try await restored.submit(.init(action: .verify), ownerUID: 501)
        let verified = try await terminal(restored)
        XCTAssertEqual(verified.phase, "completed", verified.error ?? "")
        XCTAssertEqual(verified.operation, operation)
        XCTAssertFalse(admission.isClosed)
        let recoveredActions = await afterBootDriver.actions()
        XCTAssertEqual(recoveredActions, [.verify, .verify])
    }

    func testFreshHealthProbeCannotOverlapAStartOrChangeItsOperationIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = HostDriverFixture()
        let controller = IsolatedRuntimeHostController(
            driver: driver, journal: root.appendingPathComponent("operation.json"),
            admissionRoot: root.appendingPathComponent("admission"))
        _ = try await controller.submit(.init(action: .install), ownerUID: 501)
        let installed = try await terminal(controller)
        await driver.pauseOneVerification()
        let probe = Task { try await controller.submit(.init(action: .probe), ownerUID: 501) }
        await driver.waitUntilPaused()
        do {
            _ = try await controller.submit(.init(action: .start), ownerUID: 501)
            XCTFail("Start overlapped a private probe")
        } catch {}
        await driver.resumeVerification()
        let health = try await probe.value
        XCTAssertEqual(health.operation, installed.operation)
        XCTAssertEqual(health.action, .install)
        XCTAssertEqual(health.nativeState, "stopped")
        let actions = await driver.actions()
        XCTAssertFalse(actions.contains(.start))
    }

}
