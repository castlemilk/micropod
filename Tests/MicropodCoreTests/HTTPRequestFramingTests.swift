import Foundation
import XCTest

@testable import MicropodCore

/// Binary-safe request framing: the head is text, the body is bytes.
final class HTTPRequestFramingTests: XCTestCase {
    private let limits = HTTPRequestFraming.Limits.api

    private func envelope(_ payload: Data, flags: UInt8 = 0) -> Data {
        var frame = Data([flags])
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        return frame
    }

    private func head(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func connectHead(contentLength: Int? = nil, chunked: Bool = false) -> Data {
        var lines = [
            "POST /api/micropod.v1.ImageService/PullImage HTTP/1.1",
            "Host: 127.0.0.1:45454",
            "Content-Type: application/connect+json",
        ]
        if let contentLength { lines.append("Content-Length: \(contentLength)") }
        if chunked { lines.append("Transfer-Encoding: chunked") }
        return head(lines)
    }

    private func chunked(_ body: Data, sizes: [Int]) -> Data {
        var out = Data()
        var offset = 0
        var index = 0
        while offset < body.count {
            let size = min(sizes[index % sizes.count], body.count - offset)
            out.append(Data((String(size, radix: 16) + "\r\n").utf8))
            out.append(body[offset..<(offset + size)])
            out.append(Data("\r\n".utf8))
            offset += size
            index += 1
        }
        out.append(Data("0\r\n\r\n".utf8))
        return out
    }

    private func complete(
        _ data: Data, file: StaticString = #filePath, line: UInt = #line
    ) -> (head: HTTPRequestFraming.Head, body: Data, consumed: Int)? {
        switch HTTPRequestFraming.parse(data, limits: limits) {
        case .complete(let head, let body, let consumed): return (head, body, consumed)
        case let other:
            XCTFail("expected complete, got \(other)", file: file, line: line)
            return nil
        }
    }

    private func assertInvalid(
        _ data: Data, status: Int, limits: HTTPRequestFraming.Limits? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let result = HTTPRequestFraming.parse(data, limits: limits ?? self.limits)
        guard case .invalid(let got, _) = result else {
            return XCTFail("expected invalid \(status), got \(result)", file: file, line: line)
        }
        XCTAssertEqual(got, status, file: file, line: line)
    }

    // MARK: - The bug: envelope length bytes 0x80–0xFF

    /// Every envelope whose length byte is not valid UTF-8 on its own — the
    /// 184-byte PullImage request that hung the cuttlefish agent among them.
    func testEnvelopeLengthByteHighBitParses() throws {
        for length in 0x80...0xFF {
            let payload = Data(repeating: UInt8(ascii: "a"), count: length)
            let body = envelope(payload)
            XCTAssertEqual(body[4], UInt8(length))
            let raw = connectHead(contentLength: body.count) + body
            let parsed = try XCTUnwrap(complete(raw), "length \(length)")
            XCTAssertEqual(parsed.body, body, "length \(length)")
            XCTAssertEqual(parsed.consumed, raw.count)
            XCTAssertEqual(parsed.head.method, "POST")
            XCTAssertEqual(parsed.head.target, "/api/micropod.v1.ImageService/PullImage")
            XCTAssertEqual(parsed.head.headers["content-type"], "application/connect+json")
        }
    }

    func testExact184BytePullImageRequest() throws {
        let reference =
            "cuttlefish-registry.benebsworth.com/cuttlefish/docker-bundle:29.8.1-cf1@sha256:"
            + "92e94931cba25934db1d98a1b3434e2e0aa6cf0dccf72197c13314ffd42a1752"
        var json = Data("{\"reference\":\"\(reference)\"}".utf8)
        json.append(Data(repeating: UInt8(ascii: " "), count: 184 - json.count))
        let body = envelope(json)
        XCTAssertEqual(body[4], 0xB8)
        XCTAssertNil(String(data: body, encoding: .utf8), "precondition: body is not UTF-8")
        let parsed = try XCTUnwrap(complete(connectHead(contentLength: body.count) + body))
        XCTAssertEqual(parsed.body, body)
    }

    // MARK: - Binary bodies

    func testArbitraryBinaryBodies() throws {
        var generator = SystemRandomNumberGenerator()
        for size in [1, 2, 5, 127, 128, 255, 256, 4096, 70_000] {
            var body = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
            // Terminator-looking bytes inside the body must not matter.
            if size > 8 { body.replaceSubrange(2..<6, with: Data("\r\n\r\n".utf8)) }
            let raw = head(["PUT /x HTTP/1.1", "Host: h", "Content-Length: \(size)"]) + body
            let parsed = try XCTUnwrap(complete(raw))
            XCTAssertEqual(parsed.body, body, "size \(size)")
        }
    }

    func testAllByteValuesSurvive() throws {
        let body = Data((0...255).map { UInt8($0) })
        let parsed = try XCTUnwrap(complete(connectHead(contentLength: body.count) + body))
        XCTAssertEqual(parsed.body, body)
    }

    /// A non-UTF-8 byte in the head (obs-text in a header value) must not
    /// stall the parser either: it decodes as Latin-1.
    func testNonUTF8HeadByteDecodes() throws {
        var raw = Data("GET /x HTTP/1.1\r\nHost: h\r\nX-Odd: a".utf8)
        raw.append(0xB8)
        raw.append(Data("b\r\n\r\n".utf8))
        let parsed = try XCTUnwrap(complete(raw))
        XCTAssertEqual(parsed.head.headers["x-odd"], "a\u{B8}b")
    }

    // MARK: - Chunked

    func testChunkedBodyDecodesToRawBytes() throws {
        let body = envelope(Data(repeating: 0x7B, count: 184))
        for sizes in [[body.count], [1], [5, 7], [64]] {
            let raw = connectHead(chunked: true) + chunked(body, sizes: sizes)
            let parsed = try XCTUnwrap(complete(raw), "sizes \(sizes)")
            XCTAssertEqual(parsed.body, body, "sizes \(sizes)")
            XCTAssertEqual(parsed.consumed, raw.count)
            XCTAssertEqual(parsed.head.bodyFraming, .chunked)
        }
    }

    func testChunkedWithExtensionsTrailersAndUppercaseHex() throws {
        var framed = Data("B8;name=value\r\n".utf8)
        let data = Data((0..<184).map { UInt8($0 % 256) })
        framed.append(data)
        framed.append(Data("\r\n0\r\nX-Trailer: v\r\n\r\n".utf8))
        let parsed = try XCTUnwrap(complete(connectHead(chunked: true) + framed))
        XCTAssertEqual(parsed.body, data)
    }

    func testChunkedWinsOverContentLength() throws {
        let raw =
            head(["POST /x HTTP/1.1", "Host: h", "Content-Length: 3", "Transfer-Encoding: chunked"])
            + Data("5\r\nhello\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(try XCTUnwrap(complete(raw)).body, Data("hello".utf8))
    }

    func testEmptyChunkedBody() throws {
        let raw = connectHead(chunked: true) + Data("0\r\n\r\n".utf8)
        XCTAssertEqual(try XCTUnwrap(complete(raw)).body, Data())
    }

    // MARK: - Partial reads and pipelining

    /// Bytes arriving one at a time: incomplete at every prefix, complete
    /// (and identical) only at the end — for both body framings.
    func testByteAtATimeArrival() throws {
        let body = envelope(Data((0..<200).map { UInt8(255 - $0 % 256) }))
        let requests = [
            connectHead(contentLength: body.count) + body,
            connectHead(chunked: true) + chunked(body, sizes: [17, 3]),
        ]
        for raw in requests {
            for cut in 0..<raw.count {
                let prefix = raw.prefix(cut)
                XCTAssertEqual(
                    HTTPRequestFraming.parse(Data(prefix), limits: limits), .incomplete,
                    "prefix \(cut)/\(raw.count)")
            }
            XCTAssertEqual(try XCTUnwrap(complete(raw)).body, body)
        }
    }

    func testPipelinedRequestsReportConsumed() throws {
        let first = connectHead(contentLength: 6) + Data([0x00, 0x00, 0x00, 0x00, 0x01, 0xFF])
        let second = connectHead(chunked: true) + Data("2\r\n\u{1}\u{2}\r\n0\r\n\r\n".utf8)
        let third = head(["GET /health HTTP/1.1", "Host: h"])
        var buffer = first + second + third
        var bodies: [Data] = []
        while !buffer.isEmpty {
            let parsed = try XCTUnwrap(complete(buffer))
            bodies.append(parsed.body)
            buffer = Data(buffer.dropFirst(parsed.consumed))
        }
        XCTAssertEqual(bodies, [Data([0, 0, 0, 0, 1, 0xFF]), Data([1, 2]), Data()])
    }

    /// Parsing a slice (non-zero startIndex) must use relative offsets.
    func testSliceWithNonZeroStartIndex() throws {
        let raw = Data("junk".utf8) + connectHead(contentLength: 3) + Data([0xB8, 0x80, 0xFF])
        let slice = raw[4...]
        let parsed = try XCTUnwrap(complete(slice))
        XCTAssertEqual(parsed.body, Data([0xB8, 0x80, 0xFF]))
        XCTAssertEqual(parsed.consumed, slice.count)
    }

    // MARK: - Limits and malformed input

    func testOversizedHeaderIsRefusedWithoutTerminator() {
        let small = HTTPRequestFraming.Limits(maxHeaderBytes: 1024, maxBodyBytes: 1024)
        var raw = Data("GET /x HTTP/1.1\r\nX-Big: ".utf8)
        raw.append(Data(repeating: UInt8(ascii: "a"), count: 2048))
        assertInvalid(raw, status: 431, limits: small)
        // Under the limit and unterminated: still waiting.
        XCTAssertEqual(
            HTTPRequestFraming.parse(Data(raw.prefix(512)), limits: small), .incomplete)
    }

    func testOversizedHeaderIsRefusedWithTerminator() {
        let small = HTTPRequestFraming.Limits(maxHeaderBytes: 1024, maxBodyBytes: 1024)
        let raw = head(["GET /x HTTP/1.1", "X-Big: " + String(repeating: "a", count: 1100)])
        assertInvalid(raw, status: 431, limits: small)
    }

    func testOversizedBodies() {
        let small = HTTPRequestFraming.Limits(maxHeaderBytes: 1024, maxBodyBytes: 100)
        // Refused from the head alone — no need to receive the body.
        assertInvalid(connectHead(contentLength: 101), status: 413, limits: small)
        let chunkedBody = chunked(Data(repeating: 1, count: 150), sizes: [60])
        assertInvalid(connectHead(chunked: true) + chunkedBody, status: 413, limits: small)
        // A single huge declared chunk is refused before its data arrives.
        assertInvalid(connectHead(chunked: true) + Data("FFFFFFFF\r\n".utf8), status: 413, limits: small)
    }

    func testMalformedInputIsRefused() {
        let cases: [(Data, Int)] = [
            (Data("GARBAGE\r\n\r\n".utf8), 400),
            (Data("GET /x\r\n\r\n".utf8), 400),
            (Data("G\u{1}T /x HTTP/1.1\r\n\r\n".utf8), 400),
            (Data("GET /x HTTP/2.0\r\n\r\n".utf8), 505),
            (head(["POST /x HTTP/1.1", "Content-Length: -1"]), 400),
            (head(["POST /x HTTP/1.1", "Content-Length: abc"]), 400),
            (head(["POST /x HTTP/1.1", "Content-Length: 3", "Content-Length: 4"]), 400),
            (head(["POST /x HTTP/1.1", "Content-Length : 3"]), 400),
            (head(["POST /x HTTP/1.1", "no colon here"]), 400),
            (head(["POST /x HTTP/1.1", "Transfer-Encoding: gzip"]), 501),
            (head(["POST /x HTTP/1.1", "Transfer-Encoding: chunked"]) + Data("zz\r\n".utf8), 400),
            (head(["POST /x HTTP/1.1", "Transfer-Encoding: chunked"]) + Data("-5\r\n".utf8), 400),
            (head(["POST /x HTTP/1.1", "Transfer-Encoding: chunked"]) + Data("3\r\nabcXY".utf8), 400),
            (
                head(["POST /x HTTP/1.1", "Transfer-Encoding: chunked"])
                    + Data(repeating: UInt8(ascii: "1"), count: 5000), 400
            ),
        ]
        for (raw, status) in cases {
            assertInvalid(raw, status: status)
        }
    }

    func testRepeatedEqualContentLengthIsAccepted() throws {
        let raw = head(["POST /x HTTP/1.1", "Content-Length: 2", "Content-Length: 2"]) + Data([0x80, 0x81])
        XCTAssertEqual(try XCTUnwrap(complete(raw)).body, Data([0x80, 0x81]))
    }

    func testErrorResponseIsFramed() {
        let response = String(decoding: HTTPRequestFraming.errorResponse(status: 413, reason: "big"), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"), response)
        XCTAssertTrue(response.contains("Connection: close\r\n"), response)
        XCTAssertTrue(response.contains("\"big\""), response)
    }
}
