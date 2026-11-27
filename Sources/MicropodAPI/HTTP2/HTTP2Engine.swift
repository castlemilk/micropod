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
/// HTTP/1.1): until the client's connection is cancelled and its descriptor
/// closed, which can be `HTTP2Limits.closeDrain` after NIO's side closed. A
/// client that takes no byte of what is sent to it for
/// `HTTP2Limits.connectionWriteStall` has its connection cancelled and closed.
/// At most `HTTP2Limits.maxConnections` per listener are
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

    /// One connection's kept place and its count among its listener's
    /// HTTP/2 connections, given back once.
    private final class Place: @unchecked Sendable {
        private let lock = NSLock()
        private var held = true
        private let connection: NWConnection
        private let kept: HTTPServer.KeptConnections
        private let counters: ListenerCounters

        init(_ connection: NWConnection, kept: HTTPServer.KeptConnections, counters: ListenerCounters) {
            self.connection = connection
            self.kept = kept
            self.counters = counters
        }

        func release() {
            let first = lock.withLock { () -> Bool in
                defer { held = false }
                return held
            }
            guard first else { return }
            kept.release(connection)
            counters.releaseConnection()
        }
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
        let place = Place(connection, kept: kept, counters: counters)
        guard let loop = eventLoop(), let fds = HTTP2Bridge.socketpair() else {
            place.release()
            return Self.refuse(connection)
        }
        // The places are held until the client's connection is cancelled,
        // not until NIO's side closed: the bridge may still be sending the
        // last bytes then, and the descriptor is open until it is done.
        connection.stateUpdateHandler = { [weak connection] state in
            guard case .cancelled = state else { return }
            place.release()
            connection?.stateUpdateHandler = nil
        }
        let state = HTTP2ConnectionState(limits: limits, context: context, listener: counters)
        let limits = self.limits
        let server = ClientBootstrap(group: loop)
            // A client that ends its side after its requests (shutdown
            // SHUT_WR, `nc -N`) is still answered, as on HTTP/1.1:
            // `HTTP2ConnectionErrors` then closes the connection gracefully.
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try Self.configure(channel, limits: limits, state: state) }
            }
            .withConnectedSocket(fds.server)
        let pump = ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        HTTP2BridgeHandler(
                            connection: connection, initial: initial, drain: limits.closeDrain,
                            stall: limits.connectionWriteStall,
                            onStall: { server.whenSuccess { $0.close(promise: nil) } }))
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
                    // The bridge cancels the client's connection, which
                    // gives the places back.
                    pumpChannel.close(promise: nil)
                }
                if admitted != true { serverChannel.close(promise: nil) }
            case .failure:
                // Whichever end NIO adopted it closes; the client's
                // connection goes too, and its places with it.
                server.whenSuccess { $0.close(promise: nil) }
                pump.whenSuccess { $0.close(promise: nil) }
                connection.cancel()
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
        let goAways = HTTP2GoAwayWatch()
        try channel.pipeline.syncOperations.addHandler(goAways)
        try channel.pipeline.syncOperations.addHandler(http2)
        try channel.pipeline.syncOperations.addHandler(FirstStreamDeadline(limits.firstStreamDeadline, state: state))
        if limits.logControlFrames {
            try channel.pipeline.syncOperations.addHandler(HTTP2ControlFrameMeter(window: limits.controlFrames.window))
        }
        try channel.pipeline.syncOperations.addHandler(HTTP2ConnectionErrors(goAways: goAways, state: state))
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

/// Closes the connection on a connection error, and gracefully once the
/// client ended its side. NIOHTTP2Handler answers
/// one (a flood past its bound, a malformed frame, a broken header block)
/// with GOAWAY and reports it here, leaving the close to the pipeline;
/// without this the connection would stay open after its GOAWAY.
///
/// A stream's own error (a bad header block, a Content-Length that lies)
/// reaches here too, unwrapped, after
/// NIO reset that stream: those leave the connection and its other streams
/// alone. Repeated ones still end it, through NIO's own bounds
/// (ExcessiveStreamErrors, ExcessiveNumberOfGlitches).
///
/// NIO reports both kinds the same way, so they are told apart by type.
/// Two types are raised at either level (a WINDOW_UPDATE that is zero or
/// overflows the window: a stream error on a stream, a connection error on
/// stream 0); for those the GOAWAY NIO wrote, or did not, decides.
final class HTTP2ConnectionErrors: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    private let goAways: HTTP2GoAwayWatch
    private let state: HTTP2ConnectionState

    init(goAways: HTTP2GoAwayWatch, state: HTTP2ConnectionState) {
        self.goAways = goAways
        self.state = state
    }

    /// The client ended its side. No request can follow, but the ones it
    /// sent are answered: GOAWAY, then the close once no stream is open or
    /// `goAwayGrace` ran out (a client that is gone altogether looks the
    /// same, and its streams end with the first write that fails).
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(ChannelEvent.inputClosed) = event as? ChannelEvent { state.goAway() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard !Self.streamLevel(error) else { return }
        if Self.eitherLevel(error), !goAways.sentError { return }
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
            is NIOHTTP2Errors.InvalidHTTP2HeaderFieldName, is NIOHTTP2Errors.InvalidHTTP2HeaderFieldValue,
            is NIOHTTP2Errors.InvalidPseudoHeaderValue, is NIOHTTP2Errors.ContentLengthViolated,
            is NIOHTTP2Errors.ContentLengthHeadersMismatch, is NIOHTTP2Errors.ContentLengthHeaderNegative,
            is NIOHTTP2Errors.ContentLengthHeaderMalformedValue:
            return true
        default:
            return false
        }
    }

    /// A stream error on a stream, a connection error on stream 0.
    static func eitherLevel(_ error: any Error) -> Bool {
        error is NIOHTTP2Errors.InvalidWindowIncrementSize || error is NIOHTTP2Errors.InvalidFlowControlWindowSize
    }
}

/// Notes a GOAWAY with an error code among the bytes NIOHTTP2Handler writes:
/// the one sign that NIO treated an error as the connection's (it reports a
/// stream's and a connection's error identically). It sits between the
/// socket and NIOHTTP2Handler and reads frame headers only. This server's
/// own GOAWAYs (idle, `stop()`) carry NO_ERROR.
final class HTTP2GoAwayWatch: ChannelOutboundHandler {
    typealias OutboundIn = IOData
    typealias OutboundOut = IOData

    private(set) var sentError = false
    /// A frame header's bytes so far (nine make one).
    private var header: [UInt8] = []
    /// Payload bytes of the current frame still to pass.
    private var payload = 0
    /// A GOAWAY's first eight payload bytes (last stream, error code), while collected.
    private var goAway: [UInt8]?

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if !sentError, case .byteBuffer(let buffer) = unwrapOutboundIn(data) { scan(buffer.readableBytesView) }
        context.write(data, promise: promise)
    }

    func scan(_ bytes: ByteBufferView) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if goAway != nil {
                goAway!.append(bytes[index])
                index += 1
                payload -= 1
                if goAway!.count == 8 {
                    if goAway![4...].contains(where: { $0 != 0 }) { sentError = true }
                    goAway = nil
                }
            } else if payload > 0 {
                let skipped = min(payload, bytes.endIndex - index)
                payload -= skipped
                index += skipped
            } else {
                header.append(bytes[index])
                index += 1
                guard header.count == 9 else { continue }
                payload = Int(header[0]) << 16 | Int(header[1]) << 8 | Int(header[2])
                if header[3] == 0x7, payload >= 8 { goAway = [] }
                header.removeAll(keepingCapacity: true)
            }
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
