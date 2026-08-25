import XCTest

@testable import MicropodCore

final class ParseDateTests: XCTestCase {
    func testParsesInternetDateTime() {
        XCTAssertNotNil(parseDate("2026-08-17T10:00:00Z"))
        XCTAssertNotNil(parseDate("2026-08-17T10:00:00+10:00"))
    }

    func testParsesFractionalSeconds() {
        let date = parseDate("2026-08-17T10:00:00.123Z")
        XCTAssertNotNil(date)
        if let date {
            let expected = parseDate("2026-08-17T10:00:00Z")!.timeIntervalSince1970 + 0.123
            XCTAssertEqual(date.timeIntervalSince1970, expected, accuracy: 0.01)
        }
    }

    func testRejectsGarbageAndEmpty() {
        XCTAssertNil(parseDate(""))
        XCTAssertNil(parseDate("not-a-date"))
        XCTAssertNil(parseDate("2026-13-99T99:99:99Z"))
    }

    func testRelativeCreationStableForSameInput() {
        let a = parseDate("2026-08-17T10:00:00Z")
        let b = parseDate("2026-08-17T10:00:00Z")
        XCTAssertEqual(a, b)
    }
}
