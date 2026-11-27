import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodAPI

/// The exact bytes the HTTP/1.1 server writes, pinned before HTTP/2 was
/// added beside it: every client in the field (the CLI, MicropodMCP,
/// Cuttlefish, the SDKs) reads these, so the HTTP/2 work must not move a
/// byte of them. Heads are compared byte for byte; a JSON body with more
/// than one key is compared as JSON (a Swift dictionary's order is seeded
/// per instance), with its exact length.
final class HTTP1GoldenBytesTests: XCTestCase {
    private var dir: URL!
    private var servers: [HTTPServer] = []

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/mp-g1-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    static let policy = HTTPServer.ConnectionPolicy(
        requestIdle: .milliseconds(300), requestDeadline: .milliseconds(900), keepAliveIdle: .seconds(30),
        maxKeptConnections: 64)

    /// The response shapes the real routes return.
    static func handler(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == .options { return .data(204, "text/plain", Data()) }
        switch request.path {
        case "/health":
            return .json(200, ["status": "ok"])
        case "/api/micropod.v1.SystemService/Ping":
            if request.headers["content-type"] == "application/proto" {
                return .data(200, "application/proto", Data([0x0A, 0x07]) + Data("running".utf8))
            }
            return .data(200, "application/json", Data(#"{"status":"running"}"#.utf8))
        case "/stream":
            return .stream(
                200, "application/connect+json",
                AsyncStream { continuation in
                    continuation.yield(ConnectEnvelope.frame(Data(#"{"text":"one"}"#.utf8), flags: 0))
                    continuation.yield(ConnectEnvelope.frame(Data("{}".utf8), flags: 0x02))
                    continuation.finish()
                })
        case "/sse":
            return .stream(
                200, "text/event-stream",
                AsyncStream { continuation in
                    continuation.yield(Data("data: one\n\n".utf8))
                    continuation.finish()
                })
        default:
            return .json(404, ["error": "not found"])
        }
    }

    private func ownerSocket() async throws -> String {
        let server = HTTPServer(port: 45454, policy: Self.policy, isolatedRuntime: false, handler: Self.handler)
        servers.append(server)
        let path = dir.appendingPathComponent("api.sock").path
        let started = await MicropodAPI.startOwnerSocket(server, path: path, log: { XCTFail($0) })
        XCTAssertEqual(started, path)
        return path
    }

    private func tcp() throws -> UInt16 {
        let port = try RawConnection.freePort()
        let server = HTTPServer(port: port, policy: Self.policy, isolatedRuntime: false, handler: Self.handler)
        servers.append(server)
        try server.startListening()
        return port
    }

    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async { done.resume(with: Result { try body() }) }
        }
    }

    static let codecs = "X-Micropod-Codecs: json,proto\r\n"

    /// A kept reply with a body of exactly `body`.
    static func kept(_ status: String, _ type: String, _ body: String, extra: String = "") -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n\(extra)\(codecs)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    // MARK: - Kept replies

    func testHealthAndConnectUnaryBytes() async throws {
        let path = try await ownerSocket()
        try await blocking {
            let wire = try GoldenWire.unix(path)
            try wire.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let health = Self.kept("200 OK", "application/json", #"{"status":"ok"}"#)
            XCTAssertEqual(try wire.read(health.utf8.count).text, health)

            let json = #"{"status":"running"}"#
            try wire.send(
                "POST /api/micropod.v1.SystemService/Ping HTTP/1.1\r\nHost: localhost\r\n"
                    + "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
            let jsonReply = Self.kept("200 OK", "application/json", json)
            XCTAssertEqual(try wire.read(jsonReply.utf8.count).text, jsonReply)

            try wire.send(
                "POST /api/micropod.v1.SystemService/Ping HTTP/1.1\r\nHost: localhost\r\n"
                    + "Content-Type: application/proto\r\nContent-Length: 0\r\n\r\n")
            let protoHead =
                "HTTP/1.1 200 OK\r\nContent-Type: application/proto\r\n\(Self.codecs)Content-Length: 9\r\n\r\n"
            let proto = try wire.read(protoHead.utf8.count + 9)
            XCTAssertEqual(proto, Data(protoHead.utf8) + Data([0x0A, 0x07]) + Data("running".utf8))

            try wire.send("GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let missing = Self.kept("404 Not Found", "application/json", #"{"error":"not found"}"#)
            XCTAssertEqual(try wire.read(missing.utf8.count).text, missing)
            XCTAssertTrue(try wire.silent(for: 0.2), "a kept connection says nothing more")
        }
    }

    func testPreflightBytes() async throws {
        let path = try await ownerSocket()
        try await blocking {
            let wire = try GoldenWire.unix(path)
            try wire.send(
                "OPTIONS /api/micropod.v1.SystemService/Ping HTTP/1.1\r\nHost: localhost\r\n"
                    + "Origin: http://localhost:3000\r\nAccess-Control-Request-Method: POST\r\n\r\n")
            let cors =
                "Access-Control-Allow-Origin: http://localhost:3000\r\nVary: Origin\r\n"
                + "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: Content-Type, Connect-Protocol-Version, Connect-Timeout-Ms, "
                + "Authorization\r\nAccess-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 7200\r\n"
            let expected = Self.kept("204 Unknown", "text/plain", "", extra: cors)
            XCTAssertEqual(try wire.read(expected.utf8.count).text, expected)
        }
    }

    func testPipelinedPairAndPersistenceBytes() async throws {
        let path = try await ownerSocket()
        try await blocking {
            let wire = try GoldenWire.unix(path)
            try wire.send(
                "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\nGET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let pair =
                Self.kept("200 OK", "application/json", #"{"status":"ok"}"#)
                + Self.kept("404 Not Found", "application/json", #"{"error":"not found"}"#)
            XCTAssertEqual(try wire.read(pair.utf8.count).text, pair)

            // HTTP/1.0 asking to keep the connection is told so.
            try wire.send("GET /health HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
            let announced =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: keep-alive\r\n\(Self.codecs)"
                + "Content-Length: 15\r\n\r\n{\"status\":\"ok\"}"
            XCTAssertEqual(try wire.read(announced.utf8.count).text, announced)

            // Connection: close is answered with it, then the close.
            try wire.send("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            let closing =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\(Self.codecs)Content-Length: 15\r\n"
                + "Connection: close\r\n\r\n{\"status\":\"ok\"}"
            XCTAssertEqual(try wire.readToEOF().text, closing)
        }
    }

    // MARK: - Streams

    func testCloseDelimitedStreamAndSSEBytes() async throws {
        let path = try await ownerSocket()
        try await blocking {
            let wire = try GoldenWire.unix(path)
            try wire.send(
                "POST /stream HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/connect+json\r\n"
                    + "Content-Length: 0\r\n\r\n")
            let head =
                "HTTP/1.1 200 HTTP/1.1 200 OK\r\nContent-Type: application/connect+json\r\n"
                + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            let body =
                ConnectEnvelope.frame(Data(#"{"text":"one"}"#.utf8), flags: 0)
                + ConnectEnvelope.frame(Data("{}".utf8), flags: 0x02)
            XCTAssertEqual(try wire.readToEOF(), Data(head.utf8) + body, "the head, the frames, then EOF")

            let sse = try GoldenWire.unix(path)
            try sse.send("GET /sse HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let sseBytes =
                "HTTP/1.1 200 HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\nConnection: close\r\n\r\ndata: one\n\n"
            XCTAssertEqual(try sse.readToEOF().text, sseBytes)
        }
    }

    func testChunkedStreamBytes() async throws {
        let path = try await ownerSocket()
        try await blocking {
            let wire = try GoldenWire.unix(path)
            try wire.send(
                "POST /stream HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/connect+json\r\n"
                    + "X-Micropod-Stream-Framing: chunked\r\nContent-Length: 0\r\n\r\n")
            let head =
                "HTTP/1.1 200 OK\r\nContent-Type: application/connect+json\r\nTransfer-Encoding: chunked\r\n"
                + "X-Micropod-Stream-Framing: chunked\r\nCache-Control: no-cache\r\n\r\n"
            let first = ConnectEnvelope.frame(Data(#"{"text":"one"}"#.utf8), flags: 0)
            let last = ConnectEnvelope.frame(Data("{}".utf8), flags: 0x02)
            let expected =
                Data(head.utf8) + HTTPStreamFraming.chunk(first) + HTTPStreamFraming.chunk(last)
                + Data("0\r\n\r\n".utf8)
            XCTAssertEqual(try wire.read(expected.count), expected)
            // The connection then serves the next request.
            try wire.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let health = Self.kept("200 OK", "application/json", #"{"status":"ok"}"#)
            XCTAssertEqual(try wire.read(health.utf8.count).text, health)
        }
    }

    // MARK: - Refusals

    func testGuardRefusalBytesOnTCP() async throws {
        let port = try tcp()
        try await blocking {
            for (request, status, code, message) in [
                (
                    "GET /health HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n", "403 Forbidden",
                    "permission_denied",
                    "forbidden: Host must be 127.0.0.1:\(port), localhost:\(port) or [::1]:\(port)"
                ),
                (
                    "GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: https://evil.example\r\n\r\n",
                    "403 Forbidden", "permission_denied", "forbidden: origin https://evil.example is not allowed"
                ),
                (
                    "POST /api/micropod.v1.SystemService/Ping HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                        + "Content-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}",
                    "415 Unsupported Media Type", "invalid_argument",
                    "unsupported media type: use Content-Type application/json (Connect unary), "
                        + "application/connect+json (Connect streams), application/proto or application/grpc"
                ),
            ] {
                let wire = try GoldenWire.tcp(port)
                try wire.send(request)
                let reply = try wire.readToEOF()
                let (head, body) = GoldenWire.split(reply)
                let object: [String: String] = ["code": code, "message": message, "error": message]
                let expectedBody = try JSONSerialization.data(withJSONObject: object)
                XCTAssertEqual(
                    head,
                    "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n\(Self.codecs)"
                        + "Content-Length: \(expectedBody.count)\r\nConnection: close\r\n\r\n")
                XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], object)
            }
        }
    }

    /// The dedicated runtime's API with maintenance holding admission
    /// closed: 503 before any handler, `/health` exempt.
    func testAdmissionClosedBytes() async throws {
        let root = dir.appendingPathComponent("admission")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("fence.json"))
        let server = HTTPServer(
            port: 45454, policy: Self.policy, isolatedRuntime: true, runtimeAdmission: RuntimeAdmission(root: root),
            handler: Self.handler)
        servers.append(server)
        let path = dir.appendingPathComponent("api.sock").path
        _ = await MicropodAPI.startOwnerSocket(server, path: path, log: { XCTFail($0) })
        try await blocking {
            let wire = try GoldenWire.unix(path)
            try wire.send("GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let (head, body) = GoldenWire.split(try wire.readToEOF())
            let object = ["code": "unavailable", "message": "Runtime maintenance has closed workload admission"]
            let expectedBody = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(
                head,
                "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n\(Self.codecs)"
                    + "Content-Length: \(expectedBody.count)\r\nConnection: close\r\n\r\n")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], object)

            let health = try GoldenWire.unix(path)
            try health.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let expected = Self.kept("200 OK", "application/json", #"{"status":"ok"}"#)
            XCTAssertEqual(try health.read(expected.utf8.count).text, expected, "/health is exempt")
        }
    }

    func testTheSharedChecksAnswerAsTheServerDoes() throws {
        let server = HTTPServer(port: 45454, policy: Self.policy, isolatedRuntime: false, handler: Self.handler)
        let foreign = HTTPRequest(method: .get, path: "/health", query: [:], body: Data(), headers: ["host": "evil"])
        guard case .data(403, "application/json", _) = server.guardRejection(foreign, admission: .guarded) else {
            return XCTFail("a foreign Host is refused on a guarded listener")
        }
        XCTAssertNil(server.guardRejection(foreign, admission: .ownerOnly), "the owner socket skips the guard")
        XCTAssertNil(try server.admissionClaim(foreign), "only the dedicated runtime's API claims")
        XCTAssertEqual(HTTPParser.splitTarget("/v1/x?tail=5&q=a%20b&flag").path, "/v1/x")
        XCTAssertEqual(
            HTTPParser.splitTarget("/v1/x?tail=5&q=a%20b&flag").query, ["tail": "5", "q": "a b", "flag": ""])
    }

    func testFramingRefusalAndTimeoutBytes() async throws {
        let path = try await ownerSocket()
        // With HTTP/2 off (MICROPOD_API_HTTP2=0) a preface gets the HTTP/1.1
        // answer it always had.
        let off = HTTPServer(
            port: 45454, policy: Self.policy, isolatedRuntime: false, http2Enabled: false, handler: Self.handler)
        servers.append(off)
        let offPath = dir.appendingPathComponent("off.sock").path
        _ = await MicropodAPI.startOwnerSocket(off, path: offPath, log: { XCTFail($0) })
        try await blocking {
            func error(_ status: String, _ reason: String) throws -> (String, [String: String], Int) {
                let object = ["error": reason, "message": reason]
                let body = try JSONSerialization.data(withJSONObject: object)
                return (
                    "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
                        + "Connection: close\r\n\r\n", object, body.count
                )
            }
            func check(_ wire: GoldenWire, _ expected: (String, [String: String], Int), _ why: String) throws {
                let (head, body) = GoldenWire.split(try wire.readToEOF())
                XCTAssertEqual(head, expected.0, why)
                XCTAssertEqual(body.count, expected.2, why)
                XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], expected.1, why)
            }
            // Half a request, then the client closes its side.
            let truncated = try GoldenWire.unix(path)
            try truncated.send("POST /health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nabc")
            truncated.shutdownWrite()
            try check(truncated, try error("400 Bad Request", "request truncated"), "truncated")

            // Silence mid-request: the idle clock.
            let quiet = try GoldenWire.unix(path)
            try quiet.send("GET /health HTTP/1.1\r\n")
            try check(quiet, try error("408 Request Timeout", "request incomplete: client went idle"), "silence")

            // A request trickled byte by byte, never finished: the deadline.
            let slow = try GoldenWire.unix(path)
            try slow.send("GET /health HTTP/1.1\r\n")
            // Bytes arrive well inside the idle window (300 ms) until the
            // deadline (900 ms) has passed, so a slow host cannot let the idle
            // clock answer first.
            let trickleEnd = Date().addingTimeInterval(1.2)
            while Date() < trickleEnd {
                usleep(40_000)
                try? slow.send("X")
            }
            try check(slow, try error("408 Request Timeout", "request not received in time"), "deadline")

            // The HTTP/2 connection preface, to a server that speaks only HTTP/1.1.
            let preface = try GoldenWire.unix(offPath)
            try preface.send("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
            try check(
                preface, try error("505 HTTP Version Not Supported", "unsupported HTTP version HTTP/2.0"), "preface")
        }
    }
}

/// A raw client socket that reads exact byte counts, for golden comparisons.
final class GoldenWire: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private(set) var fd: Int32
    private var buffer = Data()

    private init(fd: Int32) { self.fd = fd }
    deinit { if fd >= 0 { close(fd) } }

    static func unix(_ path: String) throws -> GoldenWire {
        GoldenWire(fd: try RuntimeUnixSocket.connect(path, expectedUID: getuid()))
    }

    static func tcp(_ port: UInt16) throws -> GoldenWire {
        let deadline = Date().addingTimeInterval(3)
        while true {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return GoldenWire(fd: fd) }
            close(fd)
            guard Date() < deadline else { throw Failure(description: "127.0.0.1:\(port) never accepted") }
            usleep(20_000)
        }
    }

    func send(_ text: String) throws { try send(Data(text.utf8)) }
    func send(_ data: Data) throws { try RuntimeUnixSocket.write(data, to: fd) }
    func shutdownWrite() { shutdown(fd, SHUT_WR) }

    /// One read: false at EOF or when nothing came by `deadline`.
    private func fill(until deadline: Date) -> Bool? {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let wait = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard poll(&poller, 1, wait) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 {
            buffer.append(contentsOf: bytes.prefix(count))
            return true
        }
        if count < 0, errno == EINTR || errno == EAGAIN { return true }
        return false
    }

    /// Exactly `count` bytes.
    func read(_ count: Int, timeout: TimeInterval = 5) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < count {
            guard fill(until: deadline) == true else {
                throw Failure(
                    description: "\(buffer.count) of \(count) bytes: \(String(decoding: buffer, as: UTF8.self))")
            }
        }
        let taken = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(count))
        return Data(taken)
    }

    /// Everything up to the server's close.
    func readToEOF(timeout: TimeInterval = 5) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch fill(until: deadline) {
            case true: continue
            case false:
                defer { buffer = Data() }
                return buffer
            case nil: throw Failure(description: "no EOF within \(timeout) s after \(buffer.count) bytes")
            }
        }
    }

    /// True when no byte and no close arrive for `seconds`.
    func silent(for seconds: TimeInterval) throws -> Bool {
        guard buffer.isEmpty else { return false }
        return fill(until: Date().addingTimeInterval(seconds)) == nil
    }

    /// Head text (through CRLFCRLF) and body.
    static func split(_ reply: Data) -> (String, Data) {
        guard let end = reply.range(of: Data("\r\n\r\n".utf8)) else {
            return (String(decoding: reply, as: UTF8.self), Data())
        }
        return (
            String(decoding: reply[reply.startIndex..<end.upperBound], as: UTF8.self),
            Data(reply[end.upperBound...])
        )
    }
}

extension Data {
    var text: String { String(decoding: self, as: UTF8.self) }
}
