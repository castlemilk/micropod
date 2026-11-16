import Foundation
import MicropodCore
import SwiftProtobuf
import XCTest

@testable import MicropodCLI

final class UpdateVerificationTests: XCTestCase {
    func testIdentityComparisonRejectsRecreatedContainersAndUnknownCreationTime() throws {
        var before = Micropod_V1_Container()
        before.id = "verification"
        before.createdAt = "2026-11-16T00:00:00Z"
        before.image = "alpine"
        before.state = "running"
        var after = before
        XCTAssertTrue(try UpdateVerification.sameIdentity(before.jsonUTF8Data(), after.jsonUTF8Data()))
        after.createdAt = "2026-11-16T00:01:00Z"
        XCTAssertFalse(try UpdateVerification.sameIdentity(before.jsonUTF8Data(), after.jsonUTF8Data()))
        before.createdAt = ""
        after.createdAt = ""
        XCTAssertFalse(try UpdateVerification.sameIdentity(before.jsonUTF8Data(), after.jsonUTF8Data()))
    }

    func testFragmentedLogFramesRequireBothMarkersAndAuthoritativeEnd() async throws {
        let evidence = UpdateVerification.LogEvidence()
        func frame(_ bytes: Data, flags: UInt8 = 0) -> Data {
            var length = UInt32(bytes.count).bigEndian
            return Data([flags]) + Data(bytes: &length, count: 4) + bytes
        }
        let before = frame(Data("{\"text\":\"BEFORE-operation\"}".utf8))
        let after = frame(Data("{\"text\":\"AFTER-operation\"}".utf8))
        let payload = before + after + frame(Data("{}".utf8), flags: 2)
        for byte in payload { try await evidence.consume(Data([byte]), marker: "operation") }
        try await evidence.finish()
        let sawBefore = await evidence.sawBefore
        let sawAfter = await evidence.sawAfter
        XCTAssertTrue(sawBefore)
        XCTAssertTrue(sawAfter)
        do {
            try await evidence.consume(before, marker: "operation")
            XCTFail("Data after EOF must fail")
        } catch {}
        let truncated = UpdateVerification.LogEvidence()
        try await truncated.consume(before, marker: "operation")
        do {
            try await truncated.finish()
            XCTFail("Missing EOF must not be called a successful stream")
        } catch {}
    }
}
