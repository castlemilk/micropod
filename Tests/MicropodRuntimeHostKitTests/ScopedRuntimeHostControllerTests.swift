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
    func corruptOneBegin() { corruptBegin = true }
    func simulateStoppedRuntime() { ready = false }
    func snapshot() -> ([IsolatedRuntimeAction], [String], [String: Bool]) { (nativeActions, history, gateAtPhase) }
    func prepare(ownerUID: UInt32) throws -> PreparedIsolatedRuntime {
        .init(
            identity: proofs.identity,
            receipt: .init(selection: selection, files: AppleRuntimeRelease.payloadSHA256),
            workerSHA256: String(repeating: "d", count: 64))
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
        if request.action == .start { ready = true }
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
