import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntimeHostKit

private actor HostDriverFixture: IsolatedRuntimeHostDriving {
    var events: [IsolatedRuntimeAction] = []
    var ready = false
    var failAfterStart = false
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
    func actions() -> [IsolatedRuntimeAction] { events }
    func preparationCount() -> Int { prepares }
    func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void
    ) async throws -> IsolatedRuntimeObservation {
        events.append(request.action)
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
