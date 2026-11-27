import Foundation
import XCTest

@testable import MicropodAPI

final class HTTP2PrefaceTests: XCTestCase {
    func testThePrefaceMatchesOnlyWhole() {
        XCTAssertEqual(HTTP2Preface.classify(Data()), .partial)
        for (text, expected) in [
            ("POST / HTTP/1.1", HTTP2Preface.Classification.mismatch), ("PUT", .mismatch), ("PATCH", .mismatch),
            ("GET", .mismatch), ("P", .partial), ("PR", .partial), ("PRI * HTTP/1.1\r\n\r\n", .mismatch),
            ("PRI * HTTP/2.0\r\n\r\n", .partial),
        ] {
            XCTAssertEqual(HTTP2Preface.classify(Data(text.utf8)), expected, text)
        }
        XCTAssertEqual(HTTP2Preface.classify(HTTP2Preface.bytes + Data([0, 0, 0, 4])), .match)
        var buffer = Data()
        for (index, byte) in HTTP2Preface.bytes.enumerated() {
            buffer.append(byte)
            XCTAssertEqual(HTTP2Preface.classify(buffer), index == 23 ? .match : .partial, "byte \(index + 1)")
        }
    }
}
