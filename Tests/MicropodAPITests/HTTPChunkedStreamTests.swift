import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodAPI

/// A stream whose request asks for chunked framing
/// (`X-Micropod-Stream-Framing: chunked`) on a connection that persists:
/// chunked transfer coding, the connection kept for the next request; and
/// without the header, a stream exactly as before.
final class HTTPChunkedStreamTests: XCTestCase {
    private var dir: URL!
    private var servers: [HTTPServer] = []

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/mp-cs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
    }

    private static let policy = HTTPServer.ConnectionPolicy(
        requestIdle: .seconds(30), requestDeadline: .seconds(120), keepAliveIdle: .seconds(120),
        maxKeptConnections: 256)

    /// Set when `/forever`'s source is torn down.
    private static let ended = EndedFlag()

    private static func handler(_ request: HTTPRequest) async -> HTTPResponse {
        switch request.path {
        case "/echo":
            return .data(200, "application/octet-stream", Data(request.path.utf8))
        case "/stream":
            return .stream(
                200, "application/connect+proto",
                AsyncStream { continuation in
                    for frame in ["one", "two"] { continuation.yield(envelope(frame, flags: 0)) }
                    continuation.yield(Data())  // an empty event is never an empty chunk
                    continuation.yield(envelope("{}", flags: 0x02))
                    continuation.finish()
                })
        case "/slow":
            return .stream(
                200, "application/connect+proto",
                AsyncStream { continuation in
                    let task = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        continuation.yield(envelope("late", flags: 0))
                        continuation.yield(envelope("{}", flags: 0x02))
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                })
        case "/forever":
            return .stream(
                200, "application/connect+proto",
                AsyncStream { continuation in
                    let task = Task {
                        while !Task.isCancelled {
                            continuation.yield(envelope("tick", flags: 0))
                            try? await Task.sleep(for: .milliseconds(30))
                        }
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                        ended.set()
                    }
                })
        default:
            return .json(404, ["error": "not found"])
        }
    }

    private static func envelope(_ payload: String, flags: UInt8) -> Data {
        let bytes = Data(payload.utf8)
        return Data([flags]) + withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) } + bytes
    }

    private static func payloads(_ data: Data) -> [String] {
        var out: [String] = []
        var bytes = [UInt8](data)[...]
        while bytes.count >= 5 {
            let length = bytes.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard bytes.count >= 5 + length else { break }
            out.append(String(decoding: bytes.dropFirst(5).prefix(length), as: UTF8.self))
            bytes = bytes.dropFirst(5 + length)
        }
        return out
    }

    private static func post(_ path: String, host: String = "localhost", chunked: Bool = true, extra: String = "")
        -> String
    {
        "POST \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/connect+proto\r\n"
            + (chunked ? "X-Micropod-Stream-Framing: chunked\r\n" : "") + extra + "Content-Length: 0\r\n\r\n"
    }

    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async { done.resume(with: Result { try body() }) }
        }
    }

    private func ownerSocket() async throws -> (HTTPServer, String) {
        let server = HTTPServer(port: 45454, policy: Self.policy, handler: Self.handler)
        servers.append(server)
        let path = dir.appendingPathComponent("api.sock").path
        let started = await MicropodAPI.startOwnerSocket(server, path: path, log: { XCTFail($0) })
        XCTAssertEqual(started, path)
        return (server, path)
    }

    func testAStreamThatAsksForChunksKeepsTheConnectionOnBothListeners() async throws {
        let (owner, path) = try await ownerSocket()
        let port = try RawConnection.freePort()
        let tcp = HTTPServer(port: port, policy: Self.policy, handler: Self.handler)
        servers.append(tcp)
        try tcp.startListening()
        for (name, host) in [("owner socket", "localhost"), ("loopback TCP", "127.0.0.1:\(port)")] {
            try await blocking {
                let client = try name == "owner socket" ? RawConnection.unix(path) : RawConnection.tcp(port)
                for round in 0..<3 {
                    try client.write(Self.post("/stream", host: host))
                    let stream = try client.reply()
                    XCTAssertEqual(stream.status, 200, "\(name) #\(round)")
                    XCTAssertEqual(stream.statusLine, "HTTP/1.1 200 OK", name)
                    XCTAssertEqual(stream.headers["transfer-encoding"], "chunked", name)
                    XCTAssertEqual(stream.headers["x-micropod-stream-framing"], "chunked", name)
                    XCTAssertNil(stream.headers["connection"], "\(name): a kept stream says nothing")
                    XCTAssertNil(stream.headers["content-length"], name)
                    XCTAssertEqual(Self.payloads(stream.body), ["one", "two", "{}"], name)
                    // The same connection serves the next request.
                    try client.write("GET /echo HTTP/1.1\r\nHost: \(host)\r\n\r\n")
                    XCTAssertEqual(try client.reply().status, 200, "\(name): a request after the stream")
                }
                let server = name == "owner socket" ? owner : tcp
                XCTAssertEqual(server.keptConnections, 1, "\(name): its one connection waits for more")
            }
        }
    }

    func testWithoutTheHeaderOrWithConnectionCloseAStreamIsCloseDelimitedAsBefore() async throws {
        let (_, path) = try await ownerSocket()
        try await blocking {
            for request in [Self.post("/stream", chunked: false), Self.post("/stream", extra: "Connection: close\r\n")]
            {
                let client = try RawConnection.unix(path)
                try client.write(request)
                let stream = try client.reply()
                XCTAssertEqual(stream.headers["connection"], "close")
                XCTAssertNil(stream.headers["transfer-encoding"])
                XCTAssertEqual(Self.payloads(stream.body), ["one", "two", "{}"])
            }
        }
    }

    func testAClientThatClosesDuringAChunkedStreamEndsItsSource() async throws {
        let (owner, path) = try await ownerSocket()
        Self.ended.reset()
        try await blocking {
            let client = try RawConnection.unix(path)
            try client.write(Self.post("/forever"))
            XCTAssertTrue(try client.hasBytes(within: 2))
            client.close()
        }
        for _ in 0..<100 where !Self.ended.value { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(Self.ended.value, "the source kept running for a client that left")
        for _ in 0..<100 where owner.keptConnections != 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(owner.keptConnections, 0)
    }

    func testARequestSentBeforeAChunkedStreamEndedIsNotServedAndTheConnectionCloses() async throws {
        let (_, path) = try await ownerSocket()
        try await blocking {
            let client = try RawConnection.unix(path)
            try client.write(Self.post("/slow") + "GET /echo HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let stream = try client.reply()
            XCTAssertEqual(Self.payloads(stream.body), ["late", "{}"])
            XCTAssertTrue(try client.closed(within: 2), "the request behind the stream was not answered")
        }
    }
}

final class EndedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    func reset() { lock.withLock { flag = false } }
    var value: Bool { lock.withLock { flag } }
}
