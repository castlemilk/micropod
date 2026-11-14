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
    private func sign(_ f: Fixture, challenge: String, peer: RuntimeProcessBirth? = nil, generation: Int64 = 7) throws
        -> String
    {
        func encode(_ bytes: Data) -> String {
            bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let birth = try JSONSerialization.jsonObject(with: JSONEncoder().encode(peer ?? f.peer))
        let claims: [String: Any] = [
            "iss": "https://api.cuttlefish.sh", "aud": "micropod-runtime-coordination", "sub": "runner:rig-a",
            "iat": 1_700_000_000, "nbf": 1_699_999_995, "exp": 1_700_000_120, "jti": UUID().uuidString,
            "schemaVersion": "micropod-runtime-proof-v1", "purpose": "enrollment",
            "scope": "micropod-dedicated-runtime",
            "peer": birth, "sessionGeneration": generation, "challenge": challenge,
            "enrollment": [
                "schemaVersion": "micropod-runtime-coordination-v1", "scope": "micropod-dedicated-runtime",
                "resourceId": f.resource, "organizationId": "org-a", "runnerId": "rig-a", "revision": 1,
                "enabled": true,
                "binding": [
                    "instance": f.identity.instance.uuidString, "hostKey": String(repeating: "b", count: 64),
                    "ownerUID": f.identity.ownerUID, "serviceUID": 400, "serviceGID": 401,
                    "accountGUID": f.identity.accountGUID.uuidString, "groupGUID": f.identity.groupGUID.uuidString,
                ],
            ],
        ]
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
        let live = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        XCTAssertThrowsError(
            try authority.enroll(
                sign(f, challenge: live, generation: 8), challenge: live, identity: f.identity, peer: f.peer,
                now: f.now, priorProcessExited: { _ in false }))
        let exited = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "enrollment")
        _ = try authority.enroll(
            sign(f, challenge: exited, generation: 8), challenge: exited, identity: f.identity, peer: f.peer,
            now: f.now, priorProcessExited: { _ in true })
        XCTAssertEqual(try authority.read(identity: f.identity)?.sessionGeneration, 8)
        let beforeRestart = try authority.issueChallenge(identity: f.identity, peer: f.peer, purpose: "session")
        var restarted = RuntimeCoordinatorAuthority(fileURL: f.file, ownerUID: getuid(), verifier: f.verifier)
        XCTAssertThrowsError(
            try restarted.authorizeSession(
                sign(f, challenge: beforeRestart, generation: 8), challenge: beforeRestart, identity: f.identity,
                peer: f.peer, now: f.now))
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
}
