import Foundation
import XCTest

@testable import MicropodSharedFS

final class IPCValueEncodingTests: XCTestCase {
    func testJSONSerializationNumbersRemainNumbersAndBooleansRemainBooleans() throws {
        // Exercise the exact Foundation bridge used by typed cache RPCs.
        let original = Data(
            #"{"zero":0,"one":1,"large":10737418240,"decimal":0.25,"enabled":true,"disabled":false}"#.utf8)
        let object = try JSONSerialization.jsonObject(with: original)
        let encoded = try JSONEncoder().encode(AnyCodable(object))
        let decoded = try JSONDecoder().decode(Values.self, from: encoded)
        XCTAssertEqual(decoded.zero, 0)
        XCTAssertEqual(decoded.one, 1)
        XCTAssertEqual(decoded.large, 10 << 30)
        XCTAssertEqual(decoded.decimal, 0.25)
        XCTAssertTrue(decoded.enabled)
        XCTAssertFalse(decoded.disabled)
    }

    private struct Values: Decodable {
        let zero: Int
        let one: Int
        let large: UInt64
        let decimal: Double
        let enabled: Bool
        let disabled: Bool
    }
}
