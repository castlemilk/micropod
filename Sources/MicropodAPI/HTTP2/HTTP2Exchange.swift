import Foundation
import MicropodCore
import NIOHTTP2

/// Where an HTTP/2 stream's response goes. The NIO stream channel writes it
/// (`HTTP2StreamWriter`); tests record it. Every write is awaited: it
/// returns once the frame left for the socket, so a reader that stops
/// taking data stops its source too. A write throws once the stream is
/// gone (reset, the connection closed, or the write-stall deadline).
protocol HTTP2ResponseWriter: Sendable {
    func head(status: Int, fields: [(String, String)], endStream: Bool) async throws
    func data(_ bytes: Data, endStream: Bool) async throws
    func trailers(_ fields: [(String, String)]) async throws
    func reset(_ code: HTTP2ErrorCode) async
}

/// What a stream's exchange reaches on its server: the same request guard,
/// admission gate and handler the HTTP/1.1 transport calls.
struct HTTP2ExchangeContext: Sendable {
    /// The listener's admission (`.guarded` on loopback TCP, `.ownerOnly` on
    /// the owner's socket), taken from the HTTP/1.1 peer that accepted the
    /// connection.
    var admission: HTTPServer.Admission
    var guardRejection: @Sendable (HTTPRequest, HTTPServer.Admission) -> HTTPResponse?
    var admissionClaim: @Sendable (HTTPRequest) throws -> RuntimeAdmissionClaim?
    var handler: @Sendable (HTTPRequest) async -> HTTPResponse
    /// A `.relay` answer forwarded to the dedicated runtime and read back
    /// as a response (`IsolatedRuntimeProxy.forwardParsed`).
    var relay: @Sendable (HTTPRequest) async -> HTTPResponse
    var log: @Sendable (String) -> Void = { fputs($0 + "\n", stderr) }
}

/// A handler place held until the handler settles (`HTTP2ConnectionState`).
protocol HTTP2HandlerSlot: Sendable {
    func release()
}

/// One HTTP/2 request, from its parsed head to the last frame of its
/// response. Per stream, in order: the request guard, the vsock refusal,
/// runtime admission, the gRPC transcoding, the handler, the response.
/// The guard and admission are the HTTP/1.1 server's own functions, so
/// HTTP/2 and gRPC have no authorisation path of their own.
///
/// A unary handler runs to completion even when the client resets the
/// stream (as on HTTP/1.1, a mutation is never cut half way); its answer
/// is then dropped. A stream's source stops when the client resets it.
enum HTTP2Exchange {
    static func run(
        _ head: HTTP2RequestAdapter.Head, body: Data, context: HTTP2ExchangeContext,
        writer: some HTTP2ResponseWriter, slot: some HTTP2HandlerSlot
    ) async {
        let request = HTTP2RequestAdapter.request(head, body: body)
        if request.method == .post, let codec = GRPCWire.codec(contentType: request.headers["content-type"]) {
            await GRPCExchange(
                request: request, codec: codec, context: context, writer: writer, slot: slot
            ).run()
        } else {
            await plain(request, context: context, writer: writer)
        }
    }

    // MARK: - REST and Connect

    static func plain(_ request: HTTPRequest, context: HTTP2ExchangeContext, writer: some HTTP2ResponseWriter) async {
        let cors = CORSPolicy.responseHeaders(for: request)
        if let refusal = context.guardRejection(request, context.admission) {
            await render(refusal, cors: cors, writer: writer)
            return
        }
        // The guest vsock bridge takes over its connection as raw bytes:
        // HTTP/1.1 only. Refused before its handler dials anything.
        if isVsockBridge(request) {
            await writer.reset(.http11Required)
            return
        }
        let claim: RuntimeAdmissionClaim?
        do {
            claim = try context.admissionClaim(request)
        } catch {
            await render(HTTPServer.admissionClosed(), cors: [], writer: writer)
            return
        }
        var response = await uncancellable { await context.handler(request) }
        if case .relay = response { response = await uncancellable { await context.relay(request) } }
        switch response {
        case .stream(let status, let contentType, let events):
            await stream(status: status, contentType: contentType, events: events, cors: cors, writer: writer)
            try? claim?.completed()
        case .bridge:
            try? claim?.completed()
            context.log("HTTP/2 \(request.method.rawValue) \(request.path): a duplex bridge needs HTTP/1.1")
            await render(
                .json(500, ["code": "internal", "message": "this route needs HTTP/1.1"]), cors: cors, writer: writer)
        default:
            // The handler has settled; delivery failure cannot replay it.
            try? claim?.completed()
            await render(response, cors: cors, writer: writer)
        }
        withExtendedLifetime(claim) {}
    }

    /// `GET /v1/containers/:id/vsock/:port`.
    static func isVsockBridge(_ request: HTTPRequest) -> Bool {
        let segments = request.path.split(separator: "/")
        return request.method == .get && segments.count == 5 && segments[0] == "v1" && segments[1] == "containers"
            && segments[3] == "vsock"
    }

    /// A complete answer's status, content type and bytes (as the HTTP/1.1
    /// server serializes them), or nil for a stream, relay or bridge.
    static func complete(_ response: HTTPResponse) -> (status: Int, contentType: String, body: Data)? {
        switch response {
        case .json(let status, let object):
            return (
                status, "application/json", (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            )
        case .text(let status, let text): return (status, "text/plain", Data(text.utf8))
        case .data(let status, let contentType, let body): return (status, contentType, body)
        case .stream, .bridge, .relay: return nil
        }
    }

    /// HEADERS (with CORS, the codec advertisement and Content-Length), then
    /// the body in one DATA frame that ends the stream.
    static func render(_ response: HTTPResponse, cors: [(String, String)], writer: some HTTP2ResponseWriter) async {
        guard let (status, contentType, body) = complete(response) else {
            await render(.json(500, ["code": "internal", "message": "no response"]), cors: cors, writer: writer)
            return
        }
        let fields =
            [("content-type", contentType)] + cors.map { ($0.0.lowercased(), $0.1) } + [
                ("x-micropod-codecs", "json,proto"), ("content-length", String(body.count)),
            ]
        do {
            try await writer.head(status: status, fields: fields, endStream: body.isEmpty)
            if !body.isEmpty { try await writer.data(body, endStream: true) }
        } catch {}
    }

    /// A stream's head, then one awaited DATA frame per event, then the end.
    /// A write that fails (the client reset the stream or left) ends the
    /// loop, which drops the source's iterator and so stops its producer.
    static func stream(
        status: Int, contentType: String, events: AsyncStream<Data>, cors: [(String, String)],
        writer: some HTTP2ResponseWriter
    ) async {
        let fields =
            [("content-type", contentType)] + cors.map { ($0.0.lowercased(), $0.1) } + [("cache-control", "no-cache")]
        do {
            try await writer.head(status: status, fields: fields, endStream: false)
            for await chunk in events where !chunk.isEmpty {
                try await writer.data(chunk, endStream: false)
            }
            guard !Task.isCancelled else { return }
            try await writer.data(Data(), endStream: true)
        } catch {}
    }

    /// Runs `body` in a task of its own, which a reset stream does not
    /// cancel: a handler always runs to its end, as on HTTP/1.1.
    static func uncancellable(_ body: @escaping @Sendable () async -> HTTPResponse) async -> HTTPResponse {
        await Task { UncheckedResponse(await body()) }.value.response
    }
}

/// `HTTPResponse` carries closures and `[String: Any]`; it never crosses
/// threads concurrently, only from the handler's task to the stream's.
struct UncheckedResponse: @unchecked Sendable {
    let response: HTTPResponse
    init(_ response: HTTPResponse) { self.response = response }
}

/// The gRPC side of one stream (see `GRPCWire`).
struct GRPCExchange<Writer: HTTP2ResponseWriter, Slot: HTTP2HandlerSlot>: Sendable {
    let request: HTTPRequest
    let codec: GRPCWire.Codec
    let context: HTTP2ExchangeContext
    let writer: Writer
    let slot: Slot

    /// `/api/` + a bare gRPC path, so the handler, the isolated runtime's
    /// policy and the relay all see the path a Connect client sends.
    static func canonicalPath(_ path: String) -> String {
        path.hasPrefix("/api/") ? path : "/api" + path
    }

    var contentType: String { codec == .proto ? "application/grpc" : "application/grpc+json" }

    func run() async {
        let bare = request.path.hasPrefix("/api/") ? String(request.path.dropFirst(4)) : request.path
        let health = bare.hasPrefix("/" + GRPCWire.healthService + "/")
        let canonical = HTTPRequest(
            method: request.method, path: health ? bare : Self.canonicalPath(bare), query: request.query,
            body: request.body, headers: request.headers)
        let state = GRPCResponseState()
        if let refusal = context.guardRejection(canonical, context.admission) {
            let (status, _, body) = HTTP2Exchange.complete(refusal) ?? (403, "", Data())
            let (code, message) = GRPCWire.status(ofError: status, body: body)
            await state.trailersOnly(code, message, contentType: contentType, writer: writer)
            return
        }
        let claim: RuntimeAdmissionClaim?
        do {
            // The health service shares /health's exemption.
            claim =
                health
                ? nil
                : try context.admissionClaim(canonical)
        } catch {
            await state.trailersOnly(
                ConnectWireCode.unavailable.grpcStatus, "Runtime maintenance has closed workload admission",
                contentType: contentType, writer: writer)
            return
        }
        defer {
            try? claim?.completed()
            withExtendedLifetime(claim) {}
        }
        switch GRPCWire.timeout(request.headers["grpc-timeout"]) {
        case .malformed:
            await state.trailersOnly(13, "malformed grpc-timeout", contentType: contentType, writer: writer)
        case .none:
            await serve(canonical, bare: bare, health: health, state: state)
        case .after(let limit):
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await serve(canonical, bare: bare, health: health, state: state) }
                group.addTask {
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    await state.expire(contentType: contentType, writer: writer)
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    private func serve(_ canonical: HTTPRequest, bare: String, health: Bool, state: GRPCResponseState) async {
        guard GRPCWire.serves(bare), let route = RPCCatalog.route(bare) else {
            return await state.trailersOnly(12, "unknown method \(bare)", contentType: contentType, writer: writer)
        }
        if let encoding = request.headers["grpc-encoding"], encoding.lowercased() != "identity" {
            return await state.trailersOnly(
                12, "grpc-encoding \(encoding) is not supported", contentType: contentType, writer: writer,
                extra: [("grpc-accept-encoding", "identity")])
        }
        let payload: Data
        switch GRPCWire.singleMessage(request.body) {
        case .message(let message): payload = message
        case .compressed:
            // No grpc-encoding (or identity) came with it, or the call was
            // refused above: the flag contradicts the headers, which gRPC
            // answers INTERNAL. UNIMPLEMENTED and grpc-accept-encoding are
            // for an encoding the client named.
            return await state.trailersOnly(
                13, "compressed flag set with identity or no grpc-encoding", contentType: contentType,
                writer: writer)
        case .malformed(let reason):
            return await state.trailersOnly(3, reason, contentType: contentType, writer: writer)
        }
        if health {
            return await GRPCHealth(exchange: self, state: state).serve(method: route.method, payload: payload)
        }
        let kind = RPCCatalog.kind(service: route.service, method: route.method) ?? .unary
        var headers = canonical.headers
        headers["content-type"] = kind == .unary ? codec.unaryContentType : codec.streamContentType
        let transcoded = HTTPRequest(
            method: .post, path: canonical.path, query: canonical.query,
            body: kind == .unary ? payload : GRPCWire.message(payload), headers: headers)
        var response = await HTTP2Exchange.uncancellable { await context.handler(transcoded) }
        if case .relay = response {
            response = await HTTP2Exchange.uncancellable { await context.relay(transcoded) }
        }
        switch (kind, response) {
        case (.serverStream, .stream(200, _, let events)):
            await stream(events, state: state)
        case (.unary, .data(200, _, let body)):
            await state.unary(body, contentType: contentType, writer: writer)
        default:
            if let (status, _, body) = HTTP2Exchange.complete(response), status != 200 {
                let (code, message) = GRPCWire.status(ofError: status, body: body)
                await state.trailersOnly(code, message, contentType: contentType, writer: writer)
            } else {
                await state.trailersOnly(
                    13, "unexpected response for \(bare)", contentType: contentType, writer: writer)
            }
        }
    }

    /// Data envelopes as gRPC messages (each chunk's whole envelopes in one
    /// DATA frame), the EndStream envelope as the trailers.
    private func stream(_ events: AsyncStream<Data>, state: GRPCResponseState) async {
        guard await state.begin(contentType: contentType, writer: writer) else { return }
        var reader = ConnectEnvelopeReader()
        for await chunk in events {
            var messages = Data()
            for frame in reader.feed(chunk) {
                if frame.flags & 0x02 != 0 {
                    if !messages.isEmpty, await !state.send(messages, writer: writer) { return }
                    let (code, message) = GRPCWire.status(ofEndStream: frame.payload)
                    await state.finish(code, message, writer: writer)
                    return
                }
                messages.append(GRPCWire.message(frame.payload))
            }
            if !messages.isEmpty, await !state.send(messages, writer: writer) { return }
        }
        guard !Task.isCancelled else { return }
        await state.finish(13, "the stream ended without its status", writer: writer)
    }
}

/// The phases of one gRPC response, so a deadline and the response itself
/// never both end it: whichever ends it first wins, and the other writes
/// nothing more.
actor GRPCResponseState {
    private enum Phase { case none, open, done }
    private var phase = Phase.none

    /// Response headers; false when the response already ended.
    func begin(contentType: String, writer: some HTTP2ResponseWriter) async -> Bool {
        guard phase == .none else { return false }
        phase = .open
        do {
            try await writer.head(status: 200, fields: [("content-type", contentType)], endStream: false)
            return true
        } catch {
            phase = .done
            return false
        }
    }

    func send(_ messages: Data, writer: some HTTP2ResponseWriter) async -> Bool {
        guard phase == .open else { return false }
        do {
            try await writer.data(messages, endStream: false)
            return true
        } catch {
            phase = .done
            return false
        }
    }

    func finish(_ code: Int, _ message: String, writer: some HTTP2ResponseWriter) async {
        guard phase == .open else { return }
        phase = .done
        try? await writer.trailers(GRPCWire.trailers(code, message))
    }

    func unary(_ payload: Data, contentType: String, writer: some HTTP2ResponseWriter) async {
        guard await begin(contentType: contentType, writer: writer),
            await send(GRPCWire.message(payload), writer: writer)
        else { return }
        await finish(0, "", writer: writer)
    }

    /// Status in the response headers, with nothing else (gRPC's
    /// Trailers-Only), when no response began; trailers when one did.
    func trailersOnly(
        _ code: Int, _ message: String, contentType: String, writer: some HTTP2ResponseWriter,
        extra: [(String, String)] = []
    ) async {
        switch phase {
        case .done: return
        case .open: return await finish(code, message, writer: writer)
        case .none:
            phase = .done
            try? await writer.head(
                status: 200, fields: [("content-type", contentType)] + extra + GRPCWire.trailers(code, message),
                endStream: true)
        }
    }

    /// `grpc-timeout` ran out.
    func expire(contentType: String, writer: some HTTP2ResponseWriter) async {
        await trailersOnly(4, "deadline exceeded", contentType: contentType, writer: writer)
    }
}
