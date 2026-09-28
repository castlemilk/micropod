import Foundation
import XCTest

@testable import MicropodDockerShim

/// Request framing through the real shim server: binary bodies (build
/// contexts, archives) are bytes, and malformed or stalled requests get an
/// answer instead of holding the connection.
final class ShimRequestFramingTests: XCTestCase {
    private var shim: ShimTestSupport.MockShim!

    override func setUp() async throws {
        shim = try ShimTestSupport.makeMockShim()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shim.stateDir)
    }

    private func statuses(_ data: Data) -> [String] {
        // Status lines, including one that directly follows a previous
        // response's body on a keep-alive connection.
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "HTTP/1.1 ").dropFirst().map {
            "HTTP/1.1 " + ($0.components(separatedBy: "\r\n").first ?? "")
        }
    }

    /// Non-UTF-8 body bytes (a Connect-style 0xB8 length byte, 0x80–0xFF)
    /// are framed by Content-Length, and the pipelined request behind them
    /// is still served.
    func testBinaryContentLengthBodyThenPipelinedRequest() throws {
        var body = Data([0x00, 0x00, 0x00, 0x00, 0xB8])
        body.append(Data((0x80...0xFF).map { UInt8($0) }))
        let client = shim.raw()
        defer { client.close() }
        var raw = Data(
            "POST /build/prune HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        raw.append(body)
        raw.append(Data("GET /_ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8))
        try client.writeRaw(raw)
        let response = try client.readUntilClose(timeout: 10)
        XCTAssertEqual(statuses(response).count, 2, String(decoding: response, as: UTF8.self))
        XCTAssertTrue(statuses(response).allSatisfy { $0.hasPrefix("HTTP/1.1 200") }, "\(statuses(response))")
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix("OK\n"))
    }

    /// A chunked binary body, delivered in small pieces.
    func testChunkedBinaryBodyArrivingInPieces() throws {
        let data = Data((0..<600).map { UInt8(0x80 + $0 % 0x80) })
        var framed = Data()
        for offset in stride(from: 0, to: data.count, by: 184) {
            let slice = data[offset..<min(offset + 184, data.count)]
            framed.append(Data((String(slice.count, radix: 16) + "\r\n").utf8))
            framed.append(slice)
            framed.append(Data("\r\n".utf8))
        }
        framed.append(Data("0\r\n\r\n".utf8))
        let head = Data(
            "POST /build/prune HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                .utf8)
        let client = shim.raw()
        defer { client.close() }
        let wire = head + framed
        for offset in stride(from: 0, to: wire.count, by: 97) {
            try client.writeRaw(Data(wire[offset..<min(offset + 97, wire.count)]))
            usleep(2000)
        }
        let response = try client.readUntilClose(timeout: 10)
        XCTAssertEqual(statuses(response).first?.hasPrefix("HTTP/1.1 200"), true, "\(statuses(response))")
    }

    /// The last-chunk line and its trailers arriving in separate reads.
    func testChunkedTrailersArrivingLater() throws {
        let client = shim.raw()
        defer { client.close() }
        var first = Data(
            "POST /build/prune HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\n"
                .utf8)
        first.append(contentsOf: [0x80, 0x81, 0x82])
        first.append(Data("\r\n0\r\n".utf8))
        try client.writeRaw(first)
        usleep(100_000)
        try client.writeRaw(Data("X-Trailer: v\r\n".utf8))
        usleep(100_000)
        try client.writeRaw(Data("\r\n".utf8))
        let response = try client.readUntilClose(timeout: 10)
        XCTAssertEqual(statuses(response).first?.hasPrefix("HTTP/1.1 200"), true, "\(statuses(response))")
    }

    func testMalformedRequestGets400() throws {
        let client = shim.raw()
        defer { client.close() }
        try client.writeRaw(
            Data("POST /build/prune HTTP/1.1\r\nHost: localhost\r\nContent-Length: nope\r\n\r\n".utf8))
        let response = try client.readUntilClose(timeout: 10)
        XCTAssertEqual(statuses(response).first, "HTTP/1.1 400 Bad Request")
    }

    func testMalformedChunkGets400() throws {
        let client = shim.raw()
        defer { client.close() }
        try client.writeRaw(
            Data(
                "POST /build/prune HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXY\r\n0\r\n\r\n"
                    .utf8))
        let response = try client.readUntilClose(timeout: 10)
        XCTAssertEqual(statuses(response).first, "HTTP/1.1 400 Bad Request")
    }

    func testOversizedHeaderGets431() throws {
        let client = shim.raw()
        defer { client.close() }
        var raw = Data("GET /_ping HTTP/1.1\r\nHost: localhost\r\nX-Big: ".utf8)
        raw.append(Data(repeating: UInt8(ascii: "a"), count: 1024 * 1024 + 16))
        // The server may refuse (and close) before every byte is written.
        try? client.writeRaw(raw)
        let response = try client.readUntilClose(timeout: 10)
        XCTAssertEqual(statuses(response).first, "HTTP/1.1 431 Request Header Fields Too Large")
    }

    /// A client that sends half a request and goes quiet gets 408.
    func testStalledPartialRequestGets408() throws {
        let previous = ShimHTTPServer.partialRequestIdleTimeoutMs
        ShimHTTPServer.partialRequestIdleTimeoutMs = 300
        defer { ShimHTTPServer.partialRequestIdleTimeoutMs = previous }
        let client = shim.raw()
        defer { client.close() }
        try client.writeRaw(
            Data("POST /build/prune HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nabc".utf8))
        let started = Date()
        let response = try client.readUntilClose(timeout: 10)
        XCTAssertEqual(statuses(response).first, "HTTP/1.1 408 Request Timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
