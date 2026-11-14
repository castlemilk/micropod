import Foundation
import Security
import XCTest

@testable import MicropodCore

final class RuntimeCoordinationProofTests: XCTestCase {
    private struct Fixture {
        let key: SecKey
        let verifier: RuntimeCoordinationProofVerifier
        let identity: IsolatedRuntimeIdentity
        let peer: RuntimeProcessBirth
        let now: Date
        let challenge: String
        let claims: [String: Any]
    }

    private func fixture() throws -> Fixture {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let identity = IsolatedRuntimeIdentity(
            instance: UUID(), ownerUID: 501, serviceUID: 400, serviceGID: 401, accountGUID: UUID(), groupGUID: UUID())
        let peerFields: [String: Any] = [
            "pid": 123, "uid": 501, "seconds": 1_700_000_000, "microseconds": 123456,
            "bootSession": UUID().uuidString,
        ]
        let peer = try JSONDecoder().decode(
            RuntimeProcessBirth.self, from: JSONSerialization.data(withJSONObject: peerFields))
        let timestamp: Int64 = 1_700_000_010
        let challenge = String(repeating: "a", count: 64)
        let claims: [String: Any] = [
            "iss": "https://api.cuttlefish.sh", "aud": "micropod-runtime-coordination", "sub": "runner:rig-a",
            "iat": timestamp, "nbf": timestamp - 5, "exp": timestamp + 120, "jti": UUID().uuidString,
            "schemaVersion": "micropod-runtime-proof-v1", "purpose": "enrollment",
            "scope": "micropod-dedicated-runtime", "peer": peerFields,
            "sessionGeneration": 7, "challenge": challenge,
            "enrollment": [
                "schemaVersion": "micropod-runtime-coordination-v1", "scope": "micropod-dedicated-runtime",
                "resourceId": "mrt-" + UUID().uuidString.lowercased(), "organizationId": "org-a", "runnerId": "rig-a",
                "revision": 1, "enabled": true,
                "binding": [
                    "instance": identity.instance.uuidString, "hostKey": String(repeating: "b", count: 64),
                    "ownerUID": 501, "serviceUID": 400, "serviceGID": 401,
                    "accountGUID": identity.accountGUID.uuidString, "groupGUID": identity.groupGUID.uuidString,
                ],
            ],
        ]
        return Fixture(
            key: key, verifier: .init(issuer: "https://api.cuttlefish.sh", keyID: "test-key", publicKeyDER: der),
            identity: identity, peer: peer, now: Date(timeIntervalSince1970: Double(timestamp)), challenge: challenge,
            claims: claims)
    }

    private func sign(_ claims: [String: Any], fixture: Fixture, header: [String: Any]? = nil) throws -> String {
        func encode(_ bytes: Data) -> String {
            bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = header ?? ["alg": "RS256", "typ": "micropod-runtime-proof+jwt", "kid": "test-key"]
        let input =
            try encode(JSONSerialization.data(withJSONObject: header, options: .sortedKeys)) + "."
            + encode(JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let signature =
            try XCTUnwrap(
                SecKeyCreateSignature(
                    fixture.key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
        return input + "." + encode(signature)
    }

    private func verify(_ token: String, _ f: Fixture, challenge: String? = nil, now: Date? = nil) throws
        -> RuntimeCoordinationEnrollmentProof
    {
        try f.verifier.verifyEnrollment(
            token, identity: f.identity, peer: f.peer, challenge: challenge ?? f.challenge, now: now ?? f.now)
    }

    func testAcceptsExactRS256EnrollmentBoundToPrivateAccountAndKernelPeer() throws {
        let f = try fixture()
        let token = try sign(f.claims, fixture: f)
        let proof = try verify(token, f)
        XCTAssertEqual(proof.enrollment.binding.instance, f.identity.instance.uuidString)
        XCTAssertEqual(proof.peer, f.peer)
        XCTAssertEqual(proof.sessionGeneration, 7)
        XCTAssertEqual(proof.challenge, f.challenge)
        XCTAssertNoThrow(try verify(token, f, now: f.now.addingTimeInterval(-5)))
        XCTAssertThrowsError(try verify(token, f, now: f.now.addingTimeInterval(-5.001)))
        XCTAssertNoThrow(try verify(token, f, now: f.now.addingTimeInterval(119.999)))
        XCTAssertThrowsError(try verify(token, f, now: f.now.addingTimeInterval(120)))
        XCTAssertThrowsError(try verify(token, f, challenge: String(repeating: "c", count: 64)))
        XCTAssertThrowsError(try verify(token, f, challenge: ""))
        // A caller-selected key or fake local control plane cannot enter the
        // production helper's compiled trust policy.
        XCTAssertThrowsError(
            try RuntimeCoordinationProofVerifier().verifyEnrollment(
                token, identity: f.identity, peer: f.peer, challenge: f.challenge, now: f.now))
    }

    func testRefusesValidlySignedTokensFromOtherProtocolsAndChangedBindings() throws {
        let f = try fixture()
        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("foreign issuer", { $0["iss"] = "http://localhost:1234" }),
            ("workflow audience", { $0["aud"] = "pipeline" }),
            ("subject", { $0["sub"] = "runner:other" }),
            ("schema", { $0["schemaVersion"] = "pipeline-oidc-v1" }),
            ("purpose", { $0["purpose"] = "maintenance" }),
            ("host scope", { $0["scope"] = "desktop-host-management-v1" }),
            (
                "future",
                {
                    $0["iat"] = 1_700_000_020
                    $0["nbf"] = 1_700_000_015
                    $0["exp"] = 1_700_000_140
                }
            ),
            ("unbounded expiry", { $0["exp"] = Int64.max }),
            ("integer overflow", { $0["iat"] = Int64.max }),
            ("missing token id", { $0["jti"] = "" }),
            ("missing session", { $0["sessionGeneration"] = 0 }),
            ("challenge", { $0["challenge"] = String(repeating: "c", count: 64) }),
            (
                "revoked",
                { claims in
                    var e = claims["enrollment"] as! [String: Any]
                    e["enabled"] = false
                    claims["enrollment"] = e
                }
            ),
            (
                "host resource",
                { claims in
                    var e = claims["enrollment"] as! [String: Any]
                    e["resourceId"] = "desktop-rig-a"
                    claims["enrollment"] = e
                }
            ),
            (
                "nil resource",
                { claims in
                    var e = claims["enrollment"] as! [String: Any]
                    e["resourceId"] = "mrt-00000000-0000-0000-0000-000000000000"
                    claims["enrollment"] = e
                }
            ),
            (
                "unapproved revision",
                { claims in
                    var e = claims["enrollment"] as! [String: Any]
                    e["revision"] = 0
                    claims["enrollment"] = e
                }
            ),
        ]
        for (name, edit) in edits {
            var claims = f.claims
            edit(&claims)
            XCTAssertThrowsError(try verify(sign(claims, fixture: f), f), name)
        }
        for field in ["instance", "hostKey", "ownerUID", "serviceUID", "serviceGID", "accountGUID", "groupGUID"] {
            var claims = f.claims
            var enrollment = claims["enrollment"] as! [String: Any]
            var binding = enrollment["binding"] as! [String: Any]
            binding[field] = field.hasSuffix("UID") || field == "serviceGID" ? 502 : "unconfirmed"
            enrollment["binding"] = binding
            claims["enrollment"] = enrollment
            XCTAssertThrowsError(try verify(sign(claims, fixture: f), f), field)
        }
        for field in ["pid", "uid", "seconds", "microseconds", "bootSession"] {
            var claims = f.claims
            var peer = claims["peer"] as! [String: Any]
            peer[field] = field == "bootSession" ? UUID().uuidString : 999
            claims["peer"] = peer
            XCTAssertThrowsError(try verify(sign(claims, fixture: f), f), field)
        }
    }

    func testRefusesWrongSignatureAlgorithmKeyAndMalformedEnvelope() throws {
        let f = try fixture()
        for header in [
            ["alg": "none", "typ": "micropod-runtime-proof+jwt", "kid": "test-key"],
            ["alg": "HS256", "typ": "micropod-runtime-proof+jwt", "kid": "test-key"],
            ["alg": "RS256", "typ": "JWT", "kid": "test-key"],
            ["alg": "RS256", "typ": "micropod-runtime-proof+jwt", "kid": "untrusted"],
        ] { XCTAssertThrowsError(try verify(sign(f.claims, fixture: f, header: header), f)) }
        let token = try sign(f.claims, fixture: f)
        let other = try fixture()
        XCTAssertThrowsError(
            try other.verifier.verifyEnrollment(
                token, identity: f.identity, peer: f.peer, challenge: f.challenge, now: f.now))
        let parts = token.split(separator: ".")
        for malformed in [
            "", token + ".extra", " \(token)", token + "=", String(repeating: "a", count: 16385),
            String(parts[0]) + ".e30." + parts[2],
            String(parts[0]) + "." + parts[1] + ".AAAA",
        ] { XCTAssertThrowsError(try verify(malformed, f)) }
    }

    func testMaintenanceProofCannotSubstituteAnEnrollmentOrAnotherOperation() throws {
        let f = try fixture()
        let enrollmentToken = try sign(f.claims, fixture: f)
        let enrollment = try verify(enrollmentToken, f).enrollment
        let operation = try RuntimeCoordinationOperation(
            operation: UUID(), identity: f.identity, action: "stop", localGeneration: 42,
            selection: .init(
                version: AppleRuntimeRelease.supported.version,
                packageSHA256: AppleRuntimeRelease.supported.packageSHA256))
        let op = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as! [String: Any]
        let empty: [String: Any] = [
            "id": "", "runtimeInstance": "", "action": "", "localGeneration": 0,
            "version": "", "packageSHA256": "", "installRoot": "", "targetState": "",
        ]
        let state: [String: Any] = [
            "scope": enrollment.scope, "resourceId": enrollment.resourceId, "revision": enrollment.revision,
            "owner": operation.id, "generation": 1, "closed": true, "operation": op,
            "lastReleasedOwner": "", "lastReleasedGeneration": -1, "lastReleasedRevision": 0,
            "lastReleasedOperation": empty,
        ]
        func maintenance(_ token: String) throws -> RuntimeCoordinationEnrollmentProof {
            try f.verifier.verifyMaintenance(
                token, identity: f.identity, peer: f.peer, challenge: f.challenge, enrollment: enrollment,
                sessionGeneration: 7, operation: operation, resourceGeneration: 1, now: f.now)
        }
        XCTAssertThrowsError(try maintenance(enrollmentToken))
        var claims = f.claims
        claims["purpose"] = "maintenance"
        claims["state"] = state
        let proof = try sign(claims, fixture: f)
        XCTAssertEqual(try maintenance(proof).state?.operation, operation)
        XCTAssertThrowsError(try verify(proof, f))
        for field in ["generation", "owner", "closed", "resourceId", "revision", "scope"] {
            var changed = state
            if field == "generation" || field == "revision" {
                changed[field] = 2
            } else if field == "closed" {
                changed[field] = false
            } else {
                changed[field] = "other"
            }
            claims["state"] = changed
            XCTAssertThrowsError(try maintenance(sign(claims, fixture: f)), field)
        }
        for field in [
            "id", "runtimeInstance", "action", "localGeneration", "version", "packageSHA256", "installRoot",
            "targetState",
        ] {
            var changed = state
            var changedOp = op
            changedOp[field] = field == "localGeneration" ? 43 : "other"
            changed["operation"] = changedOp
            claims["state"] = changed
            XCTAssertThrowsError(try maintenance(sign(claims, fixture: f)), field)
        }
    }
}
