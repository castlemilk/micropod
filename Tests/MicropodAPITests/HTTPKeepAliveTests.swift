import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodAPI

/// HTTP/1.1 persistent connections on the API's listeners, black box: a real
/// `HTTPServer` on a throwaway owner socket and a loopback TCP port, driven
/// with raw bytes so every header and every close is visible.
final class HTTPKeepAliveTests: XCTestCase {
    private var dir: URL!
    private var servers: [HTTPServer] = []

    override func setUpWithError() throws {
        // Short: sun_path holds 104 bytes.
        dir = URL(fileURLWithPath: "/tmp/mp-ka-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private static let quick = HTTPServer.ConnectionPolicy(
        requestIdle: .seconds(30), requestDeadline: .seconds(120), keepAliveIdle: .seconds(120),
        maxKeptConnections: 256)

    /// `/echo` answers its body (or its path when it has none), `/big` that
    /// many bytes, `/stream` three Connect frames and EOF, `/slow` after
    /// 400 ms.
    private static func handler(_ request: HTTPRequest) async -> HTTPResponse {
        switch request.path {
        case "/echo":
            return .data(200, "application/octet-stream", request.body.isEmpty ? Data(request.path.utf8) : request.body)
        case "/big":
            return .data(
                200, "application/octet-stream", Data(repeating: 0x61, count: Int(request.string("bytes")) ?? 0))
        case "/stream":
            return .stream(
                200, "application/connect+json",
                AsyncStream { continuation in
                    for frame in ["one", "two"] { continuation.yield(Self.envelope(frame, flags: 0)) }
                    continuation.yield(Self.envelope("{}", flags: 0x02))
                    continuation.finish()
                })
        case "/slow":
            try? await Task.sleep(for: .milliseconds(400))
            return .text(200, "slow")
        default:
            return .json(404, ["error": "not found"])
        }
    }

    /// A Connect envelope: flags, big-endian length, payload.
    private static func envelope(_ payload: String, flags: UInt8) -> Data {
        let bytes = Data(payload.utf8)
        let length = UInt32(bytes.count).bigEndian
        return Data([flags]) + withUnsafeBytes(of: length) { Data($0) } + bytes
    }

    private static func frames(_ data: Data) -> [(flags: UInt8, payload: String)] {
        var frames: [(UInt8, String)] = []
        var bytes = [UInt8](data)[...]
        while bytes.count >= 5 {
            let length = bytes.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard bytes.count >= 5 + length else { break }
            frames.append((bytes.first!, String(decoding: bytes.dropFirst(5).prefix(length), as: UTF8.self)))
            bytes = bytes.dropFirst(5 + length)
        }
        return frames
    }

    private func server(_ policy: HTTPServer.ConnectionPolicy = quick, port: UInt16 = 45454) -> HTTPServer {
        let server = HTTPServer(port: port, policy: policy, handler: Self.handler)
        servers.append(server)
        return server
    }

    /// The owner's socket as `main()` starts it.
    private func ownerSocket(_ server: HTTPServer) async throws -> String {
        let path = dir.appendingPathComponent("api.sock").path
        let started = await MicropodAPI.startOwnerSocket(server, path: path, log: { XCTFail($0) })
        XCTAssertEqual(started, path)
        return path
    }

    /// A loopback TCP server as `main()` starts it, on a free port.
    private func tcpServer(_ policy: HTTPServer.ConnectionPolicy = quick) throws -> (HTTPServer, UInt16) {
        let port = try RawConnection.freePort()
        let server = server(policy, port: port)
        try server.startListening()
        return (server, port)
    }

    private static func post(_ path: String, _ body: String, host: String = "localhost", extra: String = "")
        -> String
    {
        "POST \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\n\(extra)"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private static func get(
        _ path: String, host: String = "localhost", version: String = "HTTP/1.1", extra: String = ""
    )
        -> String
    {
        "GET \(path) \(version)\r\nHost: \(host)\r\n\(extra)\r\n"
    }

    /// Runs blocking socket work off Swift's cooperative pool, which also
    /// runs the server's handlers.
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async { done.resume(with: Result { try body() }) }
        }
    }

    // MARK: - Reuse

    func testOneConnectionCarriesTwoHundredSequentialRequestsOnBothListeners() async throws {
        let owner = server()
        let path = try await ownerSocket(owner)
        let (tcp, port) = try tcpServer()
        for (name, host) in [("owner socket", "localhost"), ("loopback TCP", "127.0.0.1:\(port)")] {
            try await blocking {
                let client = try name == "owner socket" ? RawConnection.unix(path) : RawConnection.tcp(port)
                for index in 0..<200 {
                    let body = "{\"n\":\(index)}"
                    try client.write(Self.post("/echo", body, host: host))
                    let reply = try client.reply()
                    XCTAssertEqual(reply.status, 200, "\(name) #\(index): \(reply.statusLine)")
                    XCTAssertEqual(reply.headers["content-length"], "\(body.utf8.count)", "\(name) #\(index)")
                    XCTAssertEqual(String(decoding: reply.body, as: UTF8.self), body, "\(name) #\(index)")
                    XCTAssertNil(reply.headers["connection"], "\(name) #\(index): a kept reply says nothing")
                    if reply.status != 200 { return }
                }
                let server = name == "owner socket" ? owner : tcp
                XCTAssertEqual(server.keptConnections, 1, "\(name): its one connection waits for more")
            }
        }
        for _ in 0..<100 where owner.keptConnections + tcp.keptConnections != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(owner.keptConnections + tcp.keptConnections, 0, "a client's close ends its connection")
    }

    func testPipelinedRequestsAreAnsweredInOrder() async throws {
        let path = try await ownerSocket(server())
        try await blocking {
            let client = try RawConnection.unix(path)
            // Three requests in one write, the second with a body.
            try client.write(Self.get("/echo") + Self.post("/echo", "second") + Self.get("/big?bytes=3"))
            XCTAssertEqual(String(decoding: try client.reply().body, as: UTF8.self), "/echo")
            XCTAssertEqual(String(decoding: try client.reply().body, as: UTF8.self), "second")
            XCTAssertEqual(String(decoding: try client.reply().body, as: UTF8.self), "aaa")
            // A pipelined request cut mid-head: the rest arrives later.
            let next = Self.post("/echo", "fourth")
            let cut = next.index(next.startIndex, offsetBy: 9)
            try client.write(Self.post("/echo", "third") + String(next[..<cut]))
            XCTAssertEqual(String(decoding: try client.reply().body, as: UTF8.self), "third")
            XCTAssertFalse(try client.hasBytes(within: 0.2), "nothing answers half a request")
            try client.write(String(next[cut...]))
            XCTAssertEqual(String(decoding: try client.reply().body, as: UTF8.self), "fourth")
        }
    }

    func testConnectionCloseAndHTTP10AreHonoured() async throws {
        let path = try await ownerSocket(server())
        try await blocking {
            for (request, why) in [
                (Self.get("/echo", extra: "Connection: close\r\n"), "Connection: close"),
                (Self.get("/echo", extra: "Connection: keep-alive, Close\r\n"), "close among other tokens"),
                (Self.get("/echo", extra: "Connection: keep-alive\r\nConnection: close\r\n"), "a second field"),
                (Self.get("/echo", version: "HTTP/1.0"), "HTTP/1.0 without keep-alive"),
            ] {
                let client = try RawConnection.unix(path)
                // A second request behind it must not be answered.
                try client.write(request + Self.get("/echo"))
                let reply = try client.reply()
                XCTAssertEqual(reply.status, 200, why)
                XCTAssertEqual(reply.headers["connection"], "close", why)
                XCTAssertTrue(try client.closed(within: 2), "\(why): closed after one reply")
            }
            // HTTP/1.0 that asks to keep the connection is told it is kept.
            let client = try RawConnection.unix(path)
            for _ in 0..<3 {
                try client.write(Self.get("/echo", version: "HTTP/1.0", extra: "Connection: keep-alive\r\n"))
                let reply = try client.reply()
                XCTAssertEqual(reply.status, 200)
                XCTAssertEqual(reply.headers["connection"], "keep-alive")
            }
        }
    }

    func testARefusedRequestClosesAKeptConnection() async throws {
        let path = try await ownerSocket(server())
        let (_, port) = try tcpServer()
        try await blocking {
            // Framing no longer trusted: 400, and nothing more on it.
            let owner = try RawConnection.unix(path)
            try owner.write(Self.get("/echo"))
            XCTAssertEqual(try owner.reply().status, 200)
            try owner.write(
                "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: nope\r\n\r\n" + Self.get("/echo"))
            let refused = try owner.reply()
            XCTAssertEqual(refused.status, 400)
            XCTAssertEqual(refused.headers["connection"], "close")
            XCTAssertTrue(try owner.closed(within: 2))

            // The request guard runs on every request of a kept TCP
            // connection: a foreign Host later on is refused and closes.
            let tcp = try RawConnection.tcp(port)
            try tcp.write(Self.get("/echo", host: "127.0.0.1:\(port)"))
            XCTAssertEqual(try tcp.reply().status, 200)
            try tcp.write(Self.get("/echo", host: "evil.example:\(port)"))
            let guarded = try tcp.reply()
            XCTAssertEqual(guarded.status, 403)
            XCTAssertEqual(guarded.headers["connection"], "close")
            XCTAssertTrue(try tcp.closed(within: 2))
        }
    }

    /// The owner socket skips the guard on every request, TCP runs it on
    /// every request: a Host without the API's port is fine on one and
    /// refused on the other, however many requests came before.
    func testAdmissionIsDecidedPerRequestOnBothListeners() async throws {
        let path = try await ownerSocket(server())
        let (_, port) = try tcpServer()
        try await blocking {
            let owner = try RawConnection.unix(path)
            for _ in 0..<5 {
                try owner.write(Self.post("/echo", "{}", host: "localhost"))
                XCTAssertEqual(try owner.reply().status, 200, "the owner socket has no port to name")
            }
            let tcp = try RawConnection.tcp(port)
            for _ in 0..<5 {
                try tcp.write(Self.post("/echo", "{}", host: "127.0.0.1:\(port)"))
                XCTAssertEqual(try tcp.reply().status, 200)
            }
            try tcp.write(Self.post("/echo", "{}", host: "localhost"))
            XCTAssertEqual(try tcp.reply().status, 403, "TCP still checks Host on the sixth request")
        }
    }

    // MARK: - Timeouts

    func testAnIdleKeptConnectionClosesSilently() async throws {
        var policy = Self.quick
        policy.keepAliveIdle = .milliseconds(300)
        let server = server(policy)
        let path = try await ownerSocket(server)
        let (tcp, port) = try tcpServer(policy)
        for name in ["owner socket", "loopback TCP"] {
            try await blocking {
                let owner = name == "owner socket"
                let client = try owner ? RawConnection.unix(path) : RawConnection.tcp(port)
                try client.write(Self.get("/echo", host: owner ? "localhost" : "127.0.0.1:\(port)"))
                XCTAssertEqual(try client.reply().status, 200, name)
                let started = Date()
                XCTAssertTrue(try client.closed(within: 3), "\(name): closed with no byte written, not a 408")
                XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2, "\(name): not before the idle timeout")
            }
        }
        for _ in 0..<50 where server.keptConnections + tcp.keptConnections != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.keptConnections + tcp.keptConnections, 0)
    }

    func testTheEnvironmentNamesTheTimeouts() {
        let policy = HTTPServer.ConnectionPolicy(environment: [
            "MICROPOD_API_KEEPALIVE_IDLE_MS": "1500", "MICROPOD_API_READ_IDLE_TIMEOUT_MS": "250",
            "MICROPOD_API_READ_DEADLINE_MS": "9000",
        ])
        XCTAssertEqual(policy.keepAliveIdle, .milliseconds(1500))
        XCTAssertEqual(policy.requestIdle, .milliseconds(250))
        XCTAssertEqual(policy.requestDeadline, .milliseconds(9000))
        let defaults = HTTPServer.ConnectionPolicy(environment: [:])
        XCTAssertEqual(defaults.keepAliveIdle, .milliseconds(120_000), "longer than Go's 90 s IdleConnTimeout")
        XCTAssertEqual(defaults.requestIdle, .milliseconds(30_000))
        XCTAssertEqual(defaults.requestDeadline, .milliseconds(120_000))
        XCTAssertEqual(defaults.maxKeptConnections, 256)
    }

    /// Between requests only the keep-alive timeout applies; once the next
    /// request's first byte arrives, the 408 clocks run as they do on a new
    /// connection.
    func testAHalfSentSecondRequestStillGets408() async throws {
        var policy = Self.quick
        policy.requestIdle = .milliseconds(250)
        policy.keepAliveIdle = .seconds(10)
        let path = try await ownerSocket(server(policy))
        try await blocking {
            let client = try RawConnection.unix(path)
            try client.write(Self.get("/echo"))
            XCTAssertEqual(try client.reply().status, 200)
            // Quiet for longer than a request may be: still open.
            XCTAssertFalse(try client.hasBytes(within: 0.6), "no 408 on an idle kept connection")
            try client.write(Self.get("/echo"))
            XCTAssertEqual(try client.reply().status, 200, "still served")
            // Half a request, then silence: 408 after the request idle time.
            let started = Date()
            try client.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nabc")
            let timedOut = try client.reply()
            XCTAssertEqual(timedOut.status, 408)
            XCTAssertEqual(timedOut.headers["connection"], "close")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the request clock, not the keep-alive one")
            XCTAssertTrue(try client.closed(within: 2))
        }
    }

    // MARK: - Limits and take-overs

    func testTheBodyLimitAppliesToTheSecondRequest() async throws {
        let path = try await ownerSocket(server())
        try await blocking {
            let client = try RawConnection.unix(path)
            try client.write(Self.post("/echo", "first"))
            XCTAssertEqual(try client.reply().status, 200)
            try client.write(
                "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                    + "Content-Length: 999999999999\r\n\r\n")
            let refused = try client.reply()
            XCTAssertEqual(refused.status, 413)
            XCTAssertEqual(refused.headers["connection"], "close")
            XCTAssertTrue(try client.closed(within: 2))
        }
    }

    /// A stream stays delimited by the close that ends it, also on a
    /// connection that carried a kept reply first.
    func testAStreamOnAKeptConnectionStillEndsWithEOF() async throws {
        let path = try await ownerSocket(server())
        try await blocking {
            let client = try RawConnection.unix(path)
            try client.write(Self.get("/echo"))
            XCTAssertNil(try client.reply().headers["connection"])
            try client.write(Self.post("/stream", "{}"))
            let stream = try client.reply()
            XCTAssertEqual(stream.status, 200)
            XCTAssertEqual(stream.headers["connection"], "close")
            XCTAssertNil(stream.headers["content-length"])
            let frames = Self.frames(stream.body)
            XCTAssertEqual(frames.map(\.payload), ["one", "two", "{}"])
            XCTAssertEqual(frames.last?.flags, 0x02, "EOF comes after the EndStream frame")
        }
    }

    /// The managed runtime's internal socket answers one request per
    /// connection whatever the client says: its gateway authenticates only
    /// the first request head on a connection.
    func testTheInternalSocketServesOneRequestPerConnection() async throws {
        let server = server()
        let path = dir.appendingPathComponent("internal.sock").path
        try await server.startPrivateSocket(path: path)
        try await blocking {
            let client = try RawConnection.unix(path)
            let second = Self.get("/echo", host: "localhost:45454")
            try client.write(Self.get("/big?bytes=2", host: "localhost:45454") + second)
            let reply = try client.reply()
            XCTAssertEqual(reply.status, 200)
            XCTAssertEqual(reply.headers["connection"], "close")
            XCTAssertTrue(try client.closed(within: 2), "the pipelined second request is never served")
        }
        XCTAssertEqual(server.keptConnections, 0)
    }

    /// Requests that were answered leave no timer behind: a client
    /// pipelining over one kept connection used to leave two or three timers
    /// per request, each holding its read and its connection, for up to
    /// 120 s.
    func testAnsweredRequestsLeaveNoTimerScheduled() async throws {
        let server = server()
        let path = try await ownerSocket(server)
        let before = HTTPServer.liveReads.value
        let client = try await blocking { () -> RawConnection in
            let client = try RawConnection.unix(path)
            for _ in 0..<20 {
                try client.write(String(repeating: Self.get("/echo"), count: 50))
                for _ in 0..<50 { XCTAssertEqual(try client.reply().status, 200) }
            }
            try client.write(Self.get("/echo"))
            XCTAssertEqual(try client.reply().status, 200)
            return client
        }
        var live = HTTPServer.liveReads.value - before
        for _ in 0..<100 where live > 1 {
            try await Task.sleep(for: .milliseconds(20))
            live = HTTPServer.liveReads.value - before
        }
        XCTAssertEqual(live, 1, "only the kept connection's wait for its next request is scheduled")
        XCTAssertEqual(server.keptConnections, 1)
        client.close()
    }

    func testKeptConnectionsAreBounded() async throws {
        var policy = Self.quick
        policy.maxKeptConnections = 1
        let server = server(policy)
        let path = try await ownerSocket(server)
        try await blocking {
            let first = try RawConnection.unix(path)
            try first.write(Self.get("/echo"))
            XCTAssertNil(try first.reply().headers["connection"], "the first is kept")
            let second = try RawConnection.unix(path)
            try second.write(Self.get("/echo"))
            let over = try second.reply()
            XCTAssertEqual(over.status, 200, "past the bound a request is still answered")
            XCTAssertEqual(over.headers["connection"], "close")
            XCTAssertTrue(try second.closed(within: 2))
            first.close()
        }
        for _ in 0..<100 where server.keptConnections != 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.keptConnections, 0, "a client's close frees its place")
        try await blocking {
            let third = try RawConnection.unix(path)
            try third.write(Self.get("/echo"))
            XCTAssertNil(try third.reply().headers["connection"], "the freed place is used again")
        }
    }

    /// Loopback TCP, which any local process reaches, holding every place
    /// it may keep does not cost the owner socket its kept connections.
    func testTCPConnectionsCannotTakeTheOwnerSocketsPlaces() async throws {
        var policy = Self.quick
        policy.maxKeptConnections = 1
        let server = server(policy, port: try RawConnection.freePort())
        let path = try await ownerSocket(server)
        try server.startListening()
        try await blocking {
            let tcp = try RawConnection.tcp(server.port)
            try tcp.write(Self.get("/echo", host: "127.0.0.1:\(server.port)"))
            XCTAssertNil(try tcp.reply().headers["connection"], "TCP keeps its one place")
            let other = try RawConnection.tcp(server.port)
            try other.write(Self.get("/echo", host: "127.0.0.1:\(server.port)"))
            XCTAssertEqual(try other.reply().headers["connection"], "close", "TCP is at its bound")
            let owner = try RawConnection.unix(path)
            for _ in 0..<3 {
                try owner.write(Self.get("/echo"))
                let reply = try owner.reply()
                XCTAssertEqual(reply.status, 200)
                XCTAssertNil(reply.headers["connection"], "the owner socket keeps its connection")
            }
            XCTAssertEqual(server.keptConnections, 2)
            tcp.close()
            owner.close()
        }
    }

    func testStopClosesIdleConnectionsAndAnswersTheOneInFlight() async throws {
        let server = server()
        let path = try await ownerSocket(server)
        let idle = try await blocking { () -> RawConnection in
            let client = try RawConnection.unix(path)
            try client.write(Self.get("/echo"))
            XCTAssertEqual(try client.reply().status, 200)
            return client
        }
        let busy = try await blocking { () -> RawConnection in
            let client = try RawConnection.unix(path)
            try client.write(Self.get("/slow"))
            return client
        }
        try await Task.sleep(for: .milliseconds(100))
        server.stop()
        try await blocking {
            XCTAssertTrue(try idle.closed(within: 2), "an idle kept connection closes at stop")
            let reply = try busy.reply()
            XCTAssertEqual(String(decoding: reply.body, as: UTF8.self), "slow", "the request in flight is answered")
            XCTAssertEqual(reply.headers["connection"], "close")
            XCTAssertTrue(try busy.closed(within: 2))
        }
    }

    /// A reply longer than one segment is not held back on a kept TCP
    /// connection: there is no close to flush its tail past Nagle while the
    /// client delays its ACK.
    func testLongRepliesOnAKeptTCPConnectionAreNotHeldBack() async throws {
        let (_, port) = try tcpServer()
        try await blocking {
            let client = try RawConnection.tcp(port)
            var slowest = 0.0
            // Lengths just past one or a few 16 KiB loopback segments.
            for bytes in [100_000, 16_400, 17_000, 32_800, 49_100, 16_390, 70_000, 33_333] {
                let started = Date()
                try client.write(Self.get("/big?bytes=\(bytes)", host: "127.0.0.1:\(port)"))
                let reply = try client.reply()
                slowest = max(slowest, Date().timeIntervalSince(started))
                XCTAssertEqual(reply.body.count, bytes)
            }
            // Sub-millisecond when nothing holds a tail back; a delayed-ACK
            // stall is 100 ms or more.
            XCTAssertLessThan(slowest, 0.08, "slowest long reply took \(slowest) s")
        }
    }

    // MARK: - Persistence rules

    func testPersistenceFollowsTheVersionAndEveryConnectionToken() {
        XCTAssertEqual(HTTPPersistence(version: "HTTP/1.1", connection: nil), .persistent)
        XCTAssertEqual(HTTPPersistence(version: "HTTP/1.1", connection: "keep-alive"), .persistent)
        XCTAssertEqual(HTTPPersistence(version: "HTTP/1.1", connection: "Close"), .close)
        XCTAssertEqual(HTTPPersistence(version: "HTTP/1.1", connection: "TE, close"), .close)
        XCTAssertEqual(HTTPPersistence(version: "HTTP/1.0", connection: nil), .close)
        XCTAssertEqual(HTTPPersistence(version: "HTTP/1.0", connection: "Keep-Alive"), .announced)
        XCTAssertEqual(HTTPPersistence(version: "HTTP/1.0", connection: "keep-alive, close"), .close)
    }

    func testTheParserReportsTheBytesARequestOccupied() throws {
        let first = "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi"
        let second = "GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        guard case .request(let request, let persistence, let consumed) = HTTPParser.parse(Data((first + second).utf8))
        else { return XCTFail("the first request is complete") }
        XCTAssertEqual(request.path, "/a")
        XCTAssertEqual(persistence, .persistent)
        XCTAssertEqual(consumed, first.utf8.count)
        guard case .request(let next, let nextPersistence, _) = HTTPParser.parse(Data(second.utf8)) else {
            return XCTFail("the second request is complete")
        }
        XCTAssertEqual(next.path, "/b")
        XCTAssertEqual(nextPersistence, .close)
    }

    /// Transfer-Encoding with Content-Length: the chunks frame the body, and
    /// the connection closes after the reply, so bytes a Content-Length
    /// reader would take for the next request are never served.
    func testARequestWithBothFramingsClosesItsConnection() throws {
        let both =
            "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        guard case .request(let request, let persistence, let consumed) = HTTPParser.parse(Data(both.utf8)) else {
            return XCTFail("the request is complete")
        }
        XCTAssertEqual(request.body, Data())
        XCTAssertEqual(consumed, both.utf8.count)
        XCTAssertEqual(persistence, .close)
        let chunkedOnly = "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        guard case .request(_, let kept, _) = HTTPParser.parse(Data(chunkedOnly.utf8)) else {
            return XCTFail("the chunked request is complete")
        }
        XCTAssertEqual(kept, .persistent)
    }
}

/// One raw client connection: writes bytes and reads replies framed by
/// Content-Length (or, without one, by EOF).
final class RawConnection: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    struct Reply {
        let statusLine: String
        let status: Int
        /// Lowercased names.
        let headers: [String: String]
        let body: Data
    }

    private var fd: Int32
    private var buffer = Data()

    private init(fd: Int32) { self.fd = fd }
    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    static func unix(_ path: String) throws -> RawConnection {
        RawConnection(fd: try RuntimeUnixSocket.connect(path, expectedUID: getuid()))
    }

    /// 127.0.0.1:`port`, retried while the listener comes up.
    static func tcp(_ port: UInt16) throws -> RawConnection {
        let deadline = Date().addingTimeInterval(3)
        while true {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = loopback(port)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return RawConnection(fd: fd) }
            Darwin.close(fd)
            guard Date() < deadline else { throw Failure(description: "127.0.0.1:\(port) never accepted") }
            usleep(20_000)
        }
    }

    /// A loopback port nobody listens on right now.
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = loopback(0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw Failure(description: "no free loopback port") }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    func write(_ text: String) throws { try RuntimeUnixSocket.write(Data(text.utf8), to: fd) }

    private enum Read { case data, eof, timeout }

    private func read(until deadline: Date) -> Read {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let wait = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard poll(&poller, 1, wait) > 0 else { return .timeout }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 {
            buffer.append(contentsOf: bytes.prefix(count))
            return .data
        }
        if count < 0, errno == EINTR || errno == EAGAIN { return .data }
        return .eof
    }

    private func take(_ count: Int) -> Data {
        let taken = buffer.prefix(count)
        buffer = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: taken.count)..<buffer.endIndex)
        return Data(taken)
    }

    func reply(timeout: TimeInterval = 5) throws -> Reply {
        let deadline = Date().addingTimeInterval(timeout)
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            switch read(until: deadline) {
            case .data: continue
            case .eof: throw Failure(description: "closed before a reply head (\(buffer.count) bytes)")
            case .timeout: throw Failure(description: "no reply head within \(timeout) s")
            }
        }
        let split = buffer.range(of: terminator)!
        let headText = String(decoding: buffer[buffer.startIndex..<split.lowerBound], as: UTF8.self)
        _ = take(buffer.distance(from: buffer.startIndex, to: split.upperBound))
        let lines = headText.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
        }
        let status = Int(lines[0].split(separator: " ").dropFirst().first ?? "") ?? 0
        if headers["transfer-encoding"] == "chunked" {
            // Chunks up to the zero-length one; the connection stays open.
            var body = Data()
            let crlf = Data("\r\n".utf8)
            while true {
                while buffer.range(of: crlf) == nil {
                    guard read(until: deadline) == .data else { throw Failure(description: "chunk size cut short") }
                }
                let line = buffer.range(of: crlf)!
                let size =
                    Int(String(decoding: buffer[buffer.startIndex..<line.lowerBound], as: UTF8.self), radix: 16) ?? -1
                guard size >= 0 else { throw Failure(description: "malformed chunk size") }
                _ = take(buffer.distance(from: buffer.startIndex, to: line.upperBound))
                while buffer.count < size + 2 {
                    guard read(until: deadline) == .data else { throw Failure(description: "chunk cut short") }
                }
                body.append(take(size))
                guard take(2) == crlf else { throw Failure(description: "a chunk without its CRLF") }
                if size == 0 { break }
            }
            return Reply(statusLine: lines[0], status: status, headers: headers, body: body)
        }
        if let length = headers["content-length"].flatMap({ Int($0) }) {
            while buffer.count < length {
                guard read(until: deadline) == .data else {
                    throw Failure(description: "body cut short: \(buffer.count) of \(length) bytes")
                }
            }
            return Reply(statusLine: lines[0], status: status, headers: headers, body: take(length))
        }
        while read(until: deadline) == .data {}
        return Reply(statusLine: lines[0], status: status, headers: headers, body: take(buffer.count))
    }

    /// True when the server closes within `timeout` without another byte.
    func closed(within timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let before = buffer.count
            switch read(until: deadline) {
            case .eof: return buffer.isEmpty
            case .timeout: return false
            case .data where buffer.count > before: return false
            case .data: continue
            }
        }
    }

    /// True when any byte arrives within `timeout`.
    func hasBytes(within timeout: TimeInterval) throws -> Bool {
        if !buffer.isEmpty { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch read(until: deadline) {
            case .data where !buffer.isEmpty: return true
            case .eof: return true
            default: continue
            }
        }
        return false
    }
}

/// The kept-connection bound and the open-file limit: launchd starts the
/// API with a soft limit of 256, which used to equal the bound, so the fd
/// table filled (EMFILE on every listener) before the bound applied.
final class FileDescriptorLimitTests: XCTestCase {
    func testTheKeptBoundLeavesMostDescriptorsToEverythingElse() {
        XCTAssertEqual(HTTPServer.ConnectionPolicy(environment: [:], fileLimit: 256).maxKeptConnections, 32)
        XCTAssertEqual(HTTPServer.ConnectionPolicy(environment: [:], fileLimit: 10_240).maxKeptConnections, 256)
        XCTAssertEqual(HTTPServer.ConnectionPolicy(environment: [:], fileLimit: 0).maxKeptConnections, 0)
    }

    func testStartUpRaisesALaunchdSoftLimit() throws {
        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &saved), 0)
        defer { _ = setrlimit(RLIMIT_NOFILE, &saved) }
        var low = saved
        low.rlim_cur = 256
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &low), 0)
        XCTAssertEqual(FileDescriptorLimit.soft(), 256)
        let raised = FileDescriptorLimit.raise()
        XCTAssertEqual(raised, Int(clamping: min(rlim_t(FileDescriptorLimit.target), saved.rlim_max)))
        XCTAssertEqual(FileDescriptorLimit.soft(), raised)
        XCTAssertEqual(
            HTTPServer.ConnectionPolicy(environment: [:], fileLimit: raised).maxKeptConnections, 256,
            "a raised limit leaves room for the full bound")
        // Never lowered.
        XCTAssertEqual(FileDescriptorLimit.raise(to: 300), raised)
    }
}
