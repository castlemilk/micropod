import Darwin
import Foundation
import NIOCore
import NIOHTTP2
import NIOPosix
import Network

/// The API's HTTP/2 server: connections the HTTP/1.1 listeners recognised
/// by their preface (`HTTP2Preface`), served by swift-nio-http2 over a
/// socketpair bridge (`HTTP2Bridge`), on two event-loop threads of its own
/// started with the first one.
///
/// Every connection holds one of its listener's kept-connection places for
/// its whole life (the owner socket's and loopback TCP's stay apart, as for
/// HTTP/1.1), and at most `HTTP2Limits.maxConnections` per listener are
/// HTTP/2. Past either bound the client gets SETTINGS and
/// GOAWAY(ENHANCE_YOUR_CALM) and the close. `stop()` sends every connection
/// GOAWAY; streams in flight get `goAwayGrace` to finish.
final class HTTP2Engine: @unchecked Sendable {
    enum ListenerKind: Sendable, Hashable { case owner, tcp }

    let limits: HTTP2Limits
    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var channels: [ObjectIdentifier: (channel: any Channel, state: HTTP2ConnectionState)] = [:]
    private var stopping = false
    private let counters: [ListenerKind: ListenerCounters] = [.owner: ListenerCounters(), .tcp: ListenerCounters()]

    init(limits: HTTP2Limits) { self.limits = limits }

    /// HTTP/2 connections and handlers in flight on one listener.
    final class ListenerCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var connections = 0
        private var handlers = 0

        func claimConnection(limit: Int) -> Bool {
            lock.withLock {
                guard connections < limit else { return false }
                connections += 1
                return true
            }
        }
        func releaseConnection() { lock.withLock { connections -= 1 } }
        func claimHandler(limit: Int) -> Bool {
            lock.withLock {
                guard handlers < limit else { return false }
                handlers += 1
                return true
            }
        }
        func releaseHandler() { lock.withLock { handlers -= 1 } }
        var connectionCount: Int { lock.withLock { connections } }
        var handlerCount: Int { lock.withLock { handlers } }
    }

    func connections(_ kind: ListenerKind) -> Int { counters[kind]!.connectionCount }
    func handlers(_ kind: ListenerKind) -> Int { counters[kind]!.handlerCount }

    private func eventLoop() -> (any EventLoop)? {
        lock.withLock {
            guard !stopping else { return nil }
            if group == nil { group = MultiThreadedEventLoopGroup(numberOfThreads: 2) }
            return group!.next()
        }
    }

    /// Serves `connection` (its first bytes, `initial`, already read) over
    /// HTTP/2. `kept`: its listener's kept connections, which hold its place.
    func adopt(
        _ connection: NWConnection, initial: Data, kind: ListenerKind, kept: HTTPServer.KeptConnections,
        context: HTTP2ExchangeContext
    ) {
        let counters = self.counters[kind]!
        guard counters.claimConnection(limit: limits.maxConnections) else {
            return Self.refuse(connection)
        }
        guard kept.reserve(connection) else {
            counters.releaseConnection()
            return Self.refuse(connection)
        }
        let release: @Sendable () -> Void = {
            kept.release(connection)
            counters.releaseConnection()
        }
        guard let loop = eventLoop(), let fds = HTTP2Bridge.socketpair() else {
            release()
            return Self.refuse(connection)
        }
        let state = HTTP2ConnectionState(limits: limits, context: context, listener: counters)
        let limits = self.limits
        let server = ClientBootstrap(group: loop)
            .channelOption(.allowRemoteHalfClosure, value: false)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try Self.configure(channel, limits: limits, state: state) }
            }
            .withConnectedSocket(fds.server)
        let pump = ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        HTTP2BridgeHandler(connection: connection, initial: initial))
                }
            }
            .withConnectedSocket(fds.pump)
        server.and(pump).whenComplete { [weak self] result in
            switch result {
            case .success(let (serverChannel, pumpChannel)):
                let key = ObjectIdentifier(serverChannel)
                let admitted = self?.lock.withLock { () -> Bool in
                    guard let self, !self.stopping else { return false }
                    self.channels[key] = (serverChannel, state)
                    state.attach(serverChannel)
                    return true
                }
                serverChannel.closeFuture.whenComplete { [weak self] _ in
                    _ = self?.lock.withLock { self?.channels.removeValue(forKey: key) }
                    pumpChannel.close(promise: nil)
                    release()
                }
                if admitted != true { serverChannel.close(promise: nil) }
            case .failure:
                // Whichever end NIO adopted it closes; the client's
                // connection and its places go too.
                server.whenSuccess { $0.close(promise: nil) }
                pump.whenSuccess { $0.close(promise: nil) }
                connection.cancel()
                release()
            }
        }
    }

    /// The HTTP/2 server pipeline: NIOHTTP2Handler with the stream handler
    /// for every inbound stream, the deadline for a first stream, and the
    /// close on a connection error. Idle GOAWAY and the graceful close are
    /// `HTTP2ConnectionState`'s.
    static func configure(_ channel: any Channel, limits: HTTP2Limits, state: HTTP2ConnectionState) throws {
        let http2 = NIOHTTP2Handler(
            mode: .server, eventLoop: channel.eventLoop, connectionConfiguration: limits.connectionConfiguration,
            streamConfiguration: limits.streamConfiguration
        ) { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandler(HTTP2StreamHandler(connection: state))
            }
        }
        try channel.pipeline.syncOperations.addHandler(http2)
        try channel.pipeline.syncOperations.addHandler(FirstStreamDeadline(limits.firstStreamDeadline, state: state))
        if limits.logControlFrames {
            try channel.pipeline.syncOperations.addHandler(HTTP2ControlFrameMeter(window: limits.controlFrames.window))
        }
        try channel.pipeline.syncOperations.addHandler(HTTP2ConnectionErrors())
    }

    /// The client gets this server's (empty) SETTINGS and
    /// GOAWAY(last stream 0, ENHANCE_YOUR_CALM), then the close.
    static func refuse(_ connection: NWConnection) {
        connection.send(
            content: refusal, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    static let refusal = Data(
        [0, 0, 0, 0x04, 0, 0, 0, 0, 0]  // SETTINGS, no parameters
            + [0, 0, 8, 0x07, 0, 0, 0, 0, 0] + [0, 0, 0, 0] + [0, 0, 0, 0x0B])  // GOAWAY 0, ENHANCE_YOUR_CALM

    /// Every connection gets GOAWAY; once its streams finish (or
    /// `goAwayGrace` ran out) it closes, and then the event loops stop.
    func stop() {
        let (open, group) = lock.withLock {
            () -> ([(channel: any Channel, state: HTTP2ConnectionState)], MultiThreadedEventLoopGroup?) in
            stopping = true
            return (Array(channels.values), self.group)
        }
        for entry in open { entry.state.goAway() }
        guard let group else { return }
        let grace = limits.goAwayGrace.nanoseconds
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(grace)) + .seconds(1)) {
            let remaining = self.lock.withLock { self.channels.values.map(\.channel) }
            for channel in remaining { channel.close(promise: nil) }
            group.shutdownGracefully { _ in }
        }
    }

    /// Server channels open now.
    var openConnections: Int { lock.withLock { channels.count } }
}

/// Closes a connection that opened no stream within its deadline. (With
/// the inline stream multiplexer NIO reports a new stream to a stream
/// delegate only, not down the pipeline, so the stream handlers say so
/// through `HTTP2ConnectionState`.)
final class FirstStreamDeadline: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private let deadline: TimeAmount
    private let state: HTTP2ConnectionState
    private var timer: Scheduled<Void>?

    init(_ deadline: TimeAmount, state: HTTP2ConnectionState) {
        self.deadline = deadline
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { arm(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        arm(context)
        context.fireChannelActive()
    }

    private func arm(_ context: ChannelHandlerContext) {
        guard timer == nil else { return }
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let state = self.state
        timer = context.eventLoop.scheduleTask(in: deadline) {
            if !state.everOpened { bound.value.close(promise: nil) }
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) { timer?.cancel() }
}

/// Closes the connection on a connection error. NIOHTTP2Handler answers
/// one (a flood past its bound, a malformed frame, a broken header block)
/// with GOAWAY and reports it here, leaving the close to the pipeline;
/// without this the connection would stay open after its GOAWAY.
///
/// A stream's own error (a bad header block, a Content-Length that lies)
/// reaches here too, unwrapped, after
/// NIO reset that stream: those leave the connection and its other streams
/// alone. Repeated ones still end it, through NIO's own bounds
/// (ExcessiveStreamErrors, ExcessiveNumberOfGlitches).
final class HTTP2ConnectionErrors: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard !Self.streamLevel(error) else { return }
        // The GOAWAY NIO just wrote goes out first: closing the output
        // waits for pending writes; the bridge then closes the rest.
        context.flush()
        context.close(mode: .output, promise: nil)
    }

    static func streamLevel(_ error: any Error) -> Bool {
        switch error {
        // IOOnClosedConnection: a write (a stream's WINDOW_UPDATE) after a
        // GOAWAY's last stream ended; HTTP2ConnectionState closes the
        // connection once its last frames are flushed, and closing here
        // would drop them.
        case is NIOHTTP2Errors.StreamError, is NIOHTTP2Errors.NoSuchStream, is NIOHTTP2Errors.StreamClosed,
            is NIOHTTP2Errors.IOOnClosedConnection,
            is NIOHTTP2Errors.BadStreamStateTransition,
            is NIOHTTP2Errors.MissingPseudoHeader, is NIOHTTP2Errors.DuplicatePseudoHeader,
            is NIOHTTP2Errors.PseudoHeaderAfterRegularHeader, is NIOHTTP2Errors.UnknownPseudoHeader,
            is NIOHTTP2Errors.UnsupportedPseudoHeader, is NIOHTTP2Errors.InvalidPseudoHeaders,
            is NIOHTTP2Errors.MissingHostHeader, is NIOHTTP2Errors.DuplicateHostHeader,
            is NIOHTTP2Errors.EmptyPathHeader, is NIOHTTP2Errors.InvalidStatusValue,
            is NIOHTTP2Errors.TrailersWithoutEndStream, is NIOHTTP2Errors.ForbiddenHeaderField,
            is NIOHTTP2Errors.InvalidPseudoHeaderValue, is NIOHTTP2Errors.ContentLengthViolated,
            is NIOHTTP2Errors.ContentLengthHeadersMismatch, is NIOHTTP2Errors.ContentLengthHeaderNegative,
            is NIOHTTP2Errors.ContentLengthHeaderMalformedValue:
            return true
        default:
            return false
        }
    }
}

/// Counts the control frames a client sends (PING, SETTINGS, PRIORITY: what
/// NIO's control-frame bound counts) and logs the busiest window when the
/// connection closes (`MICROPOD_API_H2_LOG_CONTROL_FRAMES=1`), so a soak can
/// size `HTTP2Limits.controlFrames` against real clients.
final class HTTP2ControlFrameMeter: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private let window: TimeAmount
    private var recent: [NIODeadline] = []
    private var peak = 0
    private var total = 0

    init(window: TimeAmount) { self.window = window }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data).payload {
        case .ping, .settings, .priority:
            let now = NIODeadline.now()
            recent.append(now)
            if let first = recent.firstIndex(where: { now - $0 < window }), first > 0 { recent.removeFirst(first) }
            peak = max(peak, recent.count)
            total += 1
        default:
            break
        }
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        Self.lastPeak.set(peak)
        fputs(
            "HTTP/2 connection closed: \(total) control frames, peak \(peak) per \(window.nanoseconds / 1_000_000_000) s\n",
            stderr)
        context.fireChannelInactive()
    }

    /// The peak of the connection that closed last (tests).
    static let lastPeak = Peak()

    final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        func set(_ value: Int) { lock.withLock { stored = value } }
        var value: Int { lock.withLock { stored } }
    }
}
