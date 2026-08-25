import XCTest

@testable import MicropodDockerShim

final class StdcopyFramingTests: XCTestCase {
    func testFrameLayout() {
        let framed = ExecSession.frame(type: 1, payload: Data("hi\n".utf8))
        XCTAssertEqual([UInt8](framed.prefix(8)), [1, 0, 0, 0, 0, 0, 0, 3])
        XCTAssertEqual(String(decoding: framed.dropFirst(8), as: UTF8.self), "hi\n")
    }

    func testLargePayloadLengthIsBigEndian() {
        let payload = Data(repeating: 0x41, count: 70_000)
        let framed = ExecSession.frame(type: 2, payload: payload)
        XCTAssertEqual([UInt8](framed[4..<8]), [0, 1, 0x11, 0x70])  // 70000 = 0x11170
        XCTAssertEqual(framed.count, 8 + 70_000)
    }

    func testDecodeRoundTrip() {
        var stream = ExecSession.frame(type: 1, payload: Data("out".utf8))
        stream.append(ExecSession.frame(type: 2, payload: Data("err!".utf8)))
        let first = decodeFrame(stream)
        XCTAssertEqual(first?.type, 1)
        XCTAssertEqual(String(decoding: first!.payload, as: UTF8.self), "out")
        let rest = stream.dropFirst(first!.consumed)
        let second = decodeFrame(Data(rest))
        XCTAssertEqual(second?.type, 2)
        XCTAssertEqual(String(decoding: second!.payload, as: UTF8.self), "err!")
    }
}
