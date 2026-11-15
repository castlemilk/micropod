import Darwin
import Foundation
import Security
import XCTest

@testable import MicropodCore
@testable import MicropodRuntimeHostKit

final class RuntimeCoordinatorAuthorityTests: XCTestCase {
    private struct Fixture {
        let key: SecKey
        let verifier: RuntimeCoordinationProofVerifier
        let identity: IsolatedRuntimeIdentity
        let peer: RuntimeProcessBirth
        let file: URL
        let resource = "mrt-" + UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
    }
    private func fixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "runtime-coordinator-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        let key = try XCTUnwrap(
            SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false,
                ] as CFDictionary, nil))
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil)) as Data
        return Fixture(
            key: key, verifier: .init(issuer: "https://api.cuttlefish.sh", keyID: "fixture", publicKeyDER: der),
            identity: .init(
                instance: UUID(), ownerUID: getuid(), serviceUID: 400, serviceGID: 401, accountGUID: UUID(),
                groupGUID: UUID()),
            peer: try XCTUnwrap(RuntimeProcessBirth.read(getpid())),
            file: dir.appendingPathComponent("runtime-coordinator.json"))
    }
    private func sign(
        _ f: Fixture, challenge: String, peer: RuntimeProcessBirth? = nil, generation: Int64 = 7,
        purpose: String = "enrollment", state: [String: Any]? = nil, revision: Int64 = 1, enabled: Bool = true
    ) throws
        -> String
    {
        func encode(_ bytes: Data) -> String {
            bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let birth = try JSONSerialization.jsonObject(with: JSONEncoder().encode(peer ?? f.peer))
        var claims: [String: Any] = [
            "iss": "https://api.cuttlefish.sh", "aud": "micropod-runtime-coordination", "sub": "runner:rig-a",
            "iat": 1_700_000_000, "nbf": 1_699_999_995, "exp": 1_700_000_120, "jti": UUID().uuidString,
            "schemaVersion": "micropod-runtime-proof-v1", "purpose": purpose,
            "scope": "micropod-dedicated-runtime",
            "peer": birth, "sessionGeneration": generation, "challenge": challenge,
            "enrollment": [
                "schemaVersion": "micropod-runtime-coordination-v1", "scope": "micropod-dedicated-runtime",
                "resourceId": f.resource, "organizationId": "org-a", "runnerId": "rig-a", "revision": revision,
                "enabled": enabled,
                "binding": [
                    "instance": f.identity.instance.uuidString, "hostKey": String(repeating: "b", count: 64),
                    "ownerUID": f.identity.ownerUID, "serviceUID": 400, "serviceGID": 401,
                    "accountGUID": f.identity.accountGUID.uuidString, "groupGUID": f.identity.groupGUID.uuidString,
                ],
            ],
        ]
        claims["state"] = state
        let head = try JSONSerialization.data(withJSONObject: [
            "alg": "RS256", "typ": "micropod-runtime-proof+jwt", "kid": "fixture",
        ])
        let input = try encode(head) + "." + encode(JSONSerialization.data(withJSONObject: claims))
        let sig =
            try XCTUnwrap(
                SecKeyCreateSignature(f.key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil))
            as Data
        return input + "." + encode(sig)
    }
    func testEnrollmentPersistsOnlyMetadataAndSessionsRequireFreshOneUseApproval() throws {
        let f = try fixture()
        var authority = RuntimeCoordinatorAuthority(fileURL: f.file, ownerUID: getuid(), verifier: f.verifier)
        let nonce = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        let token = try sign(f, challenge: nonce)
        let e = try authority.enroll(token, challenge: nonce, identity: f.identity, peer: f.peer, now: f.now)
        XCTAssertEqual(try authority.read(identity: f.identity)?.enrollment, e)
        let persisted = try String(contentsOf: f.file, encoding: .utf8)
        XCTAssertFalse(persisted.contains(token))
        XCTAssertFalse(persisted.contains(nonce))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.file.deletingLastPathComponent().appendingPathComponent("rig.json").path))
        XCTAssertThrowsError(
            try authority.enroll(token, challenge: nonce, identity: f.identity, peer: f.peer, now: f.now))
        let session = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "session")
        let sessionToken = try sign(f, challenge: session)
        XCTAssertEqual(
            try authority.authorizeSession(
                sessionToken, challenge: session, identity: f.identity, peer: f.peer, now: f.now
            ).enrollment, e)
        XCTAssertThrowsError(
            try authority.authorizeSession(
                sessionToken, challenge: session, identity: f.identity, peer: f.peer, now: f.now))
        let wrongPurpose = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        XCTAssertThrowsError(
            try authority.authorizeSession(
                sign(f, challenge: wrongPurpose), challenge: wrongPurpose, identity: f.identity, peer: f.peer,
                now: f.now))
    }
    func testReplacementRequiresPositivePriorProcessExitAndRestartCannotReviveNonce() throws {
        let f = try fixture()
        var authority = RuntimeCoordinatorAuthority(fileURL: f.file, ownerUID: getuid(), verifier: f.verifier)
        let first = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        _ = try authority.enroll(
            sign(f, challenge: first), challenge: first, identity: f.identity, peer: f.peer, now: f.now)
        let rotated = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        _ = try authority.enroll(
            sign(f, challenge: rotated, generation: 8), challenge: rotated, identity: f.identity, peer: f.peer,
            now: f.now,
            priorProcessExited: { _ in
                XCTFail("same process was treated as a replacement")
                return false
            })
        XCTAssertEqual(try authority.read(identity: f.identity)?.sessionGeneration, 8)
        let rollback = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        XCTAssertThrowsError(
            try authority.enroll(
                sign(f, challenge: rollback, generation: 7), challenge: rollback, identity: f.identity, peer: f.peer,
                now: f.now, priorProcessExited: { _ in true }))
        let replacement = RuntimeProcessBirth(
            pid: f.peer.pid + 1, uid: f.peer.uid, seconds: f.peer.seconds + 1,
            microseconds: f.peer.microseconds, bootSession: f.peer.bootSession)
        let oldSession = try authority.issueChallenge(identity: f.identity, peer: replacement, purpose: "enrollment")
        XCTAssertThrowsError(
            try authority.enroll(
                sign(f, challenge: oldSession, peer: replacement, generation: 8), challenge: oldSession,
                identity: f.identity, peer: replacement, now: f.now, priorProcessExited: { _ in true }))
        let live = try authority.issueChallenge(identity: f.identity, peer: replacement, purpose: "enrollment")
        XCTAssertThrowsError(
            try authority.enroll(
                sign(f, challenge: live, peer: replacement, generation: 9), challenge: live,
                identity: f.identity, peer: replacement, now: f.now, priorProcessExited: { _ in false }))
        let exited = try authority.issueChallenge(identity: f.identity, peer: replacement, purpose: "enrollment")
        _ = try authority.enroll(
            sign(f, challenge: exited, peer: replacement, generation: 9), challenge: exited,
            identity: f.identity, peer: replacement, now: f.now, priorProcessExited: { _ in true })
        let beforeRestart = try authority.issueChallenge(identity: f.identity, peer: replacement, purpose: "session")
        var restarted = RuntimeCoordinatorAuthority(fileURL: f.file, ownerUID: getuid(), verifier: f.verifier)
        XCTAssertThrowsError(
            try restarted.authorizeSession(
                sign(f, challenge: beforeRestart, peer: replacement, generation: 9), challenge: beforeRestart,
                identity: f.identity,
                peer: replacement, now: f.now))
    }
    func testNonceLimitsAndExpiryUseMonotonicTime() throws {
        let f = try fixture()
        var tick: UInt64 = 1
        var authority = RuntimeCoordinatorAuthority(
            fileURL: f.file, ownerUID: getuid(), verifier: f.verifier, uptime: { tick })
        var nonces: Set<String> = []
        for _ in 0..<4 {
            nonces.insert(try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment"))
        }
        XCTAssertEqual(nonces.count, 4)
        XCTAssertThrowsError(try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment"))
        tick += 120_000_000_000
        let expired = try XCTUnwrap(nonces.first)
        XCTAssertThrowsError(
            try authority.enroll(
                sign(f, challenge: expired), challenge: expired, identity: f.identity, peer: f.peer, now: f.now))
        XCTAssertNoThrow(try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment"))
        XCTAssertThrowsError(try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "reboot"))
    }

    func testLifecycleNoncesBindTheRootOperationAndCannotBecomeSessionsOrReplayAfterRestart() throws {
        let f = try fixture()
        var authority = RuntimeCoordinatorAuthority(fileURL: f.file, ownerUID: getuid(), verifier: f.verifier)
        let enrollmentNonce = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        let enrollment = try authority.enroll(
            sign(f, challenge: enrollmentNonce), challenge: enrollmentNonce,
            identity: f.identity, peer: f.peer, now: f.now)
        let operation = try RuntimeCoordinationOperation(
            operation: UUID(), identity: f.identity, action: "start", localGeneration: 42,
            selection: .init(
                version: AppleRuntimeRelease.supported.version,
                packageSHA256: AppleRuntimeRelease.supported.packageSHA256, incarnation: UUID()))
        let empty: [String: Any] = [
            "id": "", "runtimeInstance": "", "action": "", "localGeneration": 0,
            "version": "", "packageSHA256": "", "installRoot": "", "targetState": "",
        ]
        let op = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation))
        let state: [String: Any] = [
            "scope": enrollment.scope, "resourceId": enrollment.resourceId, "revision": enrollment.revision,
            "owner": operation.id, "generation": 1, "closed": true, "operation": op,
            "lastReleasedOwner": "", "lastReleasedGeneration": -1, "lastReleasedRevision": 0,
            "lastReleasedKind": "", "lastReleasedOperation": empty,
        ]
        func nonce(_ purpose: String = "maintenance") throws -> String {
            try authority.issueOperationChallenge(
                identity: f.identity, peer: f.peer, operation: operation, purpose: purpose)
        }
        let first = try nonce()
        let token = try sign(f, challenge: first, purpose: "maintenance", state: state)
        let retained = try authority.authorizeMaintenance(
            token, challenge: first, identity: f.identity, peer: f.peer,
            operation: operation, resourceGeneration: 1, now: f.now)
        XCTAssertEqual(retained.enrollment, enrollment)
        XCTAssertEqual(retained.operation, operation)
        XCTAssertEqual(retained.resourceGeneration, 1)
        let encoded = String(decoding: try JSONEncoder().encode(retained), as: UTF8.self)
        XCTAssertFalse(encoded.contains(token))
        XCTAssertFalse(encoded.contains(first))
        XCTAssertThrowsError(
            try authority.authorizeMaintenance(
                token, challenge: first, identity: f.identity, peer: f.peer,
                operation: operation, resourceGeneration: 1, now: f.now))
        let session = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "session")
        XCTAssertThrowsError(
            try authority.authorizeMaintenance(
                sign(f, challenge: session, purpose: "maintenance", state: state), challenge: session,
                identity: f.identity, peer: f.peer, operation: operation, resourceGeneration: 1, now: f.now))
        let maintenance = try nonce()
        XCTAssertThrowsError(
            try authority.authorizeSession(
                sign(f, challenge: maintenance), challenge: maintenance, identity: f.identity, peer: f.peer, now: f.now)
        )
        let wrongGeneration = try nonce()
        XCTAssertThrowsError(
            try authority.authorizeMaintenance(
                sign(f, challenge: wrongGeneration, purpose: "maintenance", state: state), challenge: wrongGeneration,
                identity: f.identity, peer: f.peer, operation: operation, resourceGeneration: 2, now: f.now))
        let different = try RuntimeCoordinationOperation(
            operation: UUID(), identity: f.identity, action: "start", localGeneration: 43,
            selection: .init(
                version: AppleRuntimeRelease.supported.version,
                packageSHA256: AppleRuntimeRelease.supported.packageSHA256))
        let wrongOperation = try nonce()
        XCTAssertThrowsError(
            try authority.authorizeMaintenance(
                sign(f, challenge: wrongOperation, purpose: "maintenance", state: state), challenge: wrongOperation,
                identity: f.identity, peer: f.peer, operation: different, resourceGeneration: 1, now: f.now))
        let beforeRestart = try nonce()
        var restarted = RuntimeCoordinatorAuthority(fileURL: f.file, ownerUID: getuid(), verifier: f.verifier)
        XCTAssertThrowsError(
            try restarted.authorizeMaintenance(
                sign(f, challenge: beforeRestart, purpose: "maintenance", state: state), challenge: beforeRestart,
                identity: f.identity, peer: f.peer, operation: operation, resourceGeneration: 1, now: f.now))

        var released = state
        released["owner"] = ""
        released["operation"] = empty
        released["generation"] = 2
        released["closed"] = true
        released["lastReleasedOwner"] = operation.id
        released["lastReleasedGeneration"] = 1
        released["lastReleasedRevision"] = enrollment.revision
        released["lastReleasedOperation"] = op
        released["lastReleasedKind"] = "cancelled"
        let releaseNonce = try nonce("release-observation")
        let releaseToken = try sign(f, challenge: releaseNonce, purpose: "release-observation", state: released)
        let observed = try authority.observeRelease(
            releaseToken, challenge: releaseNonce, identity: f.identity, peer: f.peer,
            retained: retained, kind: .cancelled, now: f.now)
        XCTAssertTrue(observed.state.closed, "Cancellation must not open intake for an unexecuted start")
        XCTAssertThrowsError(
            try authority.observeRelease(
                releaseToken, challenge: releaseNonce, identity: f.identity, peer: f.peer,
                retained: retained, kind: .cancelled, now: f.now))

        for _ in 0..<100 {
            authority.discardChallenge(try nonce())
        }
        XCTAssertNoThrow(try nonce(), "Ordinary drain polling must not exhaust pending challenges")

        let replacement = RuntimeProcessBirth(
            pid: f.peer.pid + 1, uid: f.peer.uid, seconds: f.peer.seconds + 1,
            microseconds: f.peer.microseconds, bootSession: f.peer.bootSession)
        XCTAssertThrowsError(
            try authority.issueReleaseRebindingChallenge(
                identity: f.identity, peer: replacement, retained: retained, priorProcessExited: { _ in false }))
        released["revision"] = 2
        func recoveryNonce() throws -> String {
            try authority.issueReleaseRebindingChallenge(
                identity: f.identity, peer: replacement, retained: retained, priorProcessExited: { _ in true })
        }
        let stale = try recoveryNonce()
        XCTAssertThrowsError(
            try authority.rebindReleasedPeer(
                sign(
                    f, challenge: stale, peer: replacement, generation: 7, purpose: "release-observation",
                    state: released, revision: 2, enabled: false),
                challenge: stale, identity: f.identity, peer: replacement, retained: retained, kind: .cancelled,
                now: f.now, priorProcessExited: { _ in true }))
        XCTAssertEqual(try authority.read(identity: f.identity)?.peer, f.peer)
        let wrongKind = try recoveryNonce()
        XCTAssertThrowsError(
            try authority.rebindReleasedPeer(
                sign(
                    f, challenge: wrongKind, peer: replacement, generation: 8, purpose: "release-observation",
                    state: released, revision: 2, enabled: false),
                challenge: wrongKind, identity: f.identity, peer: replacement, retained: retained, kind: .running,
                now: f.now, priorProcessExited: { _ in true }))
        XCTAssertEqual(try authority.read(identity: f.identity)?.peer, f.peer)
        let recovery = try recoveryNonce()
        let recoveryProof = try sign(
            f, challenge: recovery, peer: replacement, generation: 8, purpose: "release-observation", state: released,
            revision: 2, enabled: false)
        XCTAssertEqual(
            try authority.rebindReleasedPeer(
                recoveryProof, challenge: recovery, identity: f.identity, peer: replacement, retained: retained,
                kind: .cancelled, now: f.now, priorProcessExited: { _ in true }), enrollment)
        XCTAssertEqual(try authority.read(identity: f.identity)?.peer, replacement)
        XCTAssertEqual(try authority.read(identity: f.identity)?.reconciliationOnly, true)
        XCTAssertThrowsError(
            try authority.rebindReleasedPeer(
                recoveryProof, challenge: recovery, identity: f.identity, peer: replacement, retained: retained,
                kind: .cancelled, now: f.now, priorProcessExited: { _ in true }))
        XCTAssertThrowsError(
            try authority.issueOperationChallenge(
                identity: f.identity, peer: replacement, operation: operation, purpose: "maintenance"))
        let noData = try authority.issueChallenge(identity: f.identity, peer: replacement, purpose: "session")
        XCTAssertThrowsError(
            try authority.authorizeSession(
                sign(f, challenge: noData, peer: replacement, generation: 8), challenge: noData,
                identity: f.identity, peer: replacement, now: f.now))
        let historical = try authority.issueOperationChallenge(
            identity: f.identity, peer: replacement, operation: operation, purpose: "release-observation")
        XCTAssertTrue(
            try authority.observeRelease(
                sign(
                    f, challenge: historical, peer: replacement, generation: 8, purpose: "release-observation",
                    state: released, revision: 2, enabled: false),
                challenge: historical, identity: f.identity, peer: replacement, retained: retained, kind: .cancelled,
                now: f.now
            ).state.closed)
        let renewed = try authority.issueChallenge(identity: f.identity, peer: replacement, purpose: "enrollment")
        _ = try authority.enroll(
            sign(f, challenge: renewed, peer: replacement, generation: 8, revision: 3), challenge: renewed,
            identity: f.identity, peer: replacement, now: f.now)
        XCTAssertNil(try authority.read(identity: f.identity)?.reconciliationOnly)
        let approvedData = try authority.issueChallenge(identity: f.identity, peer: replacement, purpose: "session")
        XCTAssertNoThrow(
            try authority.authorizeSession(
                sign(f, challenge: approvedData, peer: replacement, generation: 8, revision: 3),
                challenge: approvedData,
                identity: f.identity, peer: replacement, now: f.now))

    }
}
