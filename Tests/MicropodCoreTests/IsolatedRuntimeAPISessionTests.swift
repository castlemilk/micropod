import Darwin
import Foundation
import XCTest

@testable import MicropodCore

final class IsolatedRuntimeAPISessionTests: XCTestCase {
    func testTokenIsBoundToInstanceProcessAndExpiryAndIsNotStoredInPublicRecord() throws {
        let subject = try XCTUnwrap(RuntimeProcessBirth.read(getpid()))
        let session = IsolatedRuntimeAPISession(
            id: UUID(), instance: UUID(), token: "a-private-test-capability", subject: subject,
            expiresAt: Date().addingTimeInterval(60))
        let record = IsolatedRuntimeAPISessionRecord(session: session)
        XCTAssertTrue(record.accepts(token: session.token, peer: subject, instance: session.instance))
        XCTAssertFalse(record.accepts(token: "wrong", peer: subject, instance: session.instance))
        XCTAssertFalse(record.accepts(token: session.token, peer: subject, instance: UUID()))
        XCTAssertFalse(
            record.accepts(token: session.token, peer: subject, instance: session.instance, now: session.expiresAt))
        let encoded = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(session.token))
        let expiredSubject = try JSONDecoder().decode(
            RuntimeProcessBirth.self,
            from: Data("{\"pid\":1,\"uid\":0,\"seconds\":0,\"microseconds\":0,\"bootSession\":\"foreign\"}".utf8))
        XCTAssertFalse(record.accepts(token: session.token, peer: expiredSubject, instance: session.instance))
    }
}
