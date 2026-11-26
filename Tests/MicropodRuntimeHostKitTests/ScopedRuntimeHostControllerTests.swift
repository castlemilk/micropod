import Darwin
import Foundation
import Security
import XCTest

@testable import MicropodCore
@testable import MicropodRuntimeHostKit

private final class ScopedProofFixture: @unchecked Sendable {
    let key: SecKey
    let verifier: RuntimeCoordinationProofVerifier
    let identity: IsolatedRuntimeIdentity
    let peer: RuntimeProcessBirth
    let enrollment: RuntimeCoordinationEnrollment

    init(peer: RuntimeProcessBirth? = nil) throws {
        key = try XCTUnwrap(
            SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false,
                ] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        verifier = .init(issuer: "https://api.cuttlefish.sh", keyID: "scoped-fixture", publicKeyDER: der)
        identity = .init(
            instance: UUID(), ownerUID: getuid(), serviceUID: 400, serviceGID: 401,
            accountGUID: UUID(), groupGUID: UUID())
        self.peer = try peer ?? XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        enrollment = .init(
            schemaVersion: RuntimeCoordinationEnrollment.capability, scope: RuntimeCoordinationEnrollment.runtimeScope,
            resourceId: "mrt-" + UUID().uuidString.lowercased(), organizationId: "org-a", runnerId: "rig-a",
            revision: 1, enabled: true,
            binding: .init(
                instance: identity.instance.uuidString, hostKey: String(repeating: "b", count: 64),
                ownerUID: identity.ownerUID, serviceUID: identity.serviceUID, serviceGID: identity.serviceGID,
                accountGUID: identity.accountGUID.uuidString, groupGUID: identity.groupGUID.uuidString))
    }

    func sign(
        challenge: String, purpose: String, state: [String: Any]? = nil,
        peer: RuntimeProcessBirth? = nil, enrollment: RuntimeCoordinationEnrollment? = nil, generation: Int64 = 7
    ) throws -> String {
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let now = Int64(Date().timeIntervalSince1970)
        var claims: [String: Any] = [
            "iss": "https://api.cuttlefish.sh", "aud": "micropod-runtime-coordination", "sub": "runner:rig-a",
            "iat": now, "nbf": now - 5, "exp": now + 120, "jti": UUID().uuidString,
            "schemaVersion": "micropod-runtime-proof-v1", "purpose": purpose,
            "scope": RuntimeCoordinationEnrollment.runtimeScope, "sessionGeneration": generation,
            "challenge": challenge,
            "enrollment": try JSONSerialization.jsonObject(with: JSONEncoder().encode(enrollment ?? self.enrollment)),
            "peer": try JSONSerialization.jsonObject(with: JSONEncoder().encode(peer ?? self.peer)),
        ]
        claims["state"] = state
        let header = try JSONSerialization.data(withJSONObject: [
            "alg": "RS256", "typ": "micropod-runtime-proof+jwt", "kid": "scoped-fixture",
        ])
        let input = try encode(header) + "." + encode(JSONSerialization.data(withJSONObject: claims))
        let signature =
            try XCTUnwrap(
                SecKeyCreateSignature(
                    key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
        return input + "." + encode(signature)
    }
}

private actor ScopedHostDriverFixture: IsolatedRuntimeHostDriving {
    let proofs: ScopedProofFixture
    let gate: RuntimeAdmission
    let selection = ManagedRuntimeLocation.Selection(
        version: AppleRuntimeRelease.supported.version, packageSHA256: AppleRuntimeRelease.supported.packageSHA256,
        incarnation: UUID())
    var ready = false
    var busy = false
    var holdDrain = false
    var loseCompletion = false
    var corruptBegin = false
    /// The next native start fails and leaves the runtime stopped.
    var failStart = false
    /// The dedicated API the fixture "activates", shared with the component
    /// environment fixture.
    nonisolated let box = ActiveAPIBox()
    /// Component staging installs other bytes than it was given.
    var tamperStaging = false
    /// The coordinator does not schedule onto this build: `qualify` is
    /// answered notRecorded.
    var unqualified = false
    /// The next drain is refused before the coordinator saw it (phase
    /// `refused`), as an agent refuses an unqualified build.
    var refuseNextDrainUnprocessed: String?
    var restored: [RuntimeComponentRuntime] = []
    /// The next drain is refused before the coordinator records it, as a
    /// coordinator that is stopping or busy answers.
    var refuseNextDrain: String?
    /// Calls the coordinator answers "not recorded".
    var unrecorded: Set<String> = []
    /// The newest local generation the coordinator has recorded; like
    /// Cuttlefish, it refuses a new operation that is not newer.
    var recordedGeneration: Int64 = 0
    /// Each operation's local generation, as its first drain carried it.
    var drainGenerations: [Int64] = []
    var nativeActions: [IsolatedRuntimeAction] = []
    var history: [String] = []
    var gateAtPhase: [String: Bool] = [:]
    var generation: Int64 = 0
    var current: RuntimeCoordinationOperation?
    var released: RuntimeCoordinationOperation?
    var kind = ""
    var coordinatorPeer: RuntimeProcessBirth
    var policy: RuntimeCoordinationEnrollment
    var sessionGeneration: Int64 = 7
    init(proofs: ScopedProofFixture, admissionRoot: URL) {
        self.proofs = proofs
        gate = RuntimeAdmission(root: admissionRoot)
        coordinatorPeer = proofs.peer
        policy = proofs.enrollment
    }
    func replaceCoordinator(_ peer: RuntimeProcessBirth, policy: RuntimeCoordinationEnrollment) {
        coordinatorPeer = peer
        self.policy = policy
        sessionGeneration += 1
    }
    func setBusy() { busy = true }
    func setHoldDrain(_ value: Bool) { holdDrain = value }
    func refuseNextDrain(_ reason: String) { refuseNextDrain = reason }
    func answerNotRecorded(_ actions: Set<String>) { unrecorded = actions }
    func loseOneCompletion() { loseCompletion = true }
    func failNextStart() { failStart = true }
    func setTamperStaging() { tamperStaging = true }
    func setUnqualified(_ value: Bool) { unqualified = value }
    func refuseNextDrainUnprocessed(_ reason: String) { refuseNextDrainUnprocessed = reason }
    func restoredRuntimes() -> [RuntimeComponentRuntime] { restored }
    func prepare(ownerUID: UInt32, components: RuntimeComponentSource) throws -> PreparedIsolatedRuntime {
        let api =
            tamperStaging
            ? RuntimeComponentAPI(executableSHA256: String(repeating: "f", count: 64), guestSHA256: nil)
            : components.api
        box.staged = api
        return .init(
            identity: proofs.identity, receipt: .init(selection: selection, files: AppleRuntimeRelease.payloadSHA256),
            workerSHA256: components.helperSHA256, api: api)
    }
    func restore(identity: IsolatedRuntimeIdentity, runtime: RuntimeComponentRuntime) throws
        -> PreparedIsolatedRuntime
    {
        restored.append(runtime)
        box.staged = runtime.api
        return .init(
            identity: identity, receipt: .init(selection: runtime.selection, files: AppleRuntimeRelease.payloadSHA256),
            workerSHA256: runtime.workerSHA256, api: runtime.api)
    }
    nonisolated func activateAPI(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection) throws
    {
        box.activate()
    }
    func corruptOneBegin() { corruptBegin = true }
    func simulateStoppedRuntime() { ready = false }
    func snapshot() -> ([IsolatedRuntimeAction], [String], [String: Bool]) { (nativeActions, history, gateAtPhase) }
    func prepare(ownerUID: UInt32) throws -> PreparedIsolatedRuntime {
        .init(
            identity: proofs.identity,
            receipt: .init(selection: selection, files: AppleRuntimeRelease.payloadSHA256),
            workerSHA256: String(repeating: "2", count: 64))
    }
    func rigTransition(
        identity: IsolatedRuntimeIdentity, operation: UUID, action: String, installRoot: URL,
        generation: UInt64, targetState: String
    ) throws -> RuntimeRigReceipt? { throw CocoaError(.featureUnsupported) }

    func coordinateRuntime(
        identity: IsolatedRuntimeIdentity, peer: RuntimeProcessBirth, call: RuntimeCoordinationRigCall
    ) throws -> RuntimeCoordinationRigReply {
        XCTAssertEqual(identity, proofs.identity)
        XCTAssertEqual(peer, coordinatorPeer)
        XCTAssertEqual(call.enrollment, proofs.enrollment)
        history.append(call.action)
        gateAtPhase[call.action] = gate.isClosed
        func refusal(_ phase: String, _ reason: String) throws -> RuntimeCoordinationRigReply {
            try JSONDecoder().decode(
                RuntimeCoordinationRigReply.self,
                from: JSONSerialization.data(withJSONObject: [
                    "schemaVersion": RuntimeCoordinationEnrollment.capability,
                    "scope": RuntimeCoordinationEnrollment.runtimeScope,
                    "operation": call.operation.id, "phase": phase, "reason": reason,
                ]))
        }
        if call.action == "qualify" {
            return try JSONDecoder().decode(
                RuntimeCoordinationRigReply.self,
                from: JSONSerialization.data(withJSONObject: [
                    "schemaVersion": RuntimeCoordinationEnrollment.capability,
                    "scope": RuntimeCoordinationEnrollment.runtimeScope, "operation": call.operation.id,
                    "phase": unqualified ? RuntimeCoordinationRigReply.notRecordedPhase : "qualified",
                    "reason": unqualified ? "Not recorded: this agent does not qualify the runtime build" : "",
                ]))
        }
        if call.action == "drain", let reason = refuseNextDrainUnprocessed {
            refuseNextDrainUnprocessed = nil
            return try refusal(RuntimeCoordinationRigReply.refusedPhase, reason)
        }
        if call.action == "drain", let reason = refuseNextDrain {
            refuseNextDrain = nil
            return try refusal("blocked", reason)
        }
        if unrecorded.contains(call.action) {
            return try refusal(
                RuntimeCoordinationRigReply.notRecordedPhase,
                "Not recorded: this rig never drained or fenced private runtime operation \(call.operation.id)")
        }
        if call.action == "drain", current?.id != call.operation.id, released?.id != call.operation.id {
            drainGenerations.append(call.operation.localGeneration)
            if call.operation.localGeneration <= recordedGeneration {
                return try refusal(
                    RuntimeCoordinationRigReply.notRecordedPhase,
                    "Not recorded: local generation \(call.operation.localGeneration) is not newer than the "
                        + "retained operation's \(recordedGeneration)")
            }
        }
        if call.action == "drain", current == nil, released?.id != call.operation.id {
            recordedGeneration = call.operation.localGeneration
            current = call.operation
            generation += 1
        }
        let completing = ["complete", "abortComplete"].contains(call.action)
        if completing, current != nil {
            released = current
            current = nil
            generation += 1
            kind = try XCTUnwrap(call.releaseKind).rawValue
            if loseCompletion {
                loseCompletion = false
                throw CocoaError(.fileReadUnknown)
            }
        }
        let empty: [String: Any] = [
            "id": "", "runtimeInstance": "", "action": "", "localGeneration": 0,
            "version": "", "packageSHA256": "", "installRoot": "", "targetState": "",
        ]
        var state: [String: Any] = [
            "scope": proofs.enrollment.scope, "resourceId": proofs.enrollment.resourceId, "revision": policy.revision,
            "owner": current?.id ?? "", "generation": generation,
            "closed": current != nil || kind != "running" || !policy.enabled,
            "operation": try current.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? empty,
            "lastReleasedOwner": released?.id ?? "", "lastReleasedGeneration": released == nil ? -1 : generation - 1,
            "lastReleasedRevision": released == nil ? 0 : 1, "lastReleasedKind": kind,
            "lastReleasedOperation": try released.map {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
            } ?? empty,
        ]
        if call.action == "begin", corruptBegin {
            corruptBegin = false
            state["owner"] = UUID().uuidString.lowercased()
        }
        let purpose = completing ? "release-observation" : "maintenance"
        let proof = try proofs.sign(
            challenge: call.challenge, purpose: purpose, state: state,
            peer: coordinatorPeer, enrollment: policy, generation: sessionGeneration)
        let phase =
            call.action == "drain" && holdDrain
            ? "draining"
            : [
                "drain": "drained", "prepare": "prepared", "begin": "begun", "verify": "verified",
                "complete": "completed", "abort": "aborting", "abortComplete": "cancelled",
            ][call.action]!
        return try JSONDecoder().decode(
            RuntimeCoordinationRigReply.self,
            from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": RuntimeCoordinationEnrollment.capability,
                "scope": RuntimeCoordinationEnrollment.runtimeScope,
                "operation": call.operation.id, "phase": phase, "state": state,
                completing ? "releaseProof" : "maintenanceProof": proof,
            ]))
    }

    func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void
    ) throws -> IsolatedRuntimeObservation {
        nativeActions.append(request.action)
        if request.requiresIdle && busy { throw CocoaError(.fileWriteNoPermission) }
        if request.action == .stop { ready = false }
        if request.action == .start {
            if failStart {
                failStart = false
                ready = false
                throw CocoaError(.executableLoad)
            }
            ready = true
        }
        let root = IsolatedRuntimePolicy.root.appendingPathComponent("apple/versions/" + selection.directoryName)
        return .init(
            serviceUID: identity.serviceUID, bootstrapDomain: "user/\(identity.serviceUID)",
            state: ready ? "nativeReady" : "stopped", nativeVersion: ready ? "1.5.0" : nil,
            nativeAppRoot: ready ? IsolatedRuntimePolicy.appRoot.path : nil,
            nativeInstallRoot: ready ? root.path : nil)
    }
}

@MainActor
final class ScopedRuntimeHostControllerTests: XCTestCase {
    private func terminal(_ controller: IsolatedRuntimeHostController) async throws -> IsolatedRuntimeStatus {
        for _ in 0..<200 {
            let status = try await controller.submit(.init(action: .status), ownerUID: getuid())
            if status.isTerminal { return status }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.fileReadUnknown)
    }
    private func fixture(peer: RuntimeProcessBirth? = nil, drainTimeout: Duration = .seconds(120)) async throws -> (
        IsolatedRuntimeHostController, ScopedHostDriverFixture, URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let proofs = try ScopedProofFixture(peer: peer)
        let journal = root.appendingPathComponent("operation.json")
        let admissionRoot = root.appendingPathComponent("admission")
        let driver = ScopedHostDriverFixture(proofs: proofs, admissionRoot: admissionRoot)
        let installer = IsolatedRuntimeHostController(driver: driver, journal: journal, admissionRoot: admissionRoot)
        _ = try await installer.submit(.init(action: .install), ownerUID: getuid())
        _ = try await terminal(installer)
        var coordinator = RuntimeCoordinatorAuthority(
            fileURL: root.appendingPathComponent("runtime-coordinator.json"), ownerUID: getuid(),
            verifier: proofs.verifier)
        let nonce = try coordinator.issueChallenge(identity: proofs.identity, peer: proofs.peer, purpose: "enrollment")
        _ = try coordinator.enroll(
            proofs.sign(challenge: nonce, purpose: "enrollment"), challenge: nonce,
            identity: proofs.identity, peer: proofs.peer)
        return (
            IsolatedRuntimeHostController(
                driver: driver, journal: journal, admissionRoot: admissionRoot,
                coordinator: coordinator, verifyCoordinatorAccount: { _ in }, drainTimeout: drainTimeout), driver, root
        )
    }

    func testDrainTimeoutAbandonsScopedHandoffAndLeavesRuntimeRunning() async throws {
        let (controller, driver, root) = try await fixture(drainTimeout: .milliseconds(50))
        let admission = RuntimeAdmission(root: root.appendingPathComponent("admission"))
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let started = try await terminal(controller)
        XCTAssertEqual(started.phase, "completed", started.error ?? "")
        let (beforeNative, beforeHistory, _) = await driver.snapshot()

        await driver.setHoldDrain(true)
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let abandoned = try await terminal(controller)
        XCTAssertEqual(abandoned.phase, "cancelled", abandoned.error ?? "")
        XCTAssertNotEqual(abandoned.phase, "recoveryRequired")
        XCTAssertTrue(abandoned.error?.contains("did not drain") == true, abandoned.error ?? "")
        XCTAssertEqual(abandoned.runtimeCancelledBeforeAction, true)
        XCTAssertEqual(abandoned.runtimeActionStarted, false)
        XCTAssertEqual(abandoned.runtimeRigAttempted, false, "The handoff must not stay held")
        XCTAssertEqual(abandoned.nativeState, "nativeReady")
        XCTAssertFalse(admission.isClosed)
        try XCTUnwrap(admission.claim("work continues after the abandoned drain")).completed()
        let (native, history, gates) = await driver.snapshot()
        XCTAssertEqual(native, beforeNative, "No native action may run when the drain is abandoned")
        let restart = Array(history.dropFirst(beforeHistory.count))
        XCTAssertGreaterThanOrEqual(restart.filter { $0 == "drain" }.count, 2)
        XCTAssertEqual(restart.filter { $0 != "drain" }, ["abort", "abortComplete"])
        XCTAssertEqual(gates["abort"], false)
        XCTAssertEqual(gates["abortComplete"], false)
        let kind = await driver.kind
        XCTAssertEqual(kind, "cancelled")

        // Nothing is left to recover: the next restart proceeds directly.
        await driver.setHoldDrain(false)
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let restarted = try await terminal(controller)
        XCTAssertEqual(restarted.phase, "completed", restarted.error ?? "")
        let (afterNative, _, _) = await driver.snapshot()
        XCTAssertEqual(afterNative.filter { $0 == .stop }.count, beforeNative.filter { $0 == .stop }.count + 1)
    }

    // The Gamma-128GB deadlock (2026-11-18), replayed. A restart's first
    // drain reached a coordinator that was stopping. The coordinator refused it
    // and recorded nothing, but the handoff was already marked attempted, so
    // the restart waited in recoveryRequired. Every `recover` then asked to
    // abort an operation the coordinator never had. Once the coordinator
    // answers "not recorded", recovery settles the restart as cancelled, with
    // no native action and no abortComplete, and the next restart runs.
    func testRecoverySettlesARestartTheCoordinatorNeverRecorded() async throws {
        let (controller, driver, root) = try await fixture()
        let admission = RuntimeAdmission(root: root.appendingPathComponent("admission"))
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let started = try await terminal(controller)
        XCTAssertEqual(started.phase, "completed", started.error ?? "")
        let (beforeNative, beforeHistory, _) = await driver.snapshot()

        await driver.refuseNextDrain("The private runtime request is invalid")
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let retained = try await terminal(controller)
        XCTAssertEqual(retained.phase, "recoveryRequired", "A plain refusal may have been recorded; it is kept")
        XCTAssertEqual(retained.runtimeRigAttempted, true)
        XCTAssertEqual(retained.runtimeActionStarted, false)
        XCTAssertFalse(admission.isClosed)

        await driver.answerNotRecorded(["abort"])
        _ = try await controller.submit(.init(action: .verify), ownerUID: getuid())
        let settled = try await terminal(controller)
        XCTAssertEqual(settled.phase, "cancelled", settled.error ?? "")
        XCTAssertEqual(settled.runtimeRigAttempted, false, "The handoff must not stay retained")
        XCTAssertEqual(settled.runtimeCancelledBeforeAction, true)
        XCTAssertEqual(settled.runtimeActionStarted, false)
        XCTAssertEqual(settled.nativeState, "nativeReady")
        XCTAssertTrue(settled.error?.hasPrefix("Not recorded:") == true, settled.error ?? "")
        XCTAssertFalse(admission.isClosed)
        let (native, history, _) = await driver.snapshot()
        XCTAssertEqual(native, beforeNative, "No native action may run when settling")
        XCTAssertEqual(Array(history.dropFirst(beforeHistory.count)), ["drain", "abort"])

        await driver.answerNotRecorded([])
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let restarted = try await terminal(controller)
        XCTAssertEqual(restarted.phase, "completed", restarted.error ?? "")
    }

    // A first drain the coordinator answers "not recorded" fails the
    // operation outright instead of retaining a handoff nobody holds. Once a
    // drain has been accepted, the same answer no longer settles anything.
    func testUnrecordedFirstDrainFailsWithoutRetainingTheHandoff() async throws {
        let (controller, driver, _) = try await fixture()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let started = try await terminal(controller)
        XCTAssertEqual(started.phase, "completed", started.error ?? "")
        let (beforeNative, _, _) = await driver.snapshot()

        await driver.answerNotRecorded(["drain"])
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let failed = try await terminal(controller)
        XCTAssertEqual(failed.phase, "failed", failed.error ?? "")
        XCTAssertEqual(failed.runtimeRigAttempted, false)
        XCTAssertEqual(failed.runtimeActionStarted, false)
        XCTAssertTrue(failed.error?.hasPrefix("Not recorded:") == true, failed.error ?? "")
        let (native, _, _) = await driver.snapshot()
        XCTAssertEqual(native, beforeNative)

        await driver.answerNotRecorded([])
        await driver.setHoldDrain(true)
        let (_, before, _) = await driver.snapshot()
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        for _ in 0..<400 {
            let (_, history, _) = await driver.snapshot()
            if history.count > before.count { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await driver.answerNotRecorded(["drain"])
        let retained = try await terminal(controller)
        XCTAssertEqual(retained.phase, "recoveryRequired", retained.error ?? "")
        XCTAssertEqual(retained.runtimeRigAttempted, true, "An accepted drain keeps its handoff")
    }

    // Gamma-128GB again: the admission generation advanced only when a fence
    // was taken. A restart whose drain the coordinator recorded, but which
    // ended before its fence, left the next operation the same generation,
    // and the coordinator refused it as not newer than the one it had
    // recorded (E31BBEF7, then 31C5CA26, both at 25). Each operation now
    // carries a generation of its own, fenced or not.
    func testOperationsThatNeverFencedStillGetNewerGenerations() async throws {
        let (controller, driver, _) = try await fixture(drainTimeout: .milliseconds(50))
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let started = try await terminal(controller)
        XCTAssertEqual(started.phase, "completed", started.error ?? "")

        await driver.setHoldDrain(true)
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let abandoned = try await terminal(controller)
        XCTAssertEqual(abandoned.phase, "cancelled", "recorded by the coordinator, never fenced")
        await driver.setHoldDrain(false)

        await driver.answerNotRecorded(["drain"])
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let refused = try await terminal(controller)
        XCTAssertEqual(refused.phase, "failed", refused.error ?? "")
        await driver.answerNotRecorded([])

        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let restarted = try await terminal(controller)
        XCTAssertEqual(restarted.phase, "completed", restarted.error ?? "")
        let issued = [started, abandoned, refused, restarted].compactMap(\.localGeneration)
        XCTAssertEqual(issued.count, 4)
        XCTAssertEqual(issued, issued.sorted())
        XCTAssertEqual(Set(issued).count, 4, "a generation was reused: \(issued)")
        let drained = await driver.drainGenerations
        XCTAssertEqual(drained, drained.sorted())
        XCTAssertEqual(Set(drained).count, drained.count, "the coordinator saw a generation twice: \(drained)")
    }

    func testSignedScopedHandoffRunsWithoutLegacyHostGrantAndReconcilesLostCompletion() async throws {
        let (controller, driver, root) = try await fixture()
        await driver.loseOneCompletion()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let uncertain = try await terminal(controller)
        XCTAssertEqual(uncertain.phase, "recoveryRequired", uncertain.error ?? "")
        XCTAssertEqual(uncertain.runtimeRigAttempted, true)
        XCTAssertNil(uncertain.rig)
        XCTAssertNotNil(uncertain.runtimeRig)
        _ = try await controller.submit(.init(action: .verify), ownerUID: getuid())
        let completed = try await terminal(controller)
        XCTAssertEqual(completed.phase, "completed", completed.error ?? "")
        XCTAssertEqual(completed.runtimeRigAttempted, false)
        let (native, history, gates) = await driver.snapshot()
        XCTAssertEqual(native.filter { $0 == .start }.count, 1)
        XCTAssertEqual(native.filter { $0 == .stop }.count, 1)
        XCTAssertEqual(history, ["drain", "prepare", "begin", "verify", "complete", "complete"])
        XCTAssertEqual(gates["begin"], true)
        XCTAssertEqual(gates["complete"], false)
        let persisted = try String(contentsOf: root.appendingPathComponent("operation.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("maintenanceProof"))
        XCTAssertFalse(persisted.contains("releaseProof"))
    }

    func testScopedCancellationPreservesUnexecutedStartAndVerifiesClosedReleaseKind() async throws {
        let (controller, driver, _) = try await fixture()
        await driver.setBusy()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let blocked = try await terminal(controller)
        XCTAssertEqual(blocked.phase, "recoveryRequired")
        _ = try await controller.submit(.init(action: .verify), ownerUID: getuid())
        let cancelled = try await terminal(controller)
        XCTAssertEqual(cancelled.phase, "blocked", cancelled.error ?? "")
        XCTAssertEqual(cancelled.runtimeCancelledBeforeAction, true)
        let (native, history, _) = await driver.snapshot()
        XCTAssertFalse(native.contains(.start))
        XCTAssertFalse(native.contains(.stop))
        XCTAssertEqual(history, ["drain", "prepare", "abort", "abortComplete"])
    }

    func testDepartedPeerReconcilesLostReleaseUnderRevokedPolicyWithoutRestoringAccess() async throws {
        let prior = Process()
        prior.executableURL = URL(fileURLWithPath: "/bin/sleep")
        prior.arguments = ["60"]
        try prior.run()
        defer {
            if prior.isRunning { prior.terminate() }
            prior.waitUntilExit()
        }
        let oldPeer = try XCTUnwrap(RuntimeProcessBirth.read(prior.processIdentifier))
        let (controller, driver, root) = try await fixture(peer: oldPeer)
        await driver.loseOneCompletion()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let uncertain = try await terminal(controller)
        XCTAssertEqual(uncertain.phase, "recoveryRequired", uncertain.error ?? "")
        let retained = try XCTUnwrap(uncertain.runtimeRig)
        let proofs = driver.proofs
        let before = await driver.snapshot()
        prior.terminate()
        prior.waitUntilExit()
        XCTAssertTrue(try oldPeer.hasExited())
        let replacement = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        let disabled = RuntimeCoordinationEnrollment(
            schemaVersion: proofs.enrollment.schemaVersion, scope: proofs.enrollment.scope,
            resourceId: proofs.enrollment.resourceId, organizationId: proofs.enrollment.organizationId,
            runnerId: proofs.enrollment.runnerId, revision: 2, enabled: false, binding: proofs.enrollment.binding)
        let challenge = try await controller.coordinateRuntime(
            .init(action: "runtime-recovery-challenge"), identity: proofs.identity, peer: replacement)
        XCTAssertEqual(challenge.enrollment, retained.enrollment)
        XCTAssertEqual(challenge.coverage?.operation, retained.operation)
        XCTAssertEqual(challenge.coverage?.admissionClosed, false)
        XCTAssertNil(challenge.session)
        let nonce = try XCTUnwrap(challenge.challenge)
        let empty: [String: Any] = [
            "id": "", "runtimeInstance": "", "action": "", "localGeneration": 0,
            "version": "", "packageSHA256": "", "installRoot": "", "targetState": "",
        ]
        let released: [String: Any] = [
            "scope": disabled.scope, "resourceId": disabled.resourceId, "revision": disabled.revision,
            "owner": "", "generation": retained.resourceGeneration + 1, "closed": true, "operation": empty,
            "lastReleasedOwner": retained.operation.id, "lastReleasedGeneration": retained.resourceGeneration,
            "lastReleasedRevision": retained.enrollment.revision, "lastReleasedKind": "running",
            "lastReleasedOperation": try JSONSerialization.jsonObject(with: JSONEncoder().encode(retained.operation)),
        ]
        let proof = try proofs.sign(
            challenge: nonce, purpose: "release-observation", state: released,
            peer: replacement, enrollment: disabled, generation: 8)
        let rebound = try await controller.coordinateRuntime(
            .init(action: "runtime-reconcile-peer", challenge: nonce, proof: proof),
            identity: proofs.identity, peer: replacement)
        XCTAssertEqual(rebound.enrollment, retained.enrollment)
        XCTAssertNil(rebound.session)
        let authority = RuntimeCoordinatorAuthority(
            fileURL: root.appendingPathComponent("runtime-coordinator.json"), ownerUID: getuid(),
            verifier: proofs.verifier)
        XCTAssertEqual(try authority.read(identity: proofs.identity)?.peer, replacement)
        XCTAssertEqual(try authority.read(identity: proofs.identity)?.reconciliationOnly, true)

        await driver.replaceCoordinator(replacement, policy: disabled)
        _ = try await controller.submit(.init(action: .verify), ownerUID: getuid())
        let completed = try await terminal(controller)
        XCTAssertEqual(completed.phase, "completed", completed.error ?? "")
        XCTAssertEqual(completed.runtimeRigAttempted, false)
        let after = await driver.snapshot()
        XCTAssertEqual(after.0, before.0 + [.verify])
        XCTAssertEqual(after.1, before.1 + ["complete"])
        let sessionChallenge = try await controller.coordinateRuntime(
            .init(action: "runtime-challenge", purpose: "session"), identity: proofs.identity, peer: replacement)
        let sessionNonce = try XCTUnwrap(sessionChallenge.challenge)
        let oldApproval = try proofs.sign(
            challenge: sessionNonce, purpose: "enrollment", peer: replacement, generation: 8)
        do {
            _ = try await controller.coordinateRuntime(
                .init(action: "runtime-session", challenge: sessionNonce, proof: oldApproval),
                identity: proofs.identity, peer: replacement)
            XCTFail("Receipt reconciliation must not issue a data session")
        } catch {}
    }

    func testWrongSignedBeginOwnerRefusesBeforeAnyNativeAction() async throws {
        let (controller, driver, _) = try await fixture()
        await driver.corruptOneBegin()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let refused = try await terminal(controller)
        XCTAssertEqual(refused.phase, "recoveryRequired")
        XCTAssertEqual(refused.runtimeActionStarted, false)
        let (native, _, _) = await driver.snapshot()
        XCTAssertFalse(native.contains(.start))
        XCTAssertFalse(native.contains(.stop))
    }

    func testHelperReplacementReconcilesExactReleaseWithoutReplayingNativeAction() async throws {
        let (controller, driver, root) = try await fixture()
        await driver.loseOneCompletion()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        let uncertain = try await terminal(controller)
        XCTAssertEqual(uncertain.phase, "recoveryRequired")
        let proofs = driver.proofs
        let replacement = IsolatedRuntimeHostController(
            driver: driver, journal: root.appendingPathComponent("operation.json"),
            admissionRoot: root.appendingPathComponent("admission"),
            coordinator: .init(
                fileURL: root.appendingPathComponent("runtime-coordinator.json"), ownerUID: getuid(),
                verifier: proofs.verifier))
        _ = try await replacement.submit(.init(action: .verify), ownerUID: getuid())
        let completed = try await terminal(replacement)
        XCTAssertEqual(completed.phase, "completed", completed.error ?? "")
        let (native, history, _) = await driver.snapshot()
        XCTAssertEqual(native.filter { $0 == .start }.count, 1)
        XCTAssertEqual(history.suffix(2), ["complete", "complete"])
    }

    func testLostCancellationReleaseDoesNotBecomeCompletedStartOnRetry() async throws {
        let (controller, driver, _) = try await fixture()
        await driver.setBusy()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        _ = try await terminal(controller)
        await driver.loseOneCompletion()
        _ = try await controller.submit(.init(action: .verify), ownerUID: getuid())
        let uncertain = try await terminal(controller)
        XCTAssertEqual(uncertain.phase, "recoveryRequired")
        XCTAssertEqual(uncertain.runtimeCancelledBeforeAction, true)
        _ = try await controller.submit(.init(action: .verify), ownerUID: getuid())
        let cancelled = try await terminal(controller)
        XCTAssertEqual(cancelled.phase, "blocked", cancelled.error ?? "")
        XCTAssertEqual(cancelled.runtimeRigAttempted, false)
        let (native, history, _) = await driver.snapshot()
        XCTAssertFalse(native.contains(.start))
        XCTAssertFalse(native.contains(.stop))
        XCTAssertEqual(history.suffix(3), ["abort", "abortComplete", "abortComplete"])
    }

    func testChangedNativeOutcomeCannotSettleRetainedRunningRelease() async throws {
        let (controller, driver, _) = try await fixture()
        await driver.loseOneCompletion()
        _ = try await controller.submit(.init(action: .start), ownerUID: getuid())
        _ = try await terminal(controller)
        await driver.simulateStoppedRuntime()
        _ = try await controller.submit(.init(action: .verify), ownerUID: getuid())
        let refused = try await terminal(controller)
        XCTAssertEqual(refused.phase, "recoveryRequired")
        XCTAssertEqual(refused.runtimeRigAttempted, true)
        let (native, history, _) = await driver.snapshot()
        XCTAssertEqual(native.filter { $0 == .start }.count, 1)
        XCTAssertEqual(history.filter { $0 == "complete" }.count, 1)
    }
}

// MARK: - Runtime component updates (docs/runtime-component-update.md)

private final class RelaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.withLock { count += 1 } }
    var relaunches: Int { lock.withLock { count } }
}

private struct ComponentRig {
    let driver: ScopedHostDriverFixture
    let root: URL
    let environment: ComponentEnvironmentFixture
    let updater: RuntimeComponentUpdater
    let make: (RelaunchRecorder?) -> IsolatedRuntimeHostController
}

extension ScopedRuntimeHostControllerTests {
    /// A running dedicated runtime enrolled with a signed coordinator, and a
    /// way to construct the helper again as launchd would after a relaunch.
    fileprivate func componentRig() async throws -> ComponentRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let proofs = try ScopedProofFixture()
        let journal = root.appendingPathComponent("operation.json")
        let admissionRoot = root.appendingPathComponent("admission")
        let driver = ScopedHostDriverFixture(proofs: proofs, admissionRoot: admissionRoot)
        let installer = IsolatedRuntimeHostController(driver: driver, journal: journal, admissionRoot: admissionRoot)
        _ = try await installer.submit(.init(action: .install), ownerUID: getuid())
        _ = try await terminal(installer)
        var coordinator = RuntimeCoordinatorAuthority(
            fileURL: root.appendingPathComponent("runtime-coordinator.json"), ownerUID: getuid(),
            verifier: proofs.verifier)
        let nonce = try coordinator.issueChallenge(identity: proofs.identity, peer: proofs.peer, purpose: "enrollment")
        _ = try coordinator.enroll(
            proofs.sign(challenge: nonce, purpose: "enrollment"), challenge: nonce,
            identity: proofs.identity, peer: proofs.peer)
        let environment = try ComponentEnvironmentFixture(root: root.appendingPathComponent("host"), api: driver.box)
        environment.api.active = .init(executableSHA256: ComponentEnvironmentFixture.source.apiSHA256, guestSHA256: nil)
        let updater = RuntimeComponentUpdater(environment: environment)
        let coordinatorURL = root.appendingPathComponent("runtime-coordinator.json")
        let verifier = proofs.verifier
        let make: (RelaunchRecorder?) -> IsolatedRuntimeHostController = { recorder in
            // A relaunched helper reads its enrollment from disk.
            IsolatedRuntimeHostController(
                driver: driver, journal: journal, admissionRoot: admissionRoot,
                coordinator: RuntimeCoordinatorAuthority(
                    fileURL: coordinatorURL, ownerUID: getuid(), verifier: verifier),
                verifyCoordinatorAccount: { _ in }, components: updater,
                relaunch: { recorder?.mark() })
        }
        let first = make(nil)
        _ = try await first.submit(.init(action: .start), ownerUID: getuid())
        let started = try await terminal(first)
        XCTAssertEqual(started.phase, "completed", started.error ?? "")
        return .init(driver: driver, root: root, environment: environment, updater: updater, make: make)
    }

    private func componentOutcome(_ controller: IsolatedRuntimeHostController, _ operation: UUID) async throws
        -> RuntimeComponentUpdateSummary
    {
        for _ in 0..<400 {
            let status = try await controller.submit(.init(action: .status), ownerUID: getuid())
            if let summary = status.componentUpdate, summary.operation == operation, summary.isTerminal,
                status.isTerminal
            {
                return summary
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.fileReadUnknown)
    }

    /// launchd starts whatever is installed; it settles at launch and serves.
    fileprivate func relaunchInstalled(_ rig: ComponentRig) async throws -> IsolatedRuntimeHostController {
        try rig.environment.launchInstalled()
        XCTAssertEqual(rig.updater.launch(), .proceedUnconfirmed)
        let helper = rig.make(nil)
        let confirmed = await helper.continueComponentUpdate()
        XCTAssertTrue(confirmed)
        return helper
    }

    /// The old helper swaps in the new one and lets launchd relaunch it; the
    /// new one settles the swap at launch and starts serving. `asRoot` sends
    /// the request as `sudo micropod runtime update --force` does: forced,
    /// from a peer whose audit token says euid 0.
    private func swapAndRelaunch(_ rig: ComponentRig, operation: UUID, asRoot: Bool = false) async throws
        -> IsolatedRuntimeHostController
    {
        let recorder = RelaunchRecorder()
        let old = rig.make(recorder)
        let request = IsolatedRuntimeRequest(operation: operation, action: .update, force: asRoot ? true : nil)
        let peer: UInt32 = asRoot ? 0 : getuid()
        let accepted = try await old.submit(request, ownerUID: peer)
        XCTAssertEqual(accepted.componentProtocol, RuntimeComponentManifest.protocolVersion)
        XCTAssertEqual(accepted.componentUpdate?.operation, operation)
        // A lost reply: the same request again is answered, never repeated.
        let repeated = try await old.submit(request, ownerUID: peer)
        XCTAssertEqual(repeated.componentUpdate?.operation, operation)
        for _ in 0..<400 where recorder.relaunches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(recorder.relaunches, 1)
        XCTAssertEqual(rig.environment.copies, 2, "One request stages once: the swapped and the verified copy")
        XCTAssertEqual(try rig.environment.inspect(rig.environment.installedBundle), ComponentEnvironmentFixture.target)
        try rig.environment.launchInstalled()
        return try await relaunchInstalled(rig)
    }

    // runtime-inspect carries the install attestation only when asked; it
    // describes an authority install, reports the legacy path as
    // unprotected with its reason, and is checked for every reply.
    func testRuntimeInspectAttestsTheInstallWhenAskedAndNeverFromACache() async throws {
        let rig = try await componentRig()
        let controller = rig.make(nil)
        let proofs = rig.driver.proofs
        let ask = RuntimeCoordinationCall(action: "runtime-inspect", purpose: RuntimeHelperAttestation.purpose)

        let plain = try await controller.coordinateRuntime(
            .init(action: "runtime-inspect"), identity: proofs.identity, peer: proofs.peer)
        XCTAssertNil(plain.attestation)
        let plainJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(plainJSON["attestation"], "absent, not null, for a strict decoder")

        let authorityReply = try await controller.coordinateRuntime(ask, identity: proofs.identity, peer: proofs.peer)
        let authority = try XCTUnwrap(authorityReply.attestation)
        XCTAssertEqual(authority.helperIdentifier, IsolatedRuntimePolicy.helperIdentifier)
        XCTAssertEqual(authority.helperVersion, rig.environment.runningVersion)
        XCTAssertEqual(authority.componentProtocol, RuntimeComponentManifest.protocolVersion)
        XCTAssertEqual(authority.helperService, IsolatedRuntimePolicy.authorityServiceName)
        XCTAssertEqual(authority.componentProtection, "protected")
        XCTAssertEqual(authority.authorityDefinitionSHA256, RuntimeAuthority.definitionSHA256)
        XCTAssertTrue(authority.spawnConstraint)
        XCTAssertTrue(authority.installSealed)
        XCTAssertEqual(authority.legacyJob, .retired)
        XCTAssertNotNil(authority.nativeState)
        let first = try XCTUnwrap(ISO8601DateFormatter.fractional.date(from: authority.checkedAt))
        XCTAssertLessThan(abs(first.timeIntervalSinceNow), 60)

        // The legacy path: checked again for this reply, never a cached answer.
        let reason =
            "the helper runs from /Applications/Micropod Runtime Setup.app, not the root-only authority program"
        rig.environment.setInstallFacts(
            .init(
                protection: .unprotected(reason), authority: false, spawnConstraint: false, installSealed: false,
                legacyJob: .loaded))
        try await Task.sleep(for: .milliseconds(5))
        let legacyReply = try await controller.coordinateRuntime(ask, identity: proofs.identity, peer: proofs.peer)
        let legacy = try XCTUnwrap(legacyReply.attestation)
        XCTAssertEqual(legacy.componentProtection, "unprotected: " + reason)
        XCTAssertEqual(legacy.helperService, IsolatedRuntimePolicy.serviceName)
        XCTAssertFalse(legacy.spawnConstraint)
        XCTAssertFalse(legacy.installSealed)
        XCTAssertEqual(legacy.legacyJob, .loaded)
        let second = try XCTUnwrap(ISO8601DateFormatter.fractional.date(from: legacy.checkedAt))
        XCTAssertGreaterThan(second, first)
        // Status follows the newest check.
        let status = try await controller.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(status.componentProtection, "unprotected: " + reason)

        for purpose in ["session", "attestations", ""] {
            do {
                _ = try await controller.coordinateRuntime(
                    .init(action: "runtime-inspect", purpose: purpose), identity: proofs.identity, peer: proofs.peer)
                XCTFail("purpose \(purpose) was accepted")
            } catch {}
        }
    }

    // One update: the helper swap takes no fence and drains nothing; the new
    // helper then restarts the runtime through the ordinary signed handoff.
    func testComponentUpdateSwapsTheHelperThenRestartsTheRuntimeUnderTheDrain() async throws {
        let rig = try await componentRig()
        let (beforeNative, beforeHistory, _) = await rig.driver.snapshot()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "completed", summary.reason ?? "")
        XCTAssertEqual(summary.targetVersion, "0.13.10")
        let (native, history, gates) = await rig.driver.snapshot()
        XCTAssertEqual(
            Array(history.dropFirst(beforeHistory.count)),
            ["qualify", "drain", "prepare", "begin", "verify", "complete"])
        XCTAssertEqual(gates["begin"], true)
        XCTAssertEqual(native.filter { $0 == .stop }.count, beforeNative.filter { $0 == .stop }.count + 1)
        XCTAssertEqual(native.filter { $0 == .start }.count, beforeNative.filter { $0 == .start }.count + 1)
        let status = try await new.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(status.operation, summary.runtimeOperation)
        XCTAssertEqual(status.action, .restart, "On the wire it is an ordinary restart")
        XCTAssertFalse(RuntimeAdmission(root: rig.root.appendingPathComponent("admission")).isClosed)
        let persisted = try String(contentsOf: rig.root.appendingPathComponent("operation.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("componentUpdate"), "operation.json stays readable by older helpers")
    }

    // A coordinator that refuses the restart's first drain before recording
    // it (the 2026-11-18 deadlock) settles the update: the helper stays
    // updated, the runtime is unchanged, nothing waits in recovery, and the
    // next request restarts only the runtime.
    func testCoordinatorRefusalSettlesTheUpdateAndARetryFinishesIt() async throws {
        let rig = try await componentRig()
        await rig.driver.answerNotRecorded(["drain"])
        let (beforeNative, _, _) = await rig.driver.snapshot()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "helperUpdated", summary.reason ?? "")
        let status = try await new.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertNotEqual(status.phase, "recoveryRequired")
        XCTAssertEqual(status.runtimeRigAttempted, false)
        XCTAssertFalse(RuntimeAdmission(root: rig.root.appendingPathComponent("admission")).isClosed)
        let (native, _, _) = await rig.driver.snapshot()
        XCTAssertEqual(native.filter { $0 == .stop }, beforeNative.filter { $0 == .stop }, "Nothing was stopped")

        await rig.driver.answerNotRecorded([])
        let retry = UUID()
        _ = try await new.submit(.init(operation: retry, action: .update), ownerUID: getuid())
        let finished = try await componentOutcome(new, retry)
        XCTAssertEqual(finished.phase, "completed", finished.reason ?? "")
        XCTAssertEqual(finished.sourceVersion, "0.13.10", "Only the runtime followed; the helper was not swapped again")
        XCTAssertEqual(rig.environment.copies, 3, "The retry copied only the installed authority, to stage from")
    }

    // The restart's completion reply is lost: the restart waits for
    // verification as any restart does, and the update follows its recovery
    // instead of being replayed.
    func testLostRestartCompletionIsRecoveredAndTheUpdateFollows() async throws {
        let rig = try await componentRig()
        await rig.driver.loseOneCompletion()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        var status = try await terminal(new)
        XCTAssertEqual(status.phase, "recoveryRequired", status.error ?? "")
        XCTAssertEqual(status.componentUpdate?.phase, "restarting")
        _ = try await new.submit(.init(action: .verify), ownerUID: getuid())
        status = try await terminal(new)
        XCTAssertEqual(status.phase, "completed", status.error ?? "")
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "completed", summary.reason ?? "")
        let (native, _, _) = await rig.driver.snapshot()
        XCTAssertEqual(native.filter { $0 == .start }.count, 2, "The start was never replayed")
    }

    // A target that cannot come up after `begin`: before, no release fit it and
    // the rig waited in recovery forever. `recover` now releases the restart
    // as stopped with intake paused, the update settles, and `--rollback`
    // brings back the previous helper, whose explicit start resumes the rig.
    func testATargetThatCannotStartIsReleasedStoppedAndARollbackStartsThePreviousRuntime() async throws {
        let rig = try await componentRig()
        await rig.driver.failNextStart()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        var status = try await terminal(new)
        XCTAssertEqual(status.phase, "recoveryRequired", status.error ?? "")
        _ = try await new.submit(.init(action: .verify), ownerUID: getuid())
        status = try await terminal(new)
        XCTAssertEqual(status.phase, "failed", status.error ?? "")
        XCTAssertEqual(status.runtimeReleasedStopped, true)
        XCTAssertEqual(status.nativeState, "stopped")
        XCTAssertEqual(status.runtimeRigAttempted, false, "Nothing is left held")
        let kind = await rig.driver.kind
        XCTAssertEqual(kind, "stopped", "Released as stopped: Cuttlefish keeps intake paused")
        XCTAssertFalse(RuntimeAdmission(root: rig.root.appendingPathComponent("admission")).isClosed)
        let settled = try await componentOutcome(new, operation)
        XCTAssertEqual(settled.phase, "helperUpdated", settled.reason ?? "")

        let recorder = RelaunchRecorder()
        let current = rig.make(recorder)
        let back = UUID()
        _ = try await current.submit(.init(operation: back, action: .rollback), ownerUID: getuid())
        for _ in 0..<400 where recorder.relaunches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try rig.environment.inspect(rig.environment.installedBundle), ComponentEnvironmentFixture.source)
        let previous = try await relaunchInstalled(rig)
        let rolled = try await componentOutcome(previous, back)
        XCTAssertEqual(rolled.phase, "rolledBack", rolled.reason ?? "")
        status = try await previous.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(status.action, .start, "Only an explicit start resumes a stopped release")
        XCTAssertEqual(status.nativeState, "nativeReady")
        XCTAssertEqual(status.runtimeReleasedStopped, nil)
    }

    // H3, the deadlock replayed: an agent that does not qualify the build
    // refuses the first drain with phase "refused" before its coordinator
    // records it. That settles the restart as failed with nothing held,
    // instead of recoveryRequired and an abort the agent also refuses.
    func testAnUnqualifiedBuildRefusedAtTheDrainSettlesInsteadOfDeadlocking() async throws {
        let rig = try await componentRig()
        await rig.driver.refuseNextDrainUnprocessed(
            "Runtime version or package digest differs from the version this agent pins")
        let (beforeNative, beforeHistory, _) = await rig.driver.snapshot()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "helperUpdated", summary.reason ?? "")
        let status = try await new.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(status.phase, "failed", status.error ?? "")
        XCTAssertEqual(status.runtimeRigAttempted, false, "No handoff is retained")
        XCTAssertFalse(RuntimeAdmission(root: rig.root.appendingPathComponent("admission")).isClosed)
        let (native, history, _) = await rig.driver.snapshot()
        XCTAssertEqual(native.filter { $0 == .stop }, beforeNative.filter { $0 == .stop })
        XCTAssertFalse(history.dropFirst(beforeHistory.count).contains("abort"), "No abort is needed")
    }

    // H3: with the pre-drain check, a coordinator that does not qualify the
    // build is never asked to drain at all.
    func testAnUnqualifiedBuildIsNeverDrained() async throws {
        let rig = try await componentRig()
        await rig.driver.setUnqualified(true)
        let (_, beforeHistory, _) = await rig.driver.snapshot()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "helperUpdated", summary.reason ?? "")
        let (_, history, _) = await rig.driver.snapshot()
        XCTAssertEqual(Array(history.dropFirst(beforeHistory.count)), ["qualify"])
        let status = try await new.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertTrue(status.error?.contains("does not qualify") == true, status.error ?? "")
    }

    // H2: staging that installs other bytes than the verified target is
    // refused before anything is drained.
    func testStagingOtherBytesThanTheVerifiedTargetIsRefusedBeforeTheDrain() async throws {
        let rig = try await componentRig()
        await rig.driver.setTamperStaging()
        let (_, beforeHistory, _) = await rig.driver.snapshot()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "helperUpdated", summary.reason ?? "")
        let (_, history, _) = await rig.driver.snapshot()
        XCTAssertFalse(history.dropFirst(beforeHistory.count).contains("drain"))
    }

    // M7: a rollback after the runtime moved restores the previous runtime
    // first, with the current helper, under the drain; then swaps the helper
    // back. The previous helper finds its own runtime and restarts nothing.
    func testARollbackRestoresThePreviousRuntimeThenThePreviousHelper() async throws {
        let rig = try await componentRig()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let outcome = try await componentOutcome(new, operation)
        XCTAssertEqual(outcome.phase, "completed")
        let (beforeNative, beforeHistory, _) = await rig.driver.snapshot()

        let recorder = RelaunchRecorder()
        let current = rig.make(recorder)
        let back = UUID()
        _ = try await current.submit(.init(operation: back, action: .rollback), ownerUID: getuid())
        for _ in 0..<400 where recorder.relaunches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(recorder.relaunches, 1)
        let restored = await rig.driver.restoredRuntimes()
        XCTAssertEqual(restored.map(\.workerSHA256), [ComponentEnvironmentFixture.source.helperSHA256])
        let (_, history, _) = await rig.driver.snapshot()
        XCTAssertEqual(
            Array(history.dropFirst(beforeHistory.count)),
            ["qualify", "drain", "prepare", "begin", "verify", "complete"])
        XCTAssertEqual(try rig.environment.inspect(rig.environment.installedBundle), ComponentEnvironmentFixture.source)
        XCTAssertEqual(rig.environment.api.active?.executableSHA256, ComponentEnvironmentFixture.source.apiSHA256)

        let previous = try await relaunchInstalled(rig)
        let rolled = try await componentOutcome(previous, back)
        XCTAssertEqual(rolled.phase, "rolledBack", rolled.reason ?? "")
        let (native, _, _) = await rig.driver.snapshot()
        XCTAssertEqual(
            native.filter { $0 == .start }.count, beforeNative.filter { $0 == .start }.count + 1,
            "One restart: the restore. The previous helper restarted nothing")
    }

    // M9: a runtime the operator stopped stays stopped across an update.
    func testAnUpdateDoesNotStartARuntimeTheOperatorStopped() async throws {
        let rig = try await componentRig()
        let first = rig.make(nil)
        _ = try await first.submit(.init(action: .stop), ownerUID: getuid())
        let settledfirst = try await terminal(first)
        XCTAssertEqual(settledfirst.phase, "completed")
        let (beforeNative, _, _) = await rig.driver.snapshot()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "helperUpdated", summary.reason ?? "")
        XCTAssertTrue(summary.reason?.contains("stopped deliberately") == true, summary.reason ?? "")
        let (native, _, _) = await rig.driver.snapshot()
        XCTAssertEqual(native.filter { $0 == .start }.count, beforeNative.filter { $0 == .start }.count)
    }

    // M6: an undecodable component journal blocks only an update; every
    // lifecycle action, recovery included, still runs.
    func testAnUnreadableComponentJournalBlocksOnlyUpdates() async throws {
        let rig = try await componentRig()
        try FileManager.default.createDirectory(
            at: rig.updater.journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: rig.updater.journal)
        let controller = rig.make(nil)
        _ = try await controller.submit(.init(action: .restart), ownerUID: getuid())
        let settledcontroller = try await terminal(controller)
        XCTAssertEqual(settledcontroller.phase, "completed")
        do {
            _ = try await controller.submit(.init(action: .update), ownerUID: getuid())
            XCTFail("An update ran over an unreadable journal")
        } catch {}
    }

    // N1(b): a helper that is not the exact root-owned authority reports it
    // in status and refuses every update.
    func testAnUnprotectedHelperReportsItAndRefusesUpdates() async throws {
        let rig = try await componentRig()
        rig.environment.setProtection(.unprotected("the helper runs from /Applications"))
        let helper = rig.make(nil)
        _ = await helper.continueComponentUpdate()
        let status = try await helper.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(status.componentProtection, "unprotected: the helper runs from /Applications")
        do {
            _ = try await helper.submit(.init(action: .update), ownerUID: getuid())
            XCTFail("An unprotected helper updated itself")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unprotected"), error.localizedDescription)
        }
        XCTAssertEqual(rig.environment.copies, 0)
    }

    // MARK: Forced updates (`sudo micropod runtime update --force`)

    private static let unprotected = "launchd's live authority job could not be read"

    // Requirement 2: force is honoured only for a root peer. Any other peer
    // (the owner's CLI, the desktop app) is refused before anything is read,
    // whatever it asks for and whether or not the helper is protected.
    func testAForcedRequestFromANonRootPeerIsRefused() async throws {
        let rig = try await componentRig()
        let helper = rig.make(nil)
        for protection in [RuntimeAuthority.Protection.unprotected(Self.unprotected), .ok] {
            rig.environment.setProtection(protection)
            for action in [IsolatedRuntimeAction.update, .rollback, .status, .restart] {
                do {
                    _ = try await helper.submit(.init(action: action, force: true), ownerUID: getuid())
                    XCTFail("A non-root peer forced \(action)")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Only root"), error.localizedDescription)
                }
            }
            // `force: false` is a request for force too: only absence is not.
            do {
                _ = try await helper.submit(.init(action: .update, force: false), ownerUID: getuid())
                XCTFail("A non-root peer sent force")
            } catch {}
        }
        XCTAssertEqual(rig.environment.copies, 0)
        XCTAssertNil(try rig.updater.read())
        XCTAssertNil(rig.updater.lastForced())
        // Unforced, the owner still gets the ordinary refusal.
        rig.environment.setProtection(.unprotected(Self.unprotected))
        do {
            _ = try await helper.submit(.init(action: .update), ownerUID: getuid())
            XCTFail("An unprotected helper updated itself")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unprotected"), error.localizedDescription)
        }
    }

    // Requirement 2: the Cuttlefish agent reaches the helper only through
    // the coordination socket, which has no update of any kind to force.
    func testTheCoordinationSocketHasNoWayToForceAnUpdate() async throws {
        let rig = try await componentRig()
        rig.environment.setProtection(.unprotected(Self.unprotected))
        let controller = rig.make(nil)
        let proofs = rig.driver.proofs
        for call in [
            RuntimeCoordinationCall(action: "runtime-update", purpose: "force"),
            RuntimeCoordinationCall(action: "update"), RuntimeCoordinationCall(action: "runtime-force-update"),
        ] {
            do {
                _ = try await controller.coordinateRuntime(call, identity: proofs.identity, peer: proofs.peer)
                XCTFail("\(call.action) was accepted")
            } catch {}
        }
        XCTAssertEqual(rig.environment.copies, 0)
        XCTAssertNil(rig.updater.lastForced())
    }

    // A root peer may read status and force an update, nothing else; an
    // unforced update is the owner's to ask for.
    func testARootPeerMayOnlyReadStatusOrForceAnUpdate() async throws {
        let rig = try await componentRig()
        let helper = rig.make(nil)
        let status = try await helper.submit(.init(action: .status), ownerUID: 0)
        XCTAssertEqual(status.identity?.ownerUID, getuid())
        for request in [
            IsolatedRuntimeRequest(action: .update), .init(action: .rollback), .init(action: .start),
            .init(action: .stop), .init(action: .restart), .init(action: .install), .init(action: .verify),
            .init(action: .cancel), .init(action: .start, force: true), .init(action: .status, force: true),
        ] {
            do {
                _ = try await helper.submit(request, ownerUID: 0)
                XCTFail("Root sent \(request.action) (force \(String(describing: request.force)))")
            } catch {}
        }
        XCTAssertEqual(rig.environment.copies, 0)
        let after = try await helper.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(after.phase, "completed", "Nothing root sent started an operation")
    }

    // Requirement 6: an unprotected helper with a root peer's force updates
    // exactly as an ordinary update would (swap, relaunch, the drained
    // restart), and every report says it was forced, and over what.
    func testRootForcesAnUpdateOverAFailedProtectionCheckAndItIsRecorded() async throws {
        let rig = try await componentRig()
        rig.environment.setProtection(.unprotected(Self.unprotected))
        let (_, beforeHistory, _) = await rig.driver.snapshot()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation, asRoot: true)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "completed", summary.reason ?? "")
        XCTAssertEqual(summary.forced, true)
        XCTAssertEqual(summary.forcedOver, "unprotected: " + Self.unprotected)
        let (_, history, _) = await rig.driver.snapshot()
        XCTAssertEqual(
            Array(history.dropFirst(beforeHistory.count)),
            ["qualify", "drain", "prepare", "begin", "verify", "complete"], "The runtime follows under the drain")

        let status = try await new.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(status.componentProtection, "unprotected: " + Self.unprotected, "Force repairs nothing")
        let forced = try XCTUnwrap(status.forcedComponentUpdate)
        XCTAssertEqual(forced.operation, operation)
        XCTAssertEqual(forced.overridden, "unprotected: " + Self.unprotected)
        XCTAssertTrue(forced.line.contains("was forced over \"unprotected: \(Self.unprotected)\""), forced.line)
        XCTAssertEqual(try rig.updater.read()?.ownerUID, getuid(), "Root acts for the runtime's recorded owner")
        XCTAssertEqual(status.ownerUID, getuid())
        XCTAssertTrue(rig.environment.faults.contains { $0.hasPrefix("FORCED") && $0.contains(Self.unprotected) })
        let persisted = try String(contentsOf: rig.root.appendingPathComponent("operation.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("forced"), "operation.json stays readable by older helpers")

        // Later ordinary updates never clear the mark.
        rig.environment.setProtection(.ok)
        let retry = UUID()
        _ = try await new.submit(.init(operation: retry, action: .update), ownerUID: getuid())
        let ordinary = try await componentOutcome(new, retry)
        XCTAssertNil(ordinary.forced)
        let later = try await new.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(later.forcedComponentUpdate, forced)
    }

    // Requirement 6: a root peer's force on a protected helper overrides
    // nothing: an ordinary update, with no forced record anywhere.
    func testRootForceOnAProtectedHelperIsAnOrdinaryUpdate() async throws {
        let rig = try await componentRig()
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation, asRoot: true)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "completed", summary.reason ?? "")
        XCTAssertNil(summary.forced)
        XCTAssertNil(summary.forcedOver)
        let status = try await new.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(status.componentProtection, "protected")
        XCTAssertNil(status.forcedComponentUpdate)
        XCTAssertNil(rig.updater.lastForced())
        XCTAssertFalse(rig.environment.faults.contains { $0.hasPrefix("FORCED") })
    }

    // Gamma-128's 167 old-format receipts from the still-running API: the
    // update's restart retires them as any restart does, instead of refusing.
    func testStaleAdmissionReceiptsDoNotBlockTheComponentRestart() async throws {
        let rig = try await componentRig()
        struct OldReceipt: Encodable {
            let operation: UUID
            let route: String
            let pid: Int32
        }
        let pending = rig.root.appendingPathComponent("admission/pending")
        for route in ["native.start", "native.start", "native.create"] {
            let id = UUID()
            try RuntimeDurableFile.write(
                OldReceipt(operation: id, route: route, pid: getpid()),
                to: pending.appendingPathComponent(id.uuidString + ".json"))
        }
        let operation = UUID()
        let new = try await swapAndRelaunch(rig, operation: operation)
        let summary = try await componentOutcome(new, operation)
        XCTAssertEqual(summary.phase, "completed", summary.reason ?? "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pending.path), [])
    }

    // The new helper was killed while staging its runtime components, before
    // any generation, drain or fence: the next launch settles that restart as
    // cancelled instead of waiting in recovery, and the update follows it.
    func testHelperKilledWhileStagingTheRuntimeSettles() async throws {
        let rig = try await componentRig()
        let operation = UUID()
        let first = try await swapAndRelaunch(rig, operation: operation)
        _ = try await componentOutcome(first, operation)
        // Rewrite what a kill during `stagingComponents` leaves behind.
        var record = try XCTUnwrap(rig.updater.read())
        let runtime = UUID()
        if record.phase != .restarting { try rig.updater.beginRuntime(&record, operation: runtime, previous: nil) }
        let journal = rig.root.appendingPathComponent("operation.json")
        var state = try JSONDecoder().decode(
            IsolatedRuntimeStatus.self, from: RuntimeDurableFile.read(journal, maximumBytes: 65536))
        state.operation = record.runtimeOperation
        state.action = .restart
        state.phase = "stagingComponents"
        state.localGeneration = nil
        state.runtimeRigAttempted = false
        state.runtimeActionStarted = false
        state.actionVerified = false
        try RuntimeDurableFile.write(state, to: journal)

        let relaunched = rig.make(nil)
        let settled = try await relaunched.submit(.init(action: .status), ownerUID: getuid())
        XCTAssertEqual(settled.phase, "cancelled", settled.error ?? "")
        XCTAssertEqual(settled.componentUpdate?.phase, "helperUpdated")
        XCTAssertFalse(RuntimeAdmission(root: rig.root.appendingPathComponent("admission")).isClosed)
    }
}

extension ISO8601DateFormatter {
    /// RFC 3339 with fractional seconds, as the attestation's `checkedAt`.
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
