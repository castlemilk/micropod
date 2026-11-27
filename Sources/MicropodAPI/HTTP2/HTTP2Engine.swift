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
    private var channels: [ObjectIdentifier: any Channel] = [:]
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
                    self.channels[key] = serverChannel
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
    /// for every inbound stream, the connection manager (idle GOAWAY, the
    /// graceful close and its grace period), and the deadline for a first
    /// stream.
    static func configure(_ channel: any Channel, limits: HTTP2Limits, state: HTTP2ConnectionState) throws {
        let manager = NIOHTTP2ServerConnectionManagementHandler(
            eventLoop: channel.eventLoop,
            configuration: .init(
                maxIdleTime: limits.connectionIdle, maxAge: nil, maxGraceTime: limits.goAwayGrace, keepalive: nil))
        let http2 = NIOHTTP2Handler(
            mode: .server, eventLoop: channel.eventLoop, connectionConfiguration: limits.connectionConfiguration,
            streamConfiguration: limits.streamConfiguration, streamDelegate: manager.http2StreamDelegate
        ) { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandler(HTTP2StreamHandler(connection: state))
            }
        }
        try channel.pipeline.syncOperations.addHandler(http2)
        try channel.pipeline.syncOperations.addHandler(manager)
        try channel.pipeline.syncOperations.addHandler(FirstStreamDeadline(limits.firstStreamDeadline))
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

    /// Every connection gets GOAWAY; once their streams finish (or
    /// `goAwayGrace` ran out) they close, and the event loops stop.
    func stop() {
        let (open, group) = lock.withLock { () -> ([any Channel], MultiThreadedEventLoopGroup?) in
            stopping = true
            return (Array(channels.values), self.group)
        }
        for channel in open { channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent()) }
        guard let group else { return }
        let grace = limits.goAwayGrace.nanoseconds
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(grace)) + .seconds(2)) {
            let remaining = self.lock.withLock { Array(self.channels.values) }
            for channel in remaining { channel.close(promise: nil) }
            group.shutdownGracefully { _ in }
        }
    }

    /// Server channels open now.
    var openConnections: Int { lock.withLock { channels.count } }
}

/// Closes a connection that opened no stream within its deadline.
final class FirstStreamDeadline: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private let deadline: TimeAmount
    private var timer: Scheduled<Void>?
    private var opened = false

    init(_ deadline: TimeAmount) { self.deadline = deadline }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { arm(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        arm(context)
        context.fireChannelActive()
    }

    private func arm(_ context: ChannelHandlerContext) {
        guard timer == nil, !opened else { return }
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: deadline) { bound.value.close(promise: nil) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is NIOHTTP2StreamCreatedEvent {
            opened = true
            timer?.cancel()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func handlerRemoved(context: ChannelHandlerContext) { timer?.cancel() }
}
