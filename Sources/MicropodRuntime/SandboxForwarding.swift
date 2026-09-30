import Foundation
import MicropodCore
import NIOCore
import NIOPosix

/// A published TCP port: `[hostIP:]hostPort:guestPort[/tcp]`. The host side
/// binds loopback unless an address is given.
public struct PortForward: Sendable, Equatable {
    public var hostIP: String
    public var hostPort: UInt16
    public var guestPort: UInt16

    public init(hostIP: String = "127.0.0.1", hostPort: UInt16, guestPort: UInt16) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    public static func parse(_ spec: String) throws -> PortForward {
        var body = spec
        if let slash = body.firstIndex(of: "/") {
            guard body[body.index(after: slash)...] == "tcp" else {
                throw MicropodError.message("invalidArgument: port '\(spec)' — only tcp is forwarded")
            }
            body = String(body[..<slash])
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func port(_ s: String) throws -> UInt16 {
            guard let p = UInt16(s), p > 0 else {
                throw MicropodError.message("invalidArgument: port '\(spec)' — want [hostIP:]hostPort:guestPort")
            }
            return p
        }
        switch parts.count {
        case 2: return PortForward(hostPort: try port(parts[0]), guestPort: try port(parts[1]))
        case 3:
            var address = in_addr()
            guard inet_pton(AF_INET, parts[0], &address) == 1 else {
                throw MicropodError.message("invalidArgument: port '\(spec)' — host address must be IPv4")
            }
            return PortForward(hostIP: parts[0], hostPort: try port(parts[1]), guestPort: try port(parts[2]))
        default:
            throw MicropodError.message("invalidArgument: port '\(spec)' — want [hostIP:]hostPort:guestPort")
        }
    }
}

/// TCP relays for one sandbox: published ports (host → guest) and exposed
/// host ports (guest → the host's loopback, via the network gateway). Opened
/// once the VM's network is up, closed on teardown.
///
/// SwiftNIO rather than Network.framework: NWListener would not bind a
/// vmnet gateway address while the same port was taken on loopback, where
/// a plain socket bound to that one address does.
public final class SandboxForwarding: @unchecked Sendable {
    public static let hostAlias = "host.micropod.internal"

    private let lock = NSLock()
    private var listeners: [Channel] = []

    public init() {}

    /// Accept on `listenHost:listenPort`; relay each connection to
    /// `targetHost:targetPort`. Throws when the address can't be bound
    /// (port in use, address not configured).
    func listen(on listenHost: String, _ listenPort: UInt16, to targetHost: String, _ targetPort: UInt16) throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { inbound in
                // Runs before the accepted channel is registered, so no byte
                // is read until the glue is in place. A refused upstream (the
                // guest isn't listening) fails the future, closing the client.
                ClientBootstrap(group: inbound.eventLoop)
                    .channelOption(.allowRemoteHalfClosure, value: true)
                    .connect(host: targetHost, port: Int(targetPort))
                    .flatMap { outbound in
                        let (a, b) = GlueHandler.matchedPair()
                        return inbound.pipeline.addHandler(a).and(outbound.pipeline.addHandler(b)).map { _ in }
                    }
            }
        do {
            let channel = try bootstrap.bind(host: listenHost, port: Int(listenPort)).wait()
            lock.withLock { listeners.append(channel) }
        } catch {
            throw MicropodError.message("unavailable: listening on \(listenHost):\(listenPort): \(error)")
        }
    }

    /// Close `channel` with the rest on `stop()`.
    func track(_ channel: Channel) {
        lock.withLock { listeners.append(channel) }
    }

    public func stop() {
        let open = lock.withLock {
            defer { listeners = [] }
            return listeners
        }
        open.forEach { $0.close(promise: nil) }
    }
}

/// Joins two channels: bytes read on one are written to the other, reads
/// pause while the partner can't take more, and EOF half-closes the partner
/// (the swift-nio connect-proxy glue).
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler()
        let b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
