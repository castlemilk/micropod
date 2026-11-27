import Darwin
import Foundation
import MicropodCore
import NIOCore
import NIOHTTP2
import XCTest

@testable import MicropodAPI

/// The HTTP/2 transport's bounds, each driven past its limit with raw
/// frames (or the NIO client) on a real server.
final class HTTP2LimitsTests: HTTP2TestCase {
    private static let post = H2Raw.request("/echo", method: "POST") + [("content-type", "application/json")]

    private static func raw(_ served: Served, settings: [(UInt16, UInt32)] = []) throws -> H2Raw {
        let raw = H2Raw(try GoldenWire.unix(served.socket))
        try raw.start(settings: settings)
        return raw
    }

    /// MAX_CONCURRENT_STREAMS is 100: NIO ends a connection that opens a
    /// 101st with GOAWAY(PROTOCOL_ERROR) (RFC 9113 lets a stream error be
    /// treated as a connection error); the 100 already admitted ran.
    func testTheHundredAndFirstStreamEndsTheConnection() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let result = try await offPool { () -> (goAway: UInt32?, closed: Bool) in
            let raw = try Self.raw(served)
            // Let the server's SETTINGS (and our ACK) land before exceeding them.
            usleep(100_000)
            for index in 0..<100 { try raw.headers(stream: UInt32(2 * index + 1), H2Raw.request("/block")) }
            usleep(200_000)
            try raw.headers(stream: 201, H2Raw.request("/block"))
            let drained = raw.drain(timeout: 3)
            return (drained.goAway, drained.closed)
        }
        XCTAssertEqual(result.goAway, 0x1, "GOAWAY(PROTOCOL_ERROR)")
        XCTAssertTrue(result.closed)
        XCTAssertEqual(fixture.maxRunning, 100, "the first 100 were admitted, the 101st never")
        fixture.open()
    }

    /// Rapid reset: HEADERS then RST_STREAM, over and over, against handlers
    /// that never finish. In-flight handlers stay at the per-connection bound,
    /// the reset rate ends the connection with GOAWAY, and HTTP/1.1 on
    /// another connection still answers throughout.
    func testRapidResetIsBounded() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let socket = served.socket
        let peak = LockedBox(0)
        let outcome = try await offPool { () -> (goAway: UInt32?, closed: Bool) in
            let raw = try Self.raw(served)
            usleep(100_000)
            var stream: UInt32 = 1
            for _ in 0..<1000 {
                guard (try? raw.headers(stream: stream, H2Raw.request("/block"))) != nil,
                    (try? raw.reset(stream: stream)) != nil
                else { break }
                stream += 2
            }
            let drained = raw.drain(timeout: 5)
            peak.set(fixture.maxRunning)
            // HTTP/1.1 still answers on another connection.
            let wire = try GoldenWire.unix(socket)
            try wire.send("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            XCTAssertTrue(try wire.readToEOF().text.hasPrefix("HTTP/1.1 200 OK"))
            return (drained.goAway, drained.closed)
        }
        XCTAssertEqual(outcome.goAway, 0xB, "GOAWAY(ENHANCE_YOUR_CALM)")
        XCTAssertTrue(outcome.closed)
        XCTAssertLessThanOrEqual(peak.get(), 100, "never more than 100 handlers in flight")
        XCTAssertGreaterThan(peak.get(), 0)
        fixture.open()
        for _ in 0..<100 where served.server.http2?.handlers(.owner) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(served.server.http2?.handlers(.owner), 0, "every place came back once the handlers ended")
    }

    func testFloodsCloseTheConnection() async throws {
        var limits = HTTP2Limits(policy: Self.policy)
        limits.controlFrames.count = 100
        let served = try await serve(H2Fixture(), limits: limits)
        try await offPool {
            // CONTINUATION: a header block cut into more pieces than allowed.
            let continuation = try Self.raw(served)
            let block = continuation.block(H2Raw.request("/health") + [("x-pad", String(repeating: "p", count: 64))])
            let pieces = stride(from: 0, to: block.count, by: 8).map { block[$0..<min($0 + 8, block.count)] }
            try continuation.wire.send(H2Raw.frame(type: 0x1, flags: 0x1, stream: 1, Data(pieces[0])))
            for piece in pieces.dropFirst().dropLast() {
                try? continuation.wire.send(H2Raw.frame(type: 0x9, stream: 1, Data(piece)))
            }
            XCTAssertTrue(continuation.drain(timeout: 3).closed, "CONTINUATION flood")

            // PING: over the control-frame bound.
            let ping = try Self.raw(served)
            for _ in 0..<200 { try? ping.ping() }
            let pinged = ping.drain(timeout: 3)
            XCTAssertTrue(pinged.closed, "PING flood")
            XCTAssertEqual(pinged.goAway, 0xB)

            // SETTINGS: likewise.
            let settings = try Self.raw(served)
            for _ in 0..<200 { try? settings.wire.send(H2Raw.frame(type: 0x4)) }
            XCTAssertTrue(settings.drain(timeout: 3).closed, "SETTINGS flood")

            // Empty DATA frames that never end a stream.
            let empty = try Self.raw(served)
            try empty.headers(stream: 1, Self.post, endStream: false)
            for _ in 0..<10 { try? empty.data(stream: 1, Data()) }
            XCTAssertTrue(empty.drain(timeout: 3).closed, "empty DATA flood")
        }
    }

    func testHeaderListsOver64KiBAreRefused() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        /// A request with `padding` bytes of header, its block cut into
        /// frames under the 16 KiB frame size: what came back.
        func send(_ padding: Int) async throws -> (types: [UInt8], goAway: UInt32?, resets: Int) {
            try await offPool {
                let raw = try Self.raw(served)
                // The 64 KiB bound applies once the client acknowledged the
                // server's SETTINGS (RFC 9113 §6.5.3); before it, NIO's
                // HPACK default (16 KiB) does.
                usleep(100_000)
                let block = raw.block(H2Raw.request("/health") + [("x-pad", String(repeating: "a", count: padding))])
                let pieces = stride(from: 0, to: block.count, by: 16_000).map {
                    Data(block[$0..<min($0 + 16_000, block.count)])
                }
                for (index, piece) in pieces.enumerated() {
                    let last: UInt8 = index == pieces.count - 1 ? 0x4 : 0
                    let frame =
                        index == 0
                        ? H2Raw.frame(type: 0x1, flags: 0x1 | last, stream: 1, piece)
                        : H2Raw.frame(type: 0x9, flags: last, stream: 1, piece)
                    try? raw.wire.send(frame)
                }
                let drained = raw.drain(timeout: 2) { type, stream in type == 0x0 && stream == 1 }
                return (drained.types, drained.goAway, drained.resets.count)
            }
        }
        let fine = try await send(30_000)
        XCTAssertTrue(fine.types.contains(0x0), "30 KiB of headers is answered: \(fine)")
        let refused = try await send(70_000)
        XCTAssertTrue(refused.goAway != nil || refused.resets > 0, "70 KiB is refused: \(refused)")
        XCTAssertFalse(refused.types.contains(0x0))
        XCTAssertEqual(fixture.requests.count, 1, "the 70 KiB request reached no handler")
    }

    func testRequestBodyBudgets() async throws {
        var limits = HTTP2Limits(policy: Self.policy)
        limits.streamBodyBytes = 64 * 1024
        limits.connectionBodyBytes = 100 * 1024
        let fixture = H2Fixture()
        let served = try await serve(fixture, limits: limits)
        let client = try await H2Client.unix(served.socket)
        defer { client.close() }
        let big = try await client.request(
            method: "POST", path: "/echo", headers: [("content-type", "application/json")],
            body: Data(repeating: 0x61, count: 70 * 1024))
        XCTAssertEqual(big.status, 413)
        XCTAssertEqual(
            Self.json(big)?["code"] as? String, "resource_exhausted", "the reset after it does not drop the body")
        let grpc = try await client.grpc("/micropod.v1.SystemService/Ping", Data(repeating: 0, count: 70 * 1024))
        XCTAssertEqual(grpc.grpcStatus, 8, "RESOURCE_EXHAUSTED")
        let fits = try await client.request(
            method: "POST", path: "/echo", headers: [("content-type", "application/json")],
            body: Data(repeating: 0x61, count: 60 * 1024))
        XCTAssertEqual(fits.body.count, 60 * 1024)

        // Two bodies held open at once: the second goes past the
        // connection's budget before it is buffered.
        let resets = try await offPool { () -> [(stream: UInt32, code: UInt32)] in
            let raw = try Self.raw(served)
            let post = H2Raw.request("/echo", method: "POST") + [("content-type", "application/json")]
            try raw.headers(stream: 1, post, endStream: false)
            try raw.headers(stream: 3, post, endStream: false)
            try raw.data(stream: 1, Data(repeating: 0x61, count: 16_000))
            try raw.data(stream: 1, Data(repeating: 0x61, count: 16_000))
            try raw.data(stream: 1, Data(repeating: 0x61, count: 16_000))
            try raw.data(stream: 3, Data(repeating: 0x61, count: 16_000))
            try raw.data(stream: 3, Data(repeating: 0x61, count: 16_000))
            try raw.data(stream: 3, Data(repeating: 0x61, count: 16_000))
            try raw.data(stream: 3, Data(repeating: 0x61, count: 16_000))
            return raw.drain(timeout: 2) { type, stream in type == 0x3 && stream == 3 }.resets
        }
        XCTAssertEqual(resets.first?.stream, 3)
        XCTAssertEqual(resets.first?.code, 0xB, "ENHANCE_YOUR_CALM")
    }

    func testRequestAndConnectionDeadlines() async throws {
        var policy = Self.policy
        policy.requestIdle = .milliseconds(300)
        policy.keepAliveIdle = .milliseconds(400)
        var limits = HTTP2Limits(policy: policy)
        limits.firstStreamDeadline = .milliseconds(400)
        limits.writeStall = .milliseconds(400)
        let fixture = H2Fixture()
        let served = try await serve(fixture, policy: policy, limits: limits)
        try await offPool {
            // Silence mid-request: RST_STREAM(CANCEL).
            let quiet = try Self.raw(served)
            try quiet.headers(stream: 1, Self.post, endStream: false)
            let reset = quiet.drain(timeout: 3) { type, _ in type == 0x3 }.resets
            XCTAssertEqual(reset.first?.stream, 1)
            XCTAssertEqual(reset.first?.code, 0x8, "CANCEL")

            // A connection that never opens a stream is closed.
            let started = Date()
            let idle = try Self.raw(served)
            XCTAssertTrue(idle.drain(timeout: 3).closed, "no stream: closed")
            XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.3)

            // Idle after a request: GOAWAY(NO_ERROR), then the close.
            let done = try Self.raw(served)
            try done.headers(stream: 1, H2Raw.request("/health"))
            let goAway = done.drain(timeout: 3)
            XCTAssertEqual(goAway.goAway, 0x0)
            XCTAssertTrue(goAway.closed)

            // A response the client's window never lets out: reset at the write-stall deadline.
            let stalled = try Self.raw(served, settings: [(0x4, 0)])
            try stalled.headers(stream: 1, Self.post, endStream: false)
            try stalled.data(stream: 1, Data(repeating: 0x61, count: 1000), endStream: true)
            let stall = stalled.drain(timeout: 3) { type, stream in type == 0x3 && stream == 1 }.resets
            XCTAssertEqual(stall.first?.code, 0x8, "CANCEL at the write-stall deadline")
        }
    }

    /// A head refused before any handler (here a scheme that is not http),
    /// from a client that never ends its request: the answer, then
    /// RST_STREAM(NO_ERROR), so the stream is closed and the connection
    /// reaches its idle GOAWAY instead of holding its place for good.
    func testARefusedHeadThatNeverEndsIsClosed() async throws {
        var policy = Self.policy
        policy.keepAliveIdle = .milliseconds(400)
        let served = try await serve(H2Fixture(), policy: policy)
        try await offPool {
            let raw = try Self.raw(served)
            let fields = [(":method", "GET"), (":scheme", "https"), (":path", "/health")]
            try raw.headers(stream: 1, fields, endStream: false)
            let answer = raw.drain(timeout: 3)
            XCTAssertEqual(answer.types.filter { $0 == 0x1 || $0 == 0x0 }, [0x1, 0x0], "the 400 and its body")
            XCTAssertEqual(answer.resets.first?.stream, 1)
            XCTAssertEqual(answer.resets.first?.code, 0x0, "NO_ERROR")
            XCTAssertEqual(answer.goAway, 0x0, "idle: GOAWAY(NO_ERROR)")
            XCTAssertTrue(answer.closed)

            // A refused head that did end its stream needs no reset.
            let ended = try Self.raw(served)
            try ended.headers(stream: 1, fields)
            let whole = ended.drain(timeout: 3)
            XCTAssertTrue(whole.resets.isEmpty)
            XCTAssertEqual(whole.goAway, 0x0)
        }
        for _ in 0..<50 where served.server.http2?.connections(.owner) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(served.server.http2?.connections(.owner), 0, "neither connection kept its place")
    }

    /// A stream's own error (a header name in upper case, a header value
    /// with CR LF, a WINDOW_UPDATE of zero or one that overflows the window)
    /// resets that stream and leaves the connection and its other streams
    /// alone. The same WINDOW_UPDATE on stream 0 is the connection's error:
    /// GOAWAY and the close.
    func testAStreamErrorLeavesTheOtherStreamsAlone() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let post = Self.post
        @Sendable func update(_ stream: UInt32, _ increment: UInt32) -> Data {
            H2Raw.frame(type: 0x8, stream: stream, Data(withUnsafeBytes(of: increment.bigEndian) { Array($0) }))
        }
        let cases: [(String, @Sendable (H2Raw) throws -> Void)] = [
            ("header name in upper case", { try $0.headers(stream: 3, H2Raw.request("/health") + [("X-Upper", "1")]) }),
            (
                "header value with CR LF",
                { try $0.headers(stream: 3, H2Raw.request("/health") + [("x-a", "b\r\nc: d")]) }
            ),
            (
                "WINDOW_UPDATE of zero",
                {
                    try $0.headers(stream: 3, post, endStream: false)
                    try $0.wire.send(update(3, 0))
                }
            ),
            (
                "WINDOW_UPDATE past the window",
                {
                    try $0.headers(stream: 3, post, endStream: false)
                    try $0.wire.send(update(3, 0x7FFF_FFFF))
                }
            ),
        ]
        for (name, misbehave) in cases {
            let outcome = try await offPool { () -> (resets: [UInt32], goAway: UInt32?, answered: Bool) in
                let raw = try Self.raw(served)
                try raw.headers(stream: 1, H2Raw.request("/slow?ms=600"))
                usleep(100_000)
                try misbehave(raw)
                // Stream 1's answer (HEADERS then DATA) still comes.
                let drained = raw.drain(timeout: 3) { type, stream in type == 0x0 && stream == 1 }
                return (drained.resets.map(\.stream), drained.goAway, !drained.closed && drained.types.last == 0x0)
            }
            XCTAssertEqual(outcome.resets, [3], "\(name): only the stream at fault is reset")
            XCTAssertNil(outcome.goAway, "\(name): no GOAWAY")
            XCTAssertTrue(outcome.answered, "\(name): the other stream got its answer")
        }
        for (name, increment) in [("zero", UInt32(0)), ("past the window", 0x7FFF_FFFF)] {
            let drained = try await offPool { () -> (goAway: UInt32?, closed: Bool) in
                let raw = try Self.raw(served)
                try raw.headers(stream: 1, H2Raw.request("/slow?ms=600"))
                usleep(100_000)
                try raw.wire.send(update(0, increment))
                let drained = raw.drain(timeout: 3)
                return (drained.goAway, drained.closed)
            }
            XCTAssertNotNil(drained.goAway, "WINDOW_UPDATE(0, \(name)): the connection's error")
            XCTAssertNotEqual(drained.goAway, 0)
            XCTAssertTrue(drained.closed, "WINDOW_UPDATE(0, \(name)): closed after its GOAWAY")
        }
    }

    /// The watch reads NIO's output as frames whatever the buffers' cuts.
    func testTheGoAwayWatchReadsFramesAcrossBuffers() {
        let settings = H2Raw.frame(type: 0x4)
        let data = H2Raw.frame(type: 0x0, stream: 1, Data(repeating: 0x07, count: 300))
        func goAway(_ code: UInt8) -> Data {
            H2Raw.frame(type: 0x7, Data([0, 0, 0, 0, 0, 0, 0, code]) + Data("why".utf8))
        }
        for cut in [1, 2, 9, 13, 400] {
            for (code, expected) in [(UInt8(0), false), (UInt8(1), true)] {
                let watch = HTTP2GoAwayWatch()
                let bytes = settings + data + goAway(code) + settings
                var offset = 0
                while offset < bytes.count {
                    let piece = bytes[
                        (bytes.startIndex + offset)..<min(bytes.endIndex, bytes.startIndex + offset + cut)]
                    watch.scan(ByteBuffer(bytes: piece).readableBytesView)
                    offset += cut
                }
                XCTAssertEqual(watch.sentError, expected, "cut \(cut), code \(code)")
            }
        }
    }

    /// Past the HTTP/2 connection cap a client gets SETTINGS, GOAWAY and the
    /// close; HTTP/1.1 keeps its places.
    func testTheConnectionCap() async throws {
        var limits = HTTP2Limits(policy: Self.policy)
        limits.maxConnections = 2
        let served = try await serve(H2Fixture(), limits: limits)
        let first = try await H2Client.unix(served.socket)
        let second = try await H2Client.unix(served.socket)
        defer {
            first.close()
            second.close()
        }
        _ = try await first.request(path: "/health")
        _ = try await second.request(path: "/health")
        XCTAssertEqual(served.server.http2?.connections(.owner), 2)
        let socket = served.socket
        try await offPool {
            let third = try Self.raw(served)
            let refused = third.drain(timeout: 3)
            XCTAssertEqual(refused.types, [0x4, 0x7], "SETTINGS, GOAWAY")
            XCTAssertEqual(refused.goAway, 0xB)
            XCTAssertTrue(refused.closed)
            let wire = try GoldenWire.unix(socket)
            for _ in 0..<3 {
                try wire.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
                let reply = HTTP1GoldenBytesTests.kept("200 OK", "application/json", #"{"status":"ok"}"#)
                XCTAssertEqual(try wire.read(reply.utf8.count).text, reply, "HTTP/1.1 is kept as before")
            }
            XCTAssertEqual(served.server.keptConnections, 3, "two HTTP/2 connections and the HTTP/1.1 one")
            wire.shutdownWrite()
        }
    }

    /// The soak meter counts what NIO's control-frame bound counts.
    func testTheControlFrameMeterCountsAClientsPings() async throws {
        var limits = HTTP2Limits(policy: Self.policy)
        limits.logControlFrames = true
        let served = try await serve(H2Fixture(), limits: limits)
        try await offPool {
            let raw = try Self.raw(served)
            for _ in 0..<40 { try raw.ping() }
            usleep(200_000)
            raw.wire.shutdownWrite()
            _ = raw.drain(timeout: 2)
        }
        for _ in 0..<50 where HTTP2ControlFrameMeter.lastPeak.value < 40 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(HTTP2ControlFrameMeter.lastPeak.value, 42, "40 PINGs, SETTINGS and its ACK")
    }

    /// `stop()` sends GOAWAY; the unary call in flight is still answered.
    func testStopSendsGoAwayAndAnswersTheCallInFlight() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let client = try await H2Client.unix(served.socket)
        defer { client.close() }
        let call = Task { try await client.request(path: "/slow?ms=500") }
        try await Task.sleep(for: .milliseconds(150))
        served.server.stop()
        let answer = try await call.value
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), "slow")
    }

    /// A client that sends its requests and ends its side (shutdown
    /// SHUT_WR, as `nc -N` and socat do at end of input) is answered, as on
    /// HTTP/1.1, then gets GOAWAY and the close.
    func testAClientThatHalfClosesIsStillAnswered() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        for path in ["/health", "/slow?ms=300"] {
            let drained = try await offPool { () -> (types: [UInt8], goAway: UInt32?, closed: Bool) in
                let raw = try Self.raw(served)
                try raw.headers(stream: 1, H2Raw.request(path))
                raw.wire.shutdownWrite()
                let drained = raw.drain(timeout: 4)
                return (drained.types, drained.goAway, drained.closed)
            }
            XCTAssertEqual(
                drained.types.filter { $0 == 0x1 || $0 == 0x0 }, [0x1, 0x0], "\(path): HEADERS and DATA came back")
            XCTAssertEqual(drained.goAway, 0x0, "\(path): GOAWAY(NO_ERROR)")
            XCTAssertTrue(drained.closed, path)
        }
        for _ in 0..<50 where served.server.http2?.connections(.owner) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(served.server.http2?.connections(.owner), 0)
    }

    /// A request the client ended its side without finishing can never be
    /// answered: its connection closes within the GOAWAY grace.
    func testAHalfClosedConnectionWithAnUnfinishedRequestClosesWithinTheGrace() async throws {
        var limits = HTTP2Limits(policy: Self.policy)
        limits.goAwayGrace = .milliseconds(300)
        let served = try await serve(H2Fixture(), limits: limits)
        let started = Date()
        let closed = try await offPool { () -> Bool in
            let raw = try Self.raw(served)
            try raw.headers(stream: 1, Self.post, endStream: false)
            raw.wire.shutdownWrite()
            return raw.drain(timeout: 4).closed
        }
        XCTAssertTrue(closed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// The socketpair bridge leaves no descriptor behind, and carries a
    /// large response intact to a reader that takes it slowly.
    func testTheBridgeReturnsEveryDescriptor() async throws {
        let served = try await serve(H2Fixture())
        func descriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        let warm = try await H2Client.unix(served.socket)
        _ = try await warm.request(path: "/health")
        warm.close()
        for _ in 0..<50 where served.server.http2?.openConnections != 0 { try await Task.sleep(for: .milliseconds(20)) }
        let before = descriptors()
        for _ in 0..<200 {
            let client = try await H2Client.unix(served.socket)
            let health = try await client.request(path: "/health")
            XCTAssertEqual(health.status, 200)
            client.close()
        }
        for _ in 0..<150 where served.server.http2?.openConnections != 0 || HTTP2Bridge.live.value != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(served.server.http2?.openConnections, 0)
        XCTAssertEqual(HTTP2Bridge.live.value, 0)
        var after = descriptors()
        for _ in 0..<50 where after > before {
            try await Task.sleep(for: .milliseconds(20))
            after = descriptors()
        }
        XCTAssertLessThanOrEqual(after, before, "200 connections later, no descriptor is left open")
    }

    /// A response far larger than the client's windows and the bridge's
    /// buffers arrives whole, over the bridge and NIO's flow control.
    func testALargeResponseArrivesWhole() async throws {
        let served = try await serve(H2Fixture())
        let client = try await H2Client.unix(served.socket)
        defer { client.close() }
        let size = 32 * 1024 * 1024
        let answer = try await client.request(path: "/big?bytes=\(size)", timeout: .seconds(60))
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.body.count, size)
        XCTAssertEqual(answer.body, Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
    }
}
