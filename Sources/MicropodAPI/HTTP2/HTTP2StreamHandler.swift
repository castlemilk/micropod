import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2

/// One HTTP/2 connection's shared bounds: handlers in flight and request
/// bytes buffered, both checked before anything is admitted.
final class HTTP2ConnectionState: @unchecked Sendable {
    let limits: HTTP2Limits
    let context: HTTP2ExchangeContext
    private let listener: HTTP2Engine.ListenerCounters
    private let lock = NSLock()
    private var handlers = 0
    private var bodyBytes = 0

    init(limits: HTTP2Limits, context: HTTP2ExchangeContext, listener: HTTP2Engine.ListenerCounters) {
        self.limits = limits
        self.context = context
        self.listener = listener
    }

    /// A handler place on this connection and its listener, or nil at
    /// either bound (the stream is then refused).
    func claimHandler() -> Slot? {
        let claimed = lock.withLock {
            guard handlers < limits.handlersPerConnection else { return false }
            handlers += 1
            return true
        }
        guard claimed else { return nil }
        guard listener.claimHandler(limit: limits.handlersPerListener) else {
            lock.withLock { handlers -= 1 }
            return nil
        }
        return Slot(connection: self)
    }

    var handlersInFlight: Int { lock.withLock { handlers } }

    fileprivate func releaseHandler() {
        lock.withLock { handlers -= 1 }
        listener.releaseHandler()
    }

    /// Room for `count` more buffered request bytes on this connection.
    func reserveBody(_ count: Int) -> Bool {
        lock.withLock {
            guard bodyBytes + count <= limits.connectionBodyBytes else { return false }
            bodyBytes += count
            return true
        }
    }

    func releaseBody(_ count: Int) { lock.withLock { bodyBytes -= count } }

    var bufferedBodyBytes: Int { lock.withLock { bodyBytes } }

    /// Released once, however often `release` is called.
    final class Slot: HTTP2HandlerSlot, @unchecked Sendable {
        private let connection: HTTP2ConnectionState
        private let lock = NSLock()
        private var released = false
        init(connection: HTTP2ConnectionState) { self.connection = connection }
        func release() {
            let first = lock.withLock {
                defer { released = true }
                return !released
            }
            if first { connection.releaseHandler() }
        }
    }
}

/// Writes a stream's response frames on its NIO stream channel.
struct HTTP2StreamWriter: HTTP2ResponseWriter {
    let channel: any Channel
    let writeStall: TimeAmount

    func head(status: Int, fields: [(String, String)], endStream: Bool) async throws {
        var headers = HPACKHeaders()
        headers.add(name: ":status", value: String(status))
        for (name, value) in fields { headers.add(name: name, value: value) }
        try await write(.headers(.init(headers: headers, endStream: endStream)))
    }

    func data(_ bytes: Data, endStream: Bool) async throws {
        let buffer = channel.allocator.buffer(bytes: bytes)
        try await write(.data(.init(data: .byteBuffer(buffer), endStream: endStream)))
    }

    func trailers(_ fields: [(String, String)]) async throws {
        var headers = HPACKHeaders()
        for (name, value) in fields { headers.add(name: name, value: value) }
        try await write(.headers(.init(headers: headers, endStream: true)))
    }

    func reset(_ code: HTTP2ErrorCode) async {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTP2Frame.FramePayload.rstStream(code), promise: promise)
        try? await promise.futureResult.get()
    }

    /// Awaited until the frame left for the socket; a write the client does
    /// not take within `writeStall` closes the stream (RST_STREAM CANCEL),
    /// which fails it.
    private func write(_ payload: HTTP2Frame.FramePayload) async throws {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(payload, promise: promise)
        let stall = channel.eventLoop.scheduleTask(in: writeStall) { [channel] in channel.close(promise: nil) }
        defer { stall.cancel() }
        try await promise.futureResult.get()
    }
}

/// One inbound HTTP/2 stream: collects the request (within the body bounds
/// and the request deadlines), then runs its `HTTP2Exchange`. A reset or a
/// lost connection cancels the exchange (a stream's source stops; a unary
/// handler runs to its end and its answer is dropped).
final class HTTP2StreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let connection: HTTP2ConnectionState
    private var limits: HTTP2Limits { connection.limits }
    private var head: HTTP2RequestAdapter.Head?
    private var body: ByteBuffer?
    private var reserved = 0
    /// The request was dispatched or refused: later frames are ignored.
    private var settled = false
    private var deadline: Scheduled<Void>?
    private var silence: Scheduled<Void>?
    private var exchange: Task<Void, Never>?

    init(connection: HTTP2ConnectionState) { self.connection = connection }

    func handlerAdded(context: ChannelHandlerContext) {
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: limits.requestDeadline) { bound.value.0.expire(bound.value.1) }
        touch(context)
    }

    func handlerRemoved(context: ChannelHandlerContext) { stopTimers() }

    private func stopTimers() {
        deadline?.cancel()
        silence?.cancel()
        deadline = nil
        silence = nil
    }

    /// A new silence window.
    private func touch(_ context: ChannelHandlerContext) {
        silence?.cancel()
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        silence = context.eventLoop.scheduleTask(in: limits.requestIdle) { bound.value.0.expire(bound.value.1) }
    }

    /// The request did not arrive in time: RST_STREAM(CANCEL).
    private func expire(_ context: ChannelHandlerContext) {
        guard !settled else { return }
        settle()
        context.writeAndFlush(wrapOutboundOut(.rstStream(.cancel)), promise: nil)
    }

    private func settle() {
        settled = true
        stopTimers()
    }

    private func releaseBody() {
        if reserved > 0 { connection.releaseBody(reserved) }
        reserved = 0
        body = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        switch payload {
        case .rstStream:
            exchange?.cancel()
            if !settled {
                settle()
                releaseBody()
            }
        case .headers(let frame) where !settled:
            if head == nil {
                switch HTTP2RequestAdapter.head(frame.headers) {
                case .refuse(let status, let reason):
                    settle()
                    refuse(context, status: status, code: status == 405 ? "unimplemented" : "invalid_argument", reason)
                    return
                case .head(let parsed):
                    head = parsed
                }
            }
            touch(context)
            if frame.endStream {
                dispatch(context)
            } else if let head, GRPCWire.answersFromHeaders(head) {
                // An unknown method (or a client stream, which nothing
                // serves) is refused now, not after a body that may never end.
                dispatch(context, early: true)
            }
        case .data(let frame) where !settled:
            guard head != nil else {
                settle()
                context.writeAndFlush(wrapOutboundOut(.rstStream(.protocolError)), promise: nil)
                return
            }
            guard case .byteBuffer(var bytes) = frame.data else { return }
            let count = bytes.readableBytes
            if (body?.readableBytes ?? 0) + count > limits.streamBodyBytes {
                settle()
                releaseBody()
                tooLarge(context)
                return
            }
            guard connection.reserveBody(count) else {
                settle()
                releaseBody()
                context.writeAndFlush(wrapOutboundOut(.rstStream(.enhanceYourCalm)), promise: nil)
                return
            }
            reserved += count
            if body == nil {
                body = bytes
            } else {
                body?.writeBuffer(&bytes)
            }
            touch(context)
            if frame.endStream { dispatch(context) }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        exchange?.cancel()
        if exchange == nil { releaseBody() }
        stopTimers()
        settled = true
        context.fireChannelInactive()
    }

    /// `early`: answered from the headers alone; the rest of the request is
    /// then refused (RST_STREAM NO_ERROR).
    private func dispatch(_ context: ChannelHandlerContext, early: Bool = false) {
        settle()
        guard let head else { return }
        guard let slot = connection.claimHandler() else {
            releaseBody()
            context.writeAndFlush(wrapOutboundOut(.rstStream(.refusedStream)), promise: nil)
            return
        }
        let bytes = body.map { Data($0.readableBytesView) } ?? Data()
        body = nil
        let reserved = self.reserved
        self.reserved = 0
        let writer = HTTP2StreamWriter(channel: context.channel, writeStall: limits.writeStall)
        let connection = self.connection
        exchange = Task {
            await HTTP2Exchange.run(head, body: bytes, context: connection.context, writer: writer, slot: slot)
            slot.release()
            connection.releaseBody(reserved)
            if early { await writer.reset(.noError) }
        }
    }

    /// A request refused before its exchange (malformed head).
    private func refuse(_ context: ChannelHandlerContext, status: Int, code: String, _ reason: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["code": code, "message": reason])) ?? Data()
        var headers = HPACKHeaders()
        headers.add(name: ":status", value: String(status))
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(body.count))
        context.write(wrapOutboundOut(.headers(.init(headers: headers))), promise: nil)
        let buffer = context.channel.allocator.buffer(bytes: body)
        context.writeAndFlush(wrapOutboundOut(.data(.init(data: .byteBuffer(buffer), endStream: true))), promise: nil)
    }

    /// A body over `streamBodyBytes`: 413, or RESOURCE_EXHAUSTED for gRPC;
    /// then the rest of the request is refused (RST_STREAM NO_ERROR).
    private func tooLarge(_ context: ChannelHandlerContext) {
        let reason = "request body exceeds \(limits.streamBodyBytes) bytes"
        if let head, GRPCWire.codec(contentType: head.headers["content-type"]) != nil {
            var headers = HPACKHeaders()
            headers.add(name: ":status", value: "200")
            headers.add(name: "content-type", value: "application/grpc")
            for (name, value) in GRPCWire.trailers(8, reason) { headers.add(name: name, value: value) }
            context.write(wrapOutboundOut(.headers(.init(headers: headers, endStream: true))), promise: nil)
        } else {
            refuse(context, status: 413, code: "resource_exhausted", reason)
        }
        context.writeAndFlush(wrapOutboundOut(.rstStream(.noError)), promise: nil)
    }
}
