import Foundation
import XCTest

@testable import MicropodCore

final class RuntimeCoordinationRigClientTests: XCTestCase {
    func testRuntimeReplyCannotSubstituteAHostReceiptAnotherOperationOrAnAPICapability() throws {
        let identity = IsolatedRuntimeIdentity(
            instance: UUID(), ownerUID: 501, serviceUID: 400, serviceGID: 401,
            accountGUID: UUID(), groupGUID: UUID())
        let operation = try RuntimeCoordinationOperation(
            operation: UUID(), identity: identity, action: "start", localGeneration: 42,
            selection: .init(
                version: AppleRuntimeRelease.supported.version,
                packageSHA256: AppleRuntimeRelease.supported.packageSHA256, incarnation: UUID()))
        let base: [String: Any] = [
            "schemaVersion": RuntimeCoordinationEnrollment.capability,
            "scope": RuntimeCoordinationEnrollment.runtimeScope,
            "operation": operation.id, "phase": "draining",
        ]
        func decode(_ fields: [String: Any]) throws -> RuntimeCoordinationRigReply {
            try RuntimeCoordinationRigClient.decodeReply(
                JSONSerialization.data(withJSONObject: fields), operation: operation)
        }
        let waiting = try decode(base)
        XCTAssertNil(waiting.state)
        XCTAssertNil(waiting.maintenanceProof)
        XCTAssertNil(waiting.releaseProof)
        for (field, value) in [
            ("scope", "desktop-host-maintenance"),
            ("schemaVersion", "host-maintenance-v1"),
            ("operation", UUID().uuidString.lowercased()),
            ("phase", "enrolled"),
            ("hostID", "shared-mac"),
            ("session", "must-not-cross-this-protocol"),
            ("maintenanceProof", String(repeating: "x", count: 16385)),
            ("releaseProof", String(repeating: "x", count: 16385)),
            ("reason", String(repeating: "x", count: 1025)),
        ] {
            var fields = base
            fields[field] = value
            XCTAssertThrowsError(try decode(fields), field)
        }
        var mixed = base
        mixed["maintenanceProof"] = "opaque-active-proof"
        mixed["releaseProof"] = "opaque-released-proof"
        XCTAssertThrowsError(try decode(mixed))
    }
}
