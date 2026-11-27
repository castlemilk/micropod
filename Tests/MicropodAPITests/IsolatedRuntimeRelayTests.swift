import Darwin
import Foundation
import MicropodCore
import SwiftProtobuf
import XCTest

@testable import MicropodAPI

/// HTTP/2 requests the owner relays to the dedicated runtime's API: sent
/// upstream over HTTP/1.1 and read back as a response.
final class IsolatedRuntimeRelayTests: XCTestCase {
    private var dir: URL!
    private var servers: [HTTPServer] = []

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/mp-rl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for server in servers { server.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    /// The dedicated runtime's API as its internal socket serves it: one
    /// request per connection, guarded.
    private func upstream(_ fixture: H2Fixture) async throws
        -> @Sendable () async throws -> (fd: Int32, authorization: String)
    {
        let server = HTTPServer(port: 45454, isolatedRuntime: false, http2Enabled: false, handler: fixture.handle)
        servers.append(server)
        let path = dir.appendingPathComponent("internal.sock").path
        try await server.startPrivateSocket(path: path)
        return { (try RuntimeUnixSocket.connect(path, expectedUID: getuid()), "Bearer test") }
    }

    func testCompleteAndStreamedAnswersComeBack() async throws {
        let fixture = H2Fixture()
        let connect = try await upstream(fixture)
        let ping = HTTPRequest(
            method: .post, path: "/api/micropod.v1.SystemService/Ping", query: ["a": "b c"], body: Data(),
            headers: ["content-type": "application/proto", "host": "127.0.0.1:1", "te": "trailers"])
        guard
            case .data(200, "application/proto", let body) = await IsolatedRuntimeProxy.forwardParsed(
                ping, upstream: connect)
        else { return XCTFail("a complete answer") }
        XCTAssertEqual(try Micropod_V1_PingResponse(serializedBytes: body).status, "running")
        let seen = fixture.requests.last
        XCTAssertEqual(seen?.headers["authorization"], "Bearer test")
        XCTAssertEqual(seen?.headers["host"], "localhost:45454", "the upstream's own Host")
        XCTAssertEqual(seen?.query, ["a": "b c"])

        let message = try Micropod_V1_StreamLogsRequest.with { $0.id = "c1" }.serializedData()
        let logs = HTTPRequest(
            method: .post, path: "/api/micropod.v1.ContainerService/StreamContainerLogs", query: [:],
            body: GRPCWire.message(message), headers: ["content-type": "application/connect+proto"])
        guard
            case .stream(200, "application/connect+proto", let events) = await IsolatedRuntimeProxy.forwardParsed(
                logs, upstream: connect)
        else { return XCTFail("a stream") }
        var bytes = Data()
        for await chunk in events { bytes.append(chunk) }
        var reader = ConnectEnvelopeReader()
        XCTAssertEqual(reader.feed(bytes).map(\.flags), [0, 0, 0, 0x02], "every frame, then the end")
    }

    func testAnUpstreamThatIsDownIsUnavailable() async {
        let down = await IsolatedRuntimeProxy.forwardParsed(
            HTTPRequest(method: .get, path: "/v1/containers", query: [:], body: Data(), headers: [:])
        ) { throw MicropodError.message("no runtime") }
        guard case .json(503, let object) = down else { return XCTFail("\(down)") }
        XCTAssertEqual(object["code"] as? String, "unavailable")
    }

    /// Over HTTP/2 end to end: a handler that relays (the owner with the
    /// dedicated runtime) answers REST, Connect and gRPC from upstream.
    func testHTTP2AndGRPCRequestsAreRelayed() async throws {
        let fixture = H2Fixture()
        let connect = try await upstream(fixture)
        let context = HTTP2ExchangeContext(
            admission: .ownerOnly, guardRejection: { _, _ in nil }, admissionClaim: { _ in nil },
            handler: { _ in .relay { _ in } },
            relay: { await IsolatedRuntimeProxy.forwardParsed($0, upstream: connect) })
        let rest = RecordingWriter()
        await HTTP2Exchange.run(
            .init(method: .get, target: "/health", headers: ["host": "x"]), body: Data(), context: context,
            writer: rest,
            slot: NoSlot())
        XCTAssertEqual(rest.events.first, .head(200, rest.firstFields, endStream: false))
        let grpc = RecordingWriter()
        await HTTP2Exchange.run(
            .init(
                method: .post, target: "/micropod.v1.SystemService/Ping", headers: ["content-type": "application/grpc"]),
            body: GRPCWire.message(Data()), context: context, writer: grpc, slot: NoSlot())
        XCTAssertEqual(grpc.grpcStatus, "0")
        let stream = RecordingWriter()
        let message = try Micropod_V1_StreamLogsRequest.with { $0.id = "fail" }.serializedData()
        await HTTP2Exchange.run(
            .init(
                method: .post, target: "/micropod.v1.ContainerService/StreamContainerLogs",
                headers: ["content-type": "application/grpc"]),
            body: GRPCWire.message(message), context: context, writer: stream, slot: NoSlot())
        XCTAssertEqual(stream.grpcStatus, "5", "the upstream stream's error, as gRPC trailers")
        XCTAssertEqual(
            fixture.requests.map(\.path),
            ["/health", "/api/micropod.v1.SystemService/Ping", "/api/micropod.v1.ContainerService/StreamContainerLogs"])
    }

    func testTheResponseReaderTakesAnySplit() throws {
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        for cut in 0...reply.count {
            var reader = HTTP1ResponseReader()
            try reader.feed(reply.prefix(cut))
            try reader.feed(reply.dropFirst(cut))
            XCTAssertEqual(reader.head, .init(status: 200, contentType: "application/json", contentLength: 2), "\(cut)")
            XCTAssertEqual(reader.body, Data("{}".utf8))
        }
        var stream = HTTP1ResponseReader()
        try stream.feed(Data("HTTP/1.1 200 HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata".utf8))
        XCTAssertEqual(stream.head?.contentLength, nil, "close-delimited")
        XCTAssertEqual(stream.body, Data("data".utf8))
        var chunked = HTTP1ResponseReader()
        XCTAssertThrowsError(try chunked.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        var garbage = HTTP1ResponseReader()
        XCTAssertThrowsError(try garbage.feed(Data("SSH-2.0\r\n\r\n".utf8)))
    }
}
