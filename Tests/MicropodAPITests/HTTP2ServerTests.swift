import Darwin
import Foundation
import MicropodCore
import NIOCore
import NIOHTTP2
import SwiftProtobuf
import XCTest

@testable import MicropodAPI

/// Handlers the HTTP/2 tests serve: the shapes the real routes answer with,
/// recording every request a handler saw.
final class H2Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [HTTPRequest] = []
    private var running = 0
    private(set) var maxRunning = 0
    private var terminations = 0
    /// `/block` waits until this opens.
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Apply the dedicated runtime's request policy, as `APIHandlers.handle` does.
    var isolatedPolicy = false

    var requests: [HTTPRequest] { lock.withLock { seen } }
    var count: Int { lock.withLock { seen.count } }
    var inFlight: Int { lock.withLock { running } }
    var streamsEnded: Int { lock.withLock { terminations } }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gateOpen = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }

    private func blocked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if gateOpen { return true }
                waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    static func ping(_ request: HTTPRequest) -> HTTPResponse {
        let message = Micropod_V1_PingResponse.with {
            $0.status = "running"
            $0.runtimeBackend = "fixture"
        }
        if request.headers["content-type"]?.hasPrefix("application/proto") == true {
            return .data(200, "application/proto", try! message.serializedData())
        }
        return .data(200, "application/json", try! message.jsonUTF8Data())
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        lock.withLock {
            seen.append(request)
            running += 1
            maxRunning = max(maxRunning, running)
        }
        defer { lock.withLock { running -= 1 } }
        if isolatedPolicy, !IsolatedRuntimeRequestPolicy.allows(request.path) {
            return .json(403, ["code": "permission_denied", "message": "dedicated runtime control"])
        }
        if request.method == .options { return .data(204, "text/plain", Data()) }
        switch request.path {
        case "/health":
            return .json(200, ["status": "ok"])
        case "/api/micropod.v1.SystemService/Ping":
            return Self.ping(request)
        case "/api/micropod.v1.ContainerService/GetContainer":
            return .data(404, "application/json", Data(#"{"code":"not_found","message":"no such container"}"#.utf8))
        case "/api/micropod.v1.RigService/SetRigMode", "/api/micropod.v1.MicropodService/SetRigMode":
            return .json(200, [:])
        case "/api/micropod.v1.ContainerService/StreamContainerLogs":
            return logs(request)
        case "/v1/containers/x/logs":
            return .stream(
                200, "text/event-stream",
                AsyncStream { continuation in
                    continuation.yield(Data("data: one\n\n".utf8))
                    continuation.finish()
                })
        case "/block":
            await blocked()
            return .text(200, "unblocked")
        case "/slow":
            try? await Task.sleep(for: .milliseconds(Int(request.string("ms")) ?? 300))
            return .text(200, "slow")
        case "/echo":
            return .data(200, "application/octet-stream", request.body)
        case "/big":
            let count = Int(request.string("bytes")) ?? 0
            return .data(200, "application/octet-stream", Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        default:
            return .json(404, ["error": "not found"])
        }
    }

    /// A Connect server stream: `lines` LogChunks then EndStream; id
    /// `fail` ends with not_found, `follow` never ends.
    private func logs(_ request: HTTPRequest) -> HTTPResponse {
        let binary = request.headers["content-type"] == "application/connect+proto"
        var reader = ConnectEnvelopeReader()
        let frame = reader.feed(request.body).first?.payload ?? Data()
        let ask =
            (binary
                ? try? Micropod_V1_StreamLogsRequest(serializedBytes: frame)
                : try? Micropod_V1_StreamLogsRequest(jsonUTF8Data: frame)) ?? Micropod_V1_StreamLogsRequest()
        let lines = ask.tail > 0 ? Int(ask.tail) : 3
        let encode: @Sendable (String) -> Data = { text in
            let chunk = Micropod_V1_LogChunk.with { $0.text = text }
            return ConnectEnvelope.frame(binary ? try! chunk.serializedData() : try! chunk.jsonUTF8Data(), flags: 0)
        }
        return .stream(
            200, binary ? "application/connect+proto" : "application/connect+json",
            AsyncStream { continuation in
                let task = Task {
                    for index in 0..<lines { continuation.yield(encode("line \(index)")) }
                    switch ask.id {
                    case "fail":
                        continuation.yield(
                            ConnectEnvelope.frame(
                                Data(#"{"error":{"code":"not_found","message":"no such container"}}"#.utf8),
                                flags: 0x02))
                    case "follow":
                        var index = lines
                        while !Task.isCancelled {
                            continuation.yield(encode("line \(index)"))
                            index += 1
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                    case "nostatus":
                        break
                    default:
                        continuation.yield(ConnectEnvelope.frame(Data("{}".utf8), flags: 0x02))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { [weak self] _ in
                    task.cancel()
                    self?.lock.withLock { self?.terminations += 1 }
                }
            })
    }
}

/// A server on a throwaway owner socket and loopback port, and clients for it.
class HTTP2TestCase: XCTestCase {
    var dir: URL!
    var servers: [HTTPServer] = []

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/mp-h2-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
    }

    static let policy = HTTPServer.ConnectionPolicy(
        requestIdle: .seconds(30), requestDeadline: .seconds(120), keepAliveIdle: .seconds(120),
        maxKeptConnections: 256)

    struct Served {
        let server: HTTPServer
        let socket: String
        let port: UInt16
    }

    /// A server on a throwaway owner socket and a loopback port.
    func serve(
        _ fixture: H2Fixture, policy: HTTPServer.ConnectionPolicy = policy, limits: HTTP2Limits? = nil,
        isolatedRuntime: Bool = false, admission: RuntimeAdmission? = nil, http2Enabled: Bool = true
    ) async throws -> Served {
        let port = try RawConnection.freePort()
        let server = HTTPServer(
            port: port, policy: policy, isolatedRuntime: isolatedRuntime,
            runtimeAdmission: admission ?? RuntimeAdmission(root: dir.appendingPathComponent("admission")),
            http2: limits, http2Enabled: http2Enabled, handler: fixture.handle)
        servers.append(server)
        let path = dir.appendingPathComponent("api.sock").path
        let started = await MicropodAPI.startOwnerSocket(server, path: path, log: { XCTFail($0) })
        XCTAssertEqual(started, path)
        try server.startListening()
        return Served(server: server, socket: path, port: port)
    }

    func clients(_ served: Served) async throws -> [(name: String, client: H2Client, authority: String)] {
        [
            ("owner socket", try await H2Client.unix(served.socket), "localhost"),
            ("loopback TCP", try await H2Client.tcp(served.port), "127.0.0.1:\(served.port)"),
        ]
    }

    static func json(_ response: H2Response) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    }

}

final class HTTP2ServerTests: HTTP2TestCase {
    // MARK: - REST and Connect

    func testRESTAndConnectUnaryAnswerOnBothListeners() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        for (name, client, authority) in try await clients(served) {
            let health = try await client.request(path: "/health", authority: authority)
            XCTAssertEqual(health.status, 200, name)
            XCTAssertEqual(health.header("content-type"), "application/json", name)
            XCTAssertEqual(health.header("x-micropod-codecs"), "json,proto", name)
            XCTAssertEqual(health.header("content-length"), "15", name)
            XCTAssertEqual(String(decoding: health.body, as: UTF8.self), #"{"status":"ok"}"#, name)

            let json = try await client.request(
                method: "POST", path: "/api/micropod.v1.SystemService/Ping", authority: authority,
                headers: [("content-type", "application/json")], body: Data("{}".utf8))
            XCTAssertEqual(json.status, 200, name)
            XCTAssertEqual(json.header("content-type"), "application/json", name)
            XCTAssertEqual(try Micropod_V1_PingResponse(jsonUTF8Data: json.body).status, "running", name)

            let proto = try await client.request(
                method: "POST", path: "/api/micropod.v1.SystemService/Ping", authority: authority,
                headers: [("content-type", "application/proto")], body: Data())
            XCTAssertEqual(proto.header("content-type"), "application/proto", name)
            XCTAssertEqual(try Micropod_V1_PingResponse(serializedBytes: proto.body).runtimeBackend, "fixture", name)

            let posted = try await client.request(
                method: "POST", path: "/echo?x=1", authority: authority,
                headers: [("content-type", "application/json")], body: Data(#"{"a":1}"#.utf8))
            XCTAssertEqual(String(decoding: posted.body, as: UTF8.self), #"{"a":1}"#, name)

            let missing = try await client.request(path: "/nowhere", authority: authority)
            XCTAssertEqual(missing.status, 404, name)
            client.close()
        }
        XCTAssertEqual(fixture.requests.last?.query, [:])
        XCTAssertTrue(fixture.requests.contains { $0.path == "/echo" && $0.query == ["x": "1"] })
    }

    func testConnectStreamsAndSSE() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        for (name, client, authority) in try await clients(served) {
            let request = try Micropod_V1_StreamLogsRequest.with { $0.id = "c1" }.jsonUTF8Data()
            let stream = try await client.request(
                method: "POST", path: "/api/micropod.v1.ContainerService/StreamContainerLogs", authority: authority,
                headers: [("content-type", "application/connect+json")],
                body: ConnectEnvelope.frame(request, flags: 0))
            XCTAssertEqual(stream.status, 200, name)
            XCTAssertEqual(stream.header("content-type"), "application/connect+json", name)
            var reader = ConnectEnvelopeReader()
            let frames = reader.feed(stream.body)
            XCTAssertEqual(frames.map(\.flags), [0, 0, 0, 0x02], name)
            XCTAssertEqual(
                try frames.dropLast().map { try Micropod_V1_LogChunk(jsonUTF8Data: $0.payload).text },
                ["line 0", "line 1", "line 2"], name)

            let sse = try await client.request(path: "/v1/containers/x/logs", authority: authority)
            XCTAssertEqual(sse.header("content-type"), "text/event-stream", name)
            XCTAssertEqual(sse.header("cache-control"), "no-cache", name)
            XCTAssertEqual(String(decoding: sse.body, as: UTF8.self), "data: one\n\n", name)
            client.close()
        }
    }

    // MARK: - gRPC

    func testGRPCUnaryOnBareAndAPIPaths() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        for (name, client, authority) in try await clients(served) {
            for path in ["/micropod.v1.SystemService/Ping", "/api/micropod.v1.SystemService/Ping"] {
                let ping = try await client.grpc(path, Data(), authority: authority)
                XCTAssertEqual(ping.status, 200, "\(name) \(path)")
                XCTAssertEqual(ping.header("content-type"), "application/grpc", "\(name) \(path)")
                XCTAssertEqual(ping.grpcStatus, 0, "\(name) \(path)")
                XCTAssertEqual(ping.grpcMessages.count, 1, "\(name) \(path)")
                XCTAssertEqual(
                    try Micropod_V1_PingResponse(serializedBytes: ping.grpcMessages[0]).status, "running",
                    "\(name) \(path)")
            }
            let json = try await client.grpc(
                "/micropod.v1.SystemService/Ping", Data("{}".utf8), contentType: "application/grpc+json",
                authority: authority)
            XCTAssertEqual(json.header("content-type"), "application/grpc+json", name)
            XCTAssertEqual(try Micropod_V1_PingResponse(jsonUTF8Data: json.grpcMessages[0]).status, "running", name)

            let missing = try await client.grpc(
                "/micropod.v1.ContainerService/GetContainer",
                try Micropod_V1_ContainerRef.with { $0.id = "nope" }.serializedData(), authority: authority)
            XCTAssertEqual(missing.grpcStatus, 5, "\(name): not_found")
            XCTAssertEqual(missing.grpcMessage, "no such container", name)
            XCTAssertNil(missing.trailers, "\(name): Trailers-Only")

            let unknown = try await client.grpc("/micropod.v1.SystemService/Teleport", Data(), authority: authority)
            XCTAssertEqual(unknown.grpcStatus, 12, "\(name): unimplemented")
            client.close()
        }
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/Teleport") }, "no handler ran for it")
        let seen = fixture.requests.filter { $0.path == "/api/micropod.v1.SystemService/Ping" }
        XCTAssertEqual(Set(seen.map { $0.headers["content-type"] ?? "" }), ["application/proto", "application/json"])
    }

    /// A method no service declares (reflection here) or a client stream is
    /// refused from its headers, without waiting for a body that a
    /// bidirectional client never ends.
    func testUnknownGRPCMethodsAreRefusedFromTheirHeaders() async throws {
        let served = try await serve(H2Fixture())
        let drained = try await offPool { () -> (types: [UInt8], resets: [(stream: UInt32, code: UInt32)]) in
            let raw = H2Raw(try GoldenWire.unix(served.socket))
            try raw.start()
            for (stream, path) in [
                (UInt32(1), "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"),
                (3, "/micropod.v1.SystemService/Teleport"),
            ] {
                try raw.headers(
                    stream: stream,
                    H2Raw.request(path, method: "POST") + [("content-type", "application/grpc"), ("te", "trailers")],
                    endStream: false)
            }
            let result = raw.drain(timeout: 3) { type, stream in type == 0x3 && stream == 3 }
            return (result.types, result.resets)
        }
        XCTAssertEqual(drained.types.filter { $0 == 0x1 }.count, 2, "a Trailers-Only answer for each")
        XCTAssertEqual(Set(drained.resets.map(\.stream)), [1, 3])
        XCTAssertTrue(drained.resets.allSatisfy { $0.code == 0 }, "then RST_STREAM(NO_ERROR)")
    }

    func testGRPCServerStreamsEndInTheirStatus() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let client = try await H2Client.unix(served.socket)
        defer { client.close() }
        func logs(_ id: String) async throws -> H2Response {
            try await client.grpc(
                "/micropod.v1.ContainerService/StreamContainerLogs",
                try Micropod_V1_StreamLogsRequest.with { $0.id = id }.serializedData())
        }
        let ok = try await logs("c1")
        XCTAssertEqual(ok.grpcStatus, 0)
        XCTAssertEqual(
            try ok.grpcMessages.map { try Micropod_V1_LogChunk(serializedBytes: $0).text },
            ["line 0", "line 1", "line 2"])
        let failed = try await logs("fail")
        XCTAssertEqual(failed.grpcMessages.count, 3)
        XCTAssertEqual(failed.grpcStatus, 5)
        XCTAssertEqual(failed.grpcMessage, "no such container")
        let cut = try await logs("nostatus")
        XCTAssertEqual(cut.grpcStatus, 13, "a stream without its EndStream is INTERNAL")
        let request = fixture.requests.first { $0.path.hasSuffix("/StreamContainerLogs") }
        XCTAssertEqual(request?.headers["content-type"], "application/connect+proto")
    }

    func testGRPCHealth() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let client = try await H2Client.tcp(served.port)
        defer { client.close() }
        let authority = "127.0.0.1:\(served.port)"
        let check = try await client.grpc("/grpc.health.v1.Health/Check", Data(), authority: authority)
        XCTAssertEqual(check.grpcStatus, 0)
        XCTAssertEqual(check.grpcMessages, [Data([0x08, 0x01])], "SERVING")
        let named = try await client.grpc(
            "/grpc.health.v1.Health/Check", Data([0x0A, 0x19]) + Data("micropod.v1.SystemService".utf8),
            authority: authority)
        XCTAssertEqual(named.grpcMessages, [Data([0x08, 0x01])])
        let unknown = try await client.grpc(
            "/grpc.health.v1.Health/Check", Data([0x0A, 0x03]) + Data("foo".utf8), authority: authority)
        XCTAssertEqual(unknown.grpcStatus, 5)
        let foreign = try await client.grpc("/grpc.health.v1.Health/Check", Data(), authority: "evil.example")
        XCTAssertEqual(foreign.grpcStatus, 7, "health passes the guard too")

        // Watch: one status, then held open until the client cancels.
        let watched = expectation(description: "watch answered")
        let streamBox = LockedBox<(any Channel)?>(nil)
        let watch = Task {
            try await client.request(
                method: "POST", path: "/grpc.health.v1.Health/Watch", authority: authority,
                headers: [("content-type", "application/grpc")], body: GRPCWire.message(Data()), timeout: .seconds(30),
                onStream: { stream in streamBox.set(stream) })
        }
        Task {
            for _ in 0..<100 {
                if served.server.http2?.handlers(.tcp) == 0, streamBox.get() != nil { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            watched.fulfill()
        }
        await fulfillment(of: [watched], timeout: 5)
        XCTAssertEqual(served.server.http2?.handlers(.tcp), 0, "Watch frees its handler place")
        streamBox.get()?.close(promise: nil)
        let ended = try await watch.value
        XCTAssertTrue(ended.reset != nil || ended.lost || ended.status == 200)
    }

    // MARK: - One path

    func testAllThreeTransportsHandTheHandlerTheSameRequest() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let body = try Micropod_V1_ContainerRef.with { $0.id = "c9" }.serializedData()
        try await offPool {
            let wire = try GoldenWire.tcp(served.port)
            try wire.send(
                "POST /api/micropod.v1.ContainerService/GetContainer HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\n"
                    + "Content-Type: application/proto\r\nContent-Length: \(body.count)\r\n\r\n")
            try wire.send(body)
            _ = try wire.read(10)
        }
        let client = try await H2Client.tcp(served.port)
        defer { client.close() }
        _ = try await client.request(
            method: "POST", path: "/api/micropod.v1.ContainerService/GetContainer",
            authority: "127.0.0.1:\(served.port)", headers: [("content-type", "application/proto")], body: body)
        _ = try await client.grpc(
            "/micropod.v1.ContainerService/GetContainer", body, authority: "127.0.0.1:\(served.port)")
        let seen = fixture.requests
        XCTAssertEqual(seen.count, 3)
        for request in seen {
            XCTAssertEqual(request.method, .post)
            XCTAssertEqual(request.path, "/api/micropod.v1.ContainerService/GetContainer")
            XCTAssertEqual(request.body, body)
            XCTAssertEqual(request.headers["host"], "127.0.0.1:\(served.port)")
            XCTAssertEqual(request.headers["content-type"], "application/proto")
        }
    }

    // MARK: - The guard

    func testTheGuardHoldsOnTCPForHTTP2AndGRPC() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let client = try await H2Client.tcp(served.port)
        defer { client.close() }
        let good = "127.0.0.1:\(served.port)"
        for authority in ["evil.example", "evil.example:\(served.port)", "127.0.0.1:1", "localhost"] as [String?] + [
            nil
        ] {
            let rest = try await client.request(path: "/health", authority: authority)
            XCTAssertEqual(rest.status, 403, "authority \(authority ?? "none")")
            let grpc = try await client.request(
                method: "POST", path: "/micropod.v1.SystemService/Ping", authority: authority,
                headers: [("content-type", "application/grpc")], body: GRPCWire.message(Data()))
            XCTAssertEqual(grpc.grpcStatus, 7, "authority \(authority ?? "none")")
        }
        let origin = try await client.request(
            path: "/health", authority: good, headers: [("origin", "https://evil.example")])
        XCTAssertEqual(origin.status, 403)
        let plain = try await client.request(
            method: "POST", path: "/api/micropod.v1.SystemService/Ping", authority: good,
            headers: [("content-type", "text/plain")], body: Data("{}".utf8))
        XCTAssertEqual(plain.status, 415)
        let differing = try await client.request(
            path: "/health", authority: good, headers: [("host", "evil.example:\(served.port)")])
        XCTAssertEqual(differing.status, 400, "a host field that differs from :authority")
        let twice = try await client.request(
            method: "POST", path: "/echo", authority: good,
            headers: [("content-type", "application/json"), ("content-type", "text/plain")], body: Data("{}".utf8))
        XCTAssertEqual(twice.status, 400, "a repeated content-type")
        XCTAssertEqual(fixture.count, 0, "no refused request reached a handler")

        // The owner socket takes the same requests (no guard, as for HTTP/1.1).
        let owner = try await H2Client.unix(served.socket)
        defer { owner.close() }
        let ownerHealth = try await owner.request(path: "/health", authority: "anything")
        XCTAssertEqual(ownerHealth.status, 200)
        let ownerPing = try await owner.grpc("/micropod.v1.SystemService/Ping", Data(), authority: "x")
        XCTAssertEqual(ownerPing.grpcStatus, 0)
        let allowed = try await client.request(
            path: "/health", authority: good, headers: [("origin", "http://localhost:3000")])
        XCTAssertEqual(allowed.header("access-control-allow-origin"), "http://localhost:3000")
    }

    // MARK: - The dedicated runtime

    func testTheIsolatedRuntimePolicySeesTheCanonicalPath() async throws {
        let fixture = H2Fixture()
        fixture.isolatedPolicy = true
        let served = try await serve(fixture)
        let client = try await H2Client.unix(served.socket)
        defer { client.close() }
        let connect = try await client.request(
            method: "POST", path: "/api/micropod.v1.RigService/SetRigMode",
            headers: [("content-type", "application/json")], body: Data("{}".utf8))
        XCTAssertEqual(connect.status, 403)
        let alias = try await client.request(
            method: "POST", path: "/api/micropod.v1.MicropodService/SetRigMode",
            headers: [("content-type", "application/json")], body: Data("{}".utf8))
        XCTAssertEqual(alias.status, 403)
        let bare = try await client.grpc("/micropod.v1.RigService/SetRigMode", Data())
        XCTAssertEqual(bare.grpcStatus, 7, "the bare gRPC path reaches the policy as /api/…")
        let machine = try await client.grpc("/micropod.v1.RigService/ControlMachine", Data())
        XCTAssertEqual(machine.grpcStatus, 7)
        let aliasGRPC = try await client.grpc("/micropod.v1.MicropodService/SetRigMode", Data())
        XCTAssertEqual(aliasGRPC.grpcStatus, 12, "no gRPC service by the alias name")
        XCTAssertTrue(fixture.requests.allSatisfy { $0.path.hasPrefix("/api/micropod.v1.") })
    }

    /// A reset stream, and a dropped connection, stop the stream's source.
    func testAResetOrDroppedStreamStopsItsSource() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let message = try Micropod_V1_StreamLogsRequest.with { $0.id = "follow" }.serializedData()
        for (round, drop) in [(1, false), (2, true)] {
            let client = try await H2Client.unix(served.socket)
            let box = LockedBox<(any Channel)?>(nil)
            let call = Task {
                try await client.request(
                    method: "POST", path: "/micropod.v1.ContainerService/StreamContainerLogs",
                    headers: [("content-type", "application/grpc")], body: GRPCWire.message(message),
                    timeout: .seconds(20), onStream: { box.set($0) })
            }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(fixture.streamsEnded, round - 1, "round \(round): still streaming")
            if drop { client.close() } else { box.get()?.close(promise: nil) }
            for _ in 0..<150 where fixture.streamsEnded < round { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(fixture.streamsEnded, round, "round \(round): the source stopped")
            _ = try? await call.value
            client.close()
        }
        for _ in 0..<100 where served.server.http2?.handlers(.owner) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(served.server.http2?.handlers(.owner), 0)
    }

    /// A unary handler the client stopped waiting for still runs to its
    /// end (a mutation is never cut half way); its place is then freed.
    func testAUnaryHandlerFinishesAfterItsStreamWasReset() async throws {
        let fixture = H2Fixture()
        let served = try await serve(fixture)
        let client = try await H2Client.unix(served.socket)
        defer { client.close() }
        let box = LockedBox<(any Channel)?>(nil)
        let call = Task { try await client.request(path: "/slow?ms=600", onStream: { box.set($0) }) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.inFlight, 1)
        box.get()?.close(promise: nil)
        let answer = try await call.value
        XCTAssertTrue(answer.lost || answer.reset != nil, "the client reset it")
        XCTAssertEqual(served.server.http2?.handlers(.owner), 1, "the handler still runs")
        for _ in 0..<100 where fixture.inFlight != 0 || served.server.http2?.handlers(.owner) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.inFlight, 0, "it ran to its end")
        XCTAssertEqual(served.server.http2?.handlers(.owner), 0, "and freed its place")
    }

    // MARK: - Classification

    func testWhereAPrefaceIsNotHTTP2() async throws {
        let fixture = H2Fixture()
        var quick = Self.policy
        quick.requestIdle = .milliseconds(300)
        let served = try await serve(fixture, policy: quick)
        let internalSocket = dir.appendingPathComponent("internal.sock").path
        try await served.server.startPrivateSocket(path: internalSocket)
        let disabled = try await {
            let server = HTTPServer(
                port: 45454, policy: quick, isolatedRuntime: false, http2Enabled: false, handler: fixture.handle)
            servers.append(server)
            let path = dir.appendingPathComponent("off.sock").path
            _ = await MicropodAPI.startOwnerSocket(server, path: path, log: { XCTFail($0) })
            return path
        }()
        let socket = served.socket
        try await offPool {
            func status(_ wire: GoldenWire) throws -> String {
                String(GoldenWire.split(try wire.readToEOF()).0.prefix(12))
            }
            // The internal socket answers one request per connection: never HTTP/2.
            let one = try GoldenWire.unix(internalSocket)
            try one.send(HTTP2Preface.bytes)
            XCTAssertEqual(try status(one), "HTTP/1.1 505")
            // MICROPOD_API_HTTP2=0.
            let off = try GoldenWire.unix(disabled)
            try off.send(HTTP2Preface.bytes)
            XCTAssertEqual(try status(off), "HTTP/1.1 505")
            // A preface as the second request, or pipelined behind the first.
            let second = try GoldenWire.unix(socket)
            try second.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
            _ = try second.read(
                HTTP1GoldenBytesTests.kept("200 OK", "application/json", #"{"status":"ok"}"#).utf8.count)
            try second.send(HTTP2Preface.bytes)
            XCTAssertEqual(try status(second), "HTTP/1.1 505")
            let pipelined = try GoldenWire.unix(socket)
            try pipelined.send(Data("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8) + HTTP2Preface.bytes)
            let both = try pipelined.readToEOF()
            XCTAssertTrue(both.text.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertTrue(both.text.contains("HTTP/1.1 505"))
            // Part of a preface, then silence: 408 on the request clock.
            let partial = try GoldenWire.unix(socket)
            try partial.send(HTTP2Preface.bytes.prefix(18))
            XCTAssertEqual(try status(partial), "HTTP/1.1 408")
            // HTTP/1.1's Upgrade: h2c is not taken up: a plain HTTP/1.1 answer.
            let upgrade = try GoldenWire.unix(socket)
            try upgrade.send(
                "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\n"
                    + "HTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n")
            let reply = try upgrade.read(
                HTTP1GoldenBytesTests.kept("200 OK", "application/json", #"{"status":"ok"}"#).utf8.count)
            XCTAssertEqual(reply.text, HTTP1GoldenBytesTests.kept("200 OK", "application/json", #"{"status":"ok"}"#))
        }
    }
}

/// A value shared with a callback.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func get() -> Value { lock.withLock { value } }
}
