import Foundation
import MicropodCore
import NIOHTTP2
import SwiftProtobuf
import XCTest

@testable import MicropodAPI

/// A response writer that records every frame, for exchanges run without
/// a socket.
final class RecordingWriter: HTTP2ResponseWriter, @unchecked Sendable {
    enum Event: Equatable {
        case head(Int, [String: String], endStream: Bool)
        case data(Data, endStream: Bool)
        case trailers([String: String])
        case reset(UInt32)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    /// Writes fail once the stream is gone.
    var failing = false

    var events: [Event] { lock.withLock { recorded } }

    private func record(_ event: Event) throws {
        try lock.withLock {
            if failing { throw H2TestError(description: "stream gone") }
            recorded.append(event)
        }
    }

    func head(status: Int, fields: [(String, String)], endStream: Bool) async throws {
        try record(.head(status, Dictionary(fields, uniquingKeysWith: { $1 }), endStream: endStream))
    }
    func data(_ bytes: Data, endStream: Bool) async throws { try record(.data(bytes, endStream: endStream)) }
    func trailers(_ fields: [(String, String)]) async throws {
        try record(.trailers(Dictionary(fields, uniquingKeysWith: { $1 })))
    }
    func reset(_ code: HTTP2ErrorCode) async { try? record(.reset(UInt32(code.networkCode))) }

    /// The gRPC status, from the trailers or a Trailers-Only head.
    var grpcStatus: String? {
        for event in events.reversed() {
            if case .trailers(let fields) = event { return fields["grpc-status"] }
            if case .head(_, let fields, true) = event { return fields["grpc-status"] }
        }
        return nil
    }
}

struct NoSlot: HTTP2HandlerSlot {
    func release() {}
}

final class HTTP2ExchangeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/mp-hx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A context on a real server's guard and admission, with `fixture` as the handler.
    private func context(
        _ fixture: H2Fixture, admission: RuntimeAdmission? = nil, isolated: Bool = false,
        listener: HTTPServer.Admission = .ownerOnly
    ) -> HTTP2ExchangeContext {
        let server = HTTPServer(
            port: 45454, isolatedRuntime: isolated,
            runtimeAdmission: admission ?? RuntimeAdmission(root: dir.appendingPathComponent("none")),
            handler: fixture.handle)
        return server.http2Context(listener)
    }

    private func head(
        _ path: String, method: HTTPMethod = .post, contentType: String? = "application/grpc",
        extra: [String: String] = [:]
    ) -> HTTP2RequestAdapter.Head {
        var headers = extra
        headers["host"] = "localhost:45454"
        if let contentType { headers["content-type"] = contentType }
        return HTTP2RequestAdapter.Head(method: method, target: path, headers: headers)
    }

    private func closedAdmission() throws -> RuntimeAdmission {
        let root = dir.appendingPathComponent("closed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("fence.json"))
        return RuntimeAdmission(root: root)
    }

    func testClosedAdmissionAnswersUnavailableAndHealthIsExempt() async throws {
        let fixture = H2Fixture()
        let context = context(fixture, admission: try closedAdmission(), isolated: true)
        let rest = RecordingWriter()
        await HTTP2Exchange.run(
            head("/v1/containers", method: .get, contentType: nil), body: Data(), context: context, writer: rest,
            slot: NoSlot())
        guard case .head(503, let fields, false) = rest.events.first else { return XCTFail("\(rest.events)") }
        XCTAssertEqual(fields["content-type"], "application/json")
        let grpc = RecordingWriter()
        await HTTP2Exchange.run(
            head("/micropod.v1.SystemService/Ping"), body: GRPCWire.message(Data()), context: context, writer: grpc,
            slot: NoSlot())
        XCTAssertEqual(grpc.grpcStatus, "14")
        let health = RecordingWriter()
        await HTTP2Exchange.run(
            head("/health", method: .get, contentType: nil), body: Data(), context: context, writer: health,
            slot: NoSlot())
        XCTAssertEqual(health.events.first, .head(200, health.firstFields, endStream: false))
        let check = RecordingWriter()
        await HTTP2Exchange.run(
            head("/grpc.health.v1.Health/Check"), body: GRPCWire.message(Data()), context: context, writer: check,
            slot: NoSlot())
        XCTAssertEqual(check.grpcStatus, "0")
        XCTAssertEqual(fixture.requests.map(\.path), ["/health", "/health"], "only the exempt path reached a handler")
    }

    /// The stream handler cancels a stream's exchange when the client resets
    /// it: the source stops and the admission receipt is settled.
    func testACancelledStreamSettlesItsAdmissionReceipt() async throws {
        let root = dir.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("enrolled"))
        let fixture = H2Fixture()
        let context = context(fixture, admission: RuntimeAdmission(root: root), isolated: true)
        let pending = {
            (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("pending").path)) ?? []
        }
        let message = try Micropod_V1_StreamLogsRequest.with { $0.id = "follow" }.serializedData()
        let writer = RecordingWriter()
        let streamHead = head("/micropod.v1.ContainerService/StreamContainerLogs")
        let exchange = Task {
            await HTTP2Exchange.run(
                streamHead, body: GRPCWire.message(message), context: context, writer: writer, slot: NoSlot())
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pending().count, 1, "the stream holds its receipt")
        exchange.cancel()
        await exchange.value
        for _ in 0..<50 where fixture.streamsEnded == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.streamsEnded, 1, "the source stopped")
        XCTAssertEqual(pending(), [], "the receipt was settled")
    }

    func testTheVsockBridgeAndRelaysNeedHTTP1() async throws {
        let fixture = H2Fixture()
        let context = context(fixture, listener: .guarded)
        let writer = RecordingWriter()
        await HTTP2Exchange.run(
            head("/v1/containers/c1/vsock/1024", method: .get, contentType: nil), body: Data(), context: context,
            writer: writer, slot: NoSlot())
        XCTAssertEqual(writer.events, [.reset(0xD)], "HTTP_1_1_REQUIRED")
        XCTAssertEqual(fixture.count, 0, "before its handler dials anything")
        let foreign = RecordingWriter()
        var bad = head("/v1/containers/c1/vsock/1024", method: .get, contentType: nil)
        bad = HTTP2RequestAdapter.Head(method: bad.method, target: bad.target, headers: ["host": "evil"])
        await HTTP2Exchange.run(bad, body: Data(), context: context, writer: foreign, slot: NoSlot())
        guard case .head(403, _, _) = foreign.events.first else { return XCTFail("the guard runs first") }
    }

    func testGRPCRequestFramingIsChecked() async throws {
        let fixture = H2Fixture()
        let context = context(fixture)
        func call(_ body: Data, extra: [String: String] = [:]) async -> RecordingWriter {
            let writer = RecordingWriter()
            await HTTP2Exchange.run(
                head("/micropod.v1.SystemService/Ping", extra: extra), body: body, context: context, writer: writer,
                slot: NoSlot())
            return writer
        }
        let none = await call(Data())
        XCTAssertEqual(none.grpcStatus, "3", "no message")
        let two = await call(GRPCWire.message(Data()) + GRPCWire.message(Data()))
        XCTAssertEqual(two.grpcStatus, "3", "two messages")
        let cut = await call(Data([0, 0, 0, 0, 9, 1]))
        XCTAssertEqual(cut.grpcStatus, "3", "a cut message")
        let compressed = await call(ConnectEnvelope.frame(Data(), flags: 1))
        XCTAssertEqual(compressed.grpcStatus, "12")
        guard case .head(200, let fields, true) = compressed.events.first else { return XCTFail() }
        XCTAssertEqual(fields["grpc-accept-encoding"], "identity")
        let gzip = await call(GRPCWire.message(Data()), extra: ["grpc-encoding": "gzip"])
        XCTAssertEqual(gzip.grpcStatus, "12")
        let malformed = await call(GRPCWire.message(Data()), extra: ["grpc-timeout": "soon"])
        XCTAssertEqual(malformed.grpcStatus, "13")
        XCTAssertEqual(fixture.count, 0, "no refused call reached the handler")
        let identity = await call(GRPCWire.message(Data()), extra: ["grpc-encoding": "identity"])
        XCTAssertEqual(identity.grpcStatus, "0")
    }

    /// `grpc-timeout` ends the call with DEADLINE_EXCEEDED; the unary handler
    /// still runs to its end.
    func testTheGRPCDeadlineIsHonoured() async throws {
        let fixture = H2Fixture()
        let context = context(fixture)
        let writer = RecordingWriter()
        let started = Date()
        await HTTP2Exchange.run(
            head("/micropod.v1.SystemService/Ping", extra: ["grpc-timeout": "100m"]), body: GRPCWire.message(Data()),
            context: context, writer: writer, slot: NoSlot())
        XCTAssertEqual(writer.grpcStatus, "0", "a fast call ends before its deadline")
        let slow = HTTP2ExchangeContext(
            admission: .ownerOnly, guardRejection: { _, _ in nil }, admissionClaim: { _ in nil },
            handler: { request in
                try? await Task.sleep(for: .milliseconds(400))
                return await fixture.handle(request)
            }, relay: { _ in .json(503, [:]) })
        let late = RecordingWriter()
        let timed = Date()
        await HTTP2Exchange.run(
            head("/micropod.v1.SystemService/Ping", extra: ["grpc-timeout": "50m"]), body: GRPCWire.message(Data()),
            context: slow, writer: late, slot: NoSlot())
        XCTAssertEqual(late.grpcStatus, "4")
        XCTAssertEqual(late.events.count, 1, "Trailers-Only, nothing after it")
        XCTAssertGreaterThan(Date().timeIntervalSince(timed), 0.35, "the exchange waited for its handler")
        XCTAssertEqual(fixture.count, 2, "the handler ran to its end")
        _ = started
    }

    func testRelayedAnswersAreUnavailableUntilForwarded() async throws {
        let context = HTTP2ExchangeContext(
            admission: .ownerOnly, guardRejection: { _, _ in nil }, admissionClaim: { _ in nil },
            handler: { _ in .relay { _ in } },
            relay: HTTPServer(port: 1, http2Enabled: false) { _ in .json(200, [:]) }.http2Context(.ownerOnly).relay)
        let writer = RecordingWriter()
        await HTTP2Exchange.run(
            head("/v1/containers", method: .get, contentType: nil), body: Data(), context: context, writer: writer,
            slot: NoSlot())
        guard case .head(503, _, _) = writer.events.first else { return XCTFail("\(writer.events)") }
        let grpc = RecordingWriter()
        await HTTP2Exchange.run(
            head("/micropod.v1.ContainerService/ListContainers"), body: GRPCWire.message(Data()), context: context,
            writer: grpc, slot: NoSlot())
        XCTAssertEqual(grpc.grpcStatus, "14")
    }
}

extension RecordingWriter {
    var firstFields: [String: String] {
        if case .head(_, let fields, _) = events.first { return fields }
        return [:]
    }
}
