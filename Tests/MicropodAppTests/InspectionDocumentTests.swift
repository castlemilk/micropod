import Foundation
import XCTest

@testable import MicropodApp

@MainActor
final class InspectionDocumentTests: XCTestCase {
    func testFormattingPreservesCompletePayloadAndSortsNestedKeys() async throws {
        let payload = Data(#"{"z":{"b":2,"a":1},"a":["first","last"]}"#.utf8)
        let document = try await InspectionDocument.format(payload)
        XCTAssertEqual(document.lines.joined(separator: "\n"), document.text)
        XCTAssertTrue(document.text.range(of: #""a""#)!.lowerBound < document.text.range(of: #""z""#)!.lowerBound)
        XCTAssertTrue(document.text.contains(#""last""#))
        let roundTrip = try JSONSerialization.jsonObject(with: Data(document.text.utf8)) as! NSDictionary
        let original = try JSONSerialization.jsonObject(with: payload) as! NSDictionary
        XCTAssertEqual(roundTrip, original)
    }

    func testLargeDocumentLinesShareTheWholePayloadStorage() async throws {
        let values = (0..<10_000).map { ["index": String($0), "description": "container metadata"] }
        let payload = try JSONSerialization.data(withJSONObject: values)
        let document = try await InspectionDocument.format(payload)
        XCTAssertGreaterThan(document.lines.count, 30_000)
        XCTAssertEqual(document.lines.first?.base, document.text)
        XCTAssertEqual(document.lines.last?.base, document.text)
        XCTAssertTrue(document.text.contains(#""9999""#))
        XCTAssertEqual(document.lines.joined(separator: "\n"), document.text)
    }

    func testFragmentCanBeInspected() async throws {
        let document = try await InspectionDocument.format(Data("42".utf8))
        XCTAssertEqual(document.text, "42")
        XCTAssertEqual(document.lines.map(String.init), ["42"])
    }

    func testInvalidDocumentReportsParseError() async {
        do {
            _ = try await InspectionDocument.format(Data("{broken".utf8))
            XCTFail("Invalid inspect output must not become an empty success")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancelledRequestDoesNotReturnFormattedData() async {
        let operation = Task { try await InspectionDocument.format(Data("{}".utf8)) }
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("An obsolete inspector request must discard its result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
