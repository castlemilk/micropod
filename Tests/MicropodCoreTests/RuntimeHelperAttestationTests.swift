import Foundation
import XCTest

@testable import MicropodCore

/// The attestation's wire shape is a contract with Cuttlefish's
/// micropodhost.CoordinationReply: exact field names, bounded strings.
final class RuntimeHelperAttestationTests: XCTestCase {
    private func attestation(protection: String = "protected", state: String? = "running")
        -> RuntimeHelperAttestation
    {
        .init(
            helperIdentifier: IsolatedRuntimePolicy.helperIdentifier, helperVersion: "0.13.10", componentProtocol: 1,
            helperService: IsolatedRuntimePolicy.authorityServiceName, componentProtection: protection,
            authorityDefinitionSHA256: String(repeating: "a", count: 64), spawnConstraint: true, installSealed: true,
            nativeState: state, legacyJob: .retired, checkedAt: Date(timeIntervalSince1970: 1_800_000_000.25))
    }

    func testTheWireShapeIsExact() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(attestation())) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            [
                "helperIdentifier", "helperVersion", "componentProtocol", "helperService", "componentProtection",
                "authorityDefinitionSHA256", "spawnConstraint", "installSealed", "nativeState", "legacyJob",
                "checkedAt",
            ])
        XCTAssertEqual(json["checkedAt"] as? String, "2027-01-15T08:00:00.250Z")
        XCTAssertEqual(json["legacyJob"] as? String, "retired")
        XCTAssertEqual(json["componentProtocol"] as? Int, 1)
        XCTAssertEqual(json["spawnConstraint"] as? Bool, true)
        XCTAssertEqual(
            RuntimeHelperAttestation.LegacyJob.allCases.map(\.rawValue), ["retired", "loaded", "enabled", "unknown"])
        let withoutState = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(attestation(state: nil))) as? [String: Any])
        XCTAssertNil(withoutState["nativeState"], "an unobserved runtime omits nativeState")
    }

    func testEveryStringIsBounded() {
        let long = attestation(
            protection: "unprotected: " + String(repeating: "é", count: 600),
            state: "x" + String(repeating: "y", count: 200))
        XCTAssertLessThanOrEqual(long.componentProtection.utf8.count, 512)
        XCTAssertTrue(long.componentProtection.hasPrefix("unprotected: "))
        XCTAssertLessThanOrEqual(long.nativeState?.utf8.count ?? 0, 64)
        XCTAssertEqual(
            RuntimeHelperAttestation.truncated("ab" + String(repeating: "é", count: 3), toBytes: 5), "abé",
            "cut at a character boundary")
    }
}
