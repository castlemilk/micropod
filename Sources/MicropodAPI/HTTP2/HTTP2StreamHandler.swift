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
    /// Bodies of answers whose handlers gave their places back, not yet written.
    private var unsentBytes = 0
    private var streams = 0
    /// Open streams that wait for nothing of the server's (`Slot.park`):
    /// they do not count against the idle bound.
    private var parked = 0
    private var opened = false
    private var closing = false
    private var channel: (any Channel)?
    private var idle: Scheduled<Void>?

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

    /// The connection's own channel, once adopted: its idle clock starts.
    func attach(_ channel: any Channel) {
        lock.withLock { self.channel = channel }
        armIdle()
    }

    func streamOpened() {
        let timer = lock.withLock { () -> Scheduled<Void>? in
            streams += 1
            opened = true
            defer { idle = nil }
            return idle
        }
        timer?.cancel()
    }

    /// A stream was ever opened on this connection.
    var everOpened: Bool { lock.withLock { opened } }

    /// `slot`: the stream's handler place, when it was given one.
    func streamClosed(_ slot: Slot? = nil) {
        let (close, quiet) = lock.withLock { () -> ((any Channel)?, Bool) in
            streams -= 1
            if let slot {
                if slot.parked { parked -= 1 }
                slot.parked = false
                slot.streamClosed = true
            }
            return (closing && streams == parked ? channel : nil, !closing && streams == parked)
        }
        if let close { Self.closeSoon(close) }
        if quiet { armIdle() }
    }

    fileprivate func park(_ slot: Slot) {
        let (close, quiet) = lock.withLock { () -> ((any Channel)?, Bool) in
            guard !slot.parked, !slot.streamClosed else { return (nil, false) }
            slot.parked = true
            parked += 1
            return (closing && streams == parked ? channel : nil, !closing && streams == parked)
        }
        if let close { Self.closeSoon(close) }
        if quiet { armIdle() }
    }

    /// `connectionIdle` with no stream open but parked ones: GOAWAY.
    private func armIdle() {
        lock.withLock {
            guard let channel, !closing, streams == parked, idle == nil else { return }
            idle = channel.eventLoop.scheduleTask(in: limits.connectionIdle) { [weak self] in
                guard let self else { return }
                let still = self.lock.withLock { () -> Bool in
                    self.idle = nil
                    return self.streams == self.parked
                }
                if still { self.goAway() }
            }
        }
    }

    /// GOAWAY(NO_ERROR) now; the close once no stream is open (parked ones
    /// aside), or after `goAwayGrace` whatever is still open. The server's stop and the idle
    /// bound both end a connection so. (NIO's own connection manager closes
    /// as the last stream's END_STREAM is written, which can be before its
    /// bytes are flushed: it lost the final DATA of a call in flight.)
    func goAway() {
        let (channel, quiet) = lock.withLock { () -> ((any Channel)?, Bool) in
            guard !closing else { return (nil, false) }
            closing = true
            return (self.channel, streams == parked)
        }
        guard let channel else { return }
        let frame = HTTP2Frame(
            streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil))
        channel.writeAndFlush(frame, promise: nil)
        if quiet { Self.closeSoon(channel) }
        channel.eventLoop.scheduleTask(in: limits.goAwayGrace) { channel.close(promise: nil) }
    }

    /// Closes once the frames already written reached the socket: a flush
    /// a moment later, then the output's close, which waits for them.
    private static func closeSoon(_ channel: any Channel) {
        channel.eventLoop.scheduleTask(in: .milliseconds(50)) {
            channel.flush()
            channel.close(mode: .output, promise: nil)
        }
    }

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

    /// Room for an answer of `count` bytes among this connection's unsent ones.
    fileprivate func reserveAnswer(_ count: Int) -> Bool {
        lock.withLock {
            guard unsentBytes + count <= limits.unsentResponseBytes else { return false }
            unsentBytes += count
            return true
        }
    }

    fileprivate func releaseAnswer(_ count: Int) { lock.withLock { unsentBytes -= count } }

    var unsentAnswerBytes: Int { lock.withLock { unsentBytes } }

    /// The handler place is released once, however often `release` (or
    /// `answered` before it) is called.
    final class Slot: HTTP2HandlerSlot, @unchecked Sendable {
        private let connection: HTTP2ConnectionState
        private let lock = NSLock()
        private var released = false
        /// Both under the connection's lock.
        fileprivate var parked = false
        fileprivate var streamClosed = false
        init(connection: HTTP2ConnectionState) { self.connection = connection }
        func park() {
            release()
            connection.park(self)
        }
        /// Bytes of this stream's answer counted among the unsent ones.
        private var answer = 0
        func answered(bytes: Int) {
            let freed = lock.withLock { () -> Bool in
                guard !released, connection.reserveAnswer(bytes) else { return false }
                released = true
                answer = bytes
                return true
            }
            if freed { connection.releaseHandler() }
        }
        func release() {
            let (first, bytes) = lock.withLock { () -> (Bool, Int) in
                defer {
                    released = true
                    answer = 0
                }
                return (!released, answer)
            }
            if first { connection.releaseHandler() }
            if bytes > 0 { connection.releaseAnswer(bytes) }
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
    private var slot: HTTP2ConnectionState.Slot?

    init(connection: HTTP2ConnectionState) { self.connection = connection }

    func handlerAdded(context: ChannelHandlerContext) {
        connection.streamOpened()
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
                    // A gRPC client reads a status, not an HTTP 400 (which
                    // it reports as INTERNAL or UNKNOWN): Trailers-Only, as
                    // the guard's and admission's refusals are.
                    let answered: EventLoopFuture<Void>
                    if let codec = GRPCWire.codec(contentType: frame.headers.first(name: "content-type")) {
                        answered = refuseGRPC(context, codec: codec, status == 405 ? 12 : 3, reason)
                    } else {
                        answered = refuse(
                            context, status: status, code: status == 405 ? "unimplemented" : "invalid_argument", reason)
                    }
                    // The answer is complete (RFC 9113 §8.1); a request the
                    // client has not ended is closed after it. Its timers
                    // are stopped, so left open it would hold the connection
                    // (and its place) past every deadline.
                    if !frame.endStream { closeAfter(answered, context) }
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
        connection.streamClosed(slot)
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
        self.slot = slot
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

    /// RST_STREAM(NO_ERROR) once an early answer's last frame left for the
    /// socket (sent before it, the reset would drop a DATA frame NIO still
    /// holds for flow control). A client whose window never lets the answer
    /// out is reset at `writeStall` (CANCEL), as any response is.
    private func closeAfter(_ answered: EventLoopFuture<Void>, _ context: ChannelHandlerContext) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let stall = context.eventLoop.scheduleTask(in: limits.writeStall) { bound.value.close(promise: nil) }
        answered.whenComplete { _ in
            stall.cancel()
            let context = bound.value
            guard context.channel.isActive else { return }
            context.writeAndFlush(NIOAny(HTTP2Frame.FramePayload.rstStream(.noError)), promise: nil)
        }
    }

    /// A request refused before its exchange (malformed head). The future
    /// is its last frame's write.
    @discardableResult
    private func refuse(
        _ context: ChannelHandlerContext, status: Int, code: String, _ reason: String
    ) -> EventLoopFuture<Void> {
        let body = (try? JSONSerialization.data(withJSONObject: ["code": code, "message": reason])) ?? Data()
        var headers = HPACKHeaders()
        headers.add(name: ":status", value: String(status))
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(body.count))
        context.write(wrapOutboundOut(.headers(.init(headers: headers))), promise: nil)
        let buffer = context.channel.allocator.buffer(bytes: body)
        return context.writeAndFlush(wrapOutboundOut(.data(.init(data: .byteBuffer(buffer), endStream: true))))
    }

    /// A gRPC call refused before its exchange: Trailers-Only.
    private func refuseGRPC(
        _ context: ChannelHandlerContext, codec: GRPCWire.Codec, _ code: Int, _ reason: String
    ) -> EventLoopFuture<Void> {
        var headers = HPACKHeaders()
        headers.add(name: ":status", value: "200")
        headers.add(name: "content-type", value: codec == .proto ? "application/grpc" : "application/grpc+json")
        for (name, value) in GRPCWire.trailers(code, reason) { headers.add(name: name, value: value) }
        return context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: headers, endStream: true))))
    }

    /// A body over `streamBodyBytes`: 413, or RESOURCE_EXHAUSTED for gRPC;
    /// then the rest of the request is refused (RST_STREAM NO_ERROR).
    private func tooLarge(_ context: ChannelHandlerContext) {
        let reason = "request body exceeds \(limits.streamBodyBytes) bytes"
        let answered: EventLoopFuture<Void>
        if let head, let codec = GRPCWire.codec(contentType: head.headers["content-type"]) {
            answered = refuseGRPC(context, codec: codec, 8, reason)
        } else {
            answered = refuse(context, status: 413, code: "resource_exhausted", reason)
        }
        closeAfter(answered, context)
    }
}
