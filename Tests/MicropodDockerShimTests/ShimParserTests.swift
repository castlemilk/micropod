import XCTest

@testable import MicropodDockerShim

final class ShimParserTests: XCTestCase {
    func testParsesSimpleGet() throws {
        let raw = Data("GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(ShimRequestParser.parse(raw))
        XCTAssertEqual(parsed.request.method, "GET")
        XCTAssertEqual(parsed.request.path, "/_ping")
        XCTAssertEqual(parsed.request.body, Data())
        XCTAssertTrue(parsed.remainder.isEmpty)
    }

    func testReturnsNilUntilBodyComplete() throws {
        let full = "POST /containers/create HTTP/1.1\r\nContent-Length: 5\r\n\r\nabcde"
        let truncated = String(full.dropLast(2))
        XCTAssertNil(ShimRequestParser.parse(Data(truncated.utf8)))
        let parsed = try XCTUnwrap(ShimRequestParser.parse(Data(full.utf8)))
        XCTAssertEqual(String(decoding: parsed.request.body, as: UTF8.self), "abcde")
    }

    func testRemainderCarriesPipelinedRequest() throws {
        let first = "GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n"
        let second = "GET /version HTTP/1.1\r\nHost: d\r\n\r\n"
        let parsed = try XCTUnwrap(ShimRequestParser.parse(Data((first + second).utf8)))
        XCTAssertEqual(parsed.request.path, "/_ping")
        XCTAssertEqual(String(decoding: parsed.remainder, as: UTF8.self), second)
    }

    func testStripsAPIVersionPrefix() throws {
        for path in ["/v1.24/containers/json", "/v1.44/networks", "/v1.51/volumes"] {
            let raw = Data("GET \(path) HTTP/1.1\r\nHost: d\r\n\r\n".utf8)
            let parsed = try XCTUnwrap(ShimRequestParser.parse(raw))
            let expected = String(path.dropFirst("/vX.XX".count))
            XCTAssertEqual(
                parsed.request.path, expected,
                "\(path) should lose its version prefix")
        }
    }

    func testDoesNotStripNonVersionFirstSegment() throws {
        let raw = Data("GET /volumes HTTP/1.1\r\nHost: d\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(ShimRequestParser.parse(raw))
        XCTAssertEqual(parsed.request.path, "/volumes")
    }

    func testDecodesPercentEncodedQuery() throws {
        let filters = "{\"labels\":[\"org.testcontainers.session-id=abc\"]}"
        let encoded = filters.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let raw = Data("GET /containers/json?all=1&filters=\(encoded) HTTP/1.1\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(ShimRequestParser.parse(raw))
        XCTAssertEqual(parsed.request.q("all"), "1")
        XCTAssertEqual(
            parsed.request.filters(),
            ["labels": ["org.testcontainers.session-id=abc"]])
    }

    func testBinaryBodySurvivesParsing() throws {
        var body = Data([0x01, 0x00, 0x00, 0x00, 0xFF, 0xFE])
        body.append(Data("\r\n\r\n inside body".utf8))
        let head = "POST /containers/x/archive HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n"
        let raw = Data(head.utf8) + body
        let parsed = try XCTUnwrap(ShimRequestParser.parse(raw))
        XCTAssertEqual(parsed.request.body, body)
    }

    func testChunkedBodyDecodes() throws {
        let raw = Data(
            "POST /containers/x/archive HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
                .utf8)
        let parsed = try XCTUnwrap(ShimRequestParser.parse(raw))
        XCTAssertEqual(String(decoding: parsed.request.body, as: UTF8.self), "hello world")
        XCTAssertTrue(parsed.remainder.isEmpty)
    }

    func testChunkedBodyIncompleteReturnsNil() {
        let head = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let partials = ["4\r\nabcd", "4\r\nabcd\r\n0\r\n", "4\r\nabcd\r\n0\r\n\r"]
        for partial in partials {
            XCTAssertNil(
                ShimRequestParser.parse(Data(head.utf8) + Data(partial.utf8)),
                "should be incomplete: \(partial.debugDescription)")
        }
        XCTAssertNotNil(
            ShimRequestParser.parse(
                Data(head.utf8) + Data("4\r\nabcd\r\n0\r\n\r\n".utf8)))
    }

    func testChunkedBodyWithTrailersAndRemainder() throws {
        let head = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let framed = "3\r\nabc\r\n0\r\nX-Trailer: v\r\n\r\n"
        let pipelined = "GET /next HTTP/1.1\r\nHost: d\r\n\r\n"
        let parsed = try XCTUnwrap(
            ShimRequestParser.parse(Data((head + framed).utf8) + Data(pipelined.utf8)))
        XCTAssertEqual(String(decoding: parsed.request.body, as: UTF8.self), "abc")
        XCTAssertEqual(String(decoding: parsed.remainder, as: UTF8.self), pipelined)
    }

    func testChunkedSizeLineWithExtension() throws {
        let raw = Data(
            "PUT /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4;n=v\r\nabcd\r\n0\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(ShimRequestParser.parse(raw))
        XCTAssertEqual(String(decoding: parsed.request.body, as: UTF8.self), "abcd")
    }
}
