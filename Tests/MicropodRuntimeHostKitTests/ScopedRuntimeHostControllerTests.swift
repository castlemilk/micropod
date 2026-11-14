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

    init() throws {
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
        peer = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        enrollment = .init(
            schemaVersion: RuntimeCoordinationEnrollment.capability, scope: RuntimeCoordinationEnrollment.runtimeScope,
            resourceId: "mrt-" + UUID().uuidString.lowercased(), organizationId: "org-a", runnerId: "rig-a",
            revision: 1, enabled: true,
            binding: .init(
                instance: identity.instance.uuidString, hostKey: String(repeating: "b", count: 64),
                ownerUID: identity.ownerUID, serviceUID: identity.serviceUID, serviceGID: identity.serviceGID,
                accountGUID: identity.accountGUID.uuidString, groupGUID: identity.groupGUID.uuidString))
    }

    func sign(challenge: String, purpose: String, state: [String: Any]? = nil) throws -> String {
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let now = Int64(Date().timeIntervalSince1970)
        var claims: [String: Any] = [
            "iss": "https://api.cuttlefish.sh", "aud": "micropod-runtime-coordination", "sub": "runner:rig-a",
            "iat": now, "nbf": now - 5, "exp": now + 120, "jti": UUID().uuidString,
            "schemaVersion": "micropod-runtime-proof-v1", "purpose": purpose,
            "scope": RuntimeCoordinationEnrollment.runtimeScope, "sessionGeneration": 7, "challenge": challenge,
            "enrollment": try JSONSerialization.jsonObject(with: JSONEncoder().encode(enrollment)),
            "peer": try JSONSerialization.jsonObject(with: JSONEncoder().encode(peer)),
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
    var loseCompletion = false
    var corruptBegin = false
    var nativeActions: [IsolatedRuntimeAction] = []
    var history: [String] = []
    var gateAtPhase: [String: Bool] = [:]
    var generation: Int64 = 0
    var current: RuntimeCoordinationOperation?
    var released: RuntimeCoordinationOperation?
    var kind = ""
    init(proofs: ScopedProofFixture, admissionRoot: URL) {
        self.proofs = proofs
        gate = RuntimeAdmission(root: admissionRoot)
    }
    func setBusy() { busy = true }
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
        XCTAssertEqual(peer, proofs.peer)
        XCTAssertEqual(call.enrollment, proofs.enrollment)
        history.append(call.action)
        gateAtPhase[call.action] = gate.isClosed
        if call.action == "drain", current == nil, released?.id != call.operation.id {
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
            "scope": proofs.enrollment.scope, "resourceId": proofs.enrollment.resourceId, "revision": 1,
            "owner": current?.id ?? "", "generation": generation, "closed": current != nil || kind != "running",
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
        let proof = try proofs.sign(challenge: call.challenge, purpose: purpose, state: state)
        let phase = [
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
    private func fixture() async throws -> (IsolatedRuntimeHostController, ScopedHostDriverFixture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
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
        return (
            IsolatedRuntimeHostController(
                driver: driver, journal: journal, admissionRoot: admissionRoot,
                coordinator: coordinator), driver, root
        )
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
