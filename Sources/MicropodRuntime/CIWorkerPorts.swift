import Foundation
import MicropodCore
import NIOCore
import NIOPosix

extension SandboxForwarding {
    /// Each private guest connection leases one Mac loopback listener. The four-byte
    /// request contains the requested Mac port and the port on this VM's own NIC.
    func openNativePortBroker(at socket: URL, guest: String, useKqueue: Bool, profile: Bool) async throws {
        // Keep the established transport as the default while the new path is
        // qualified under sustained connection churn on shared Macs.
        let relay = useKqueue ? try NativeLoopbackRelay(guest: guest, profile: profile) : nil
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NativePortLease(guest: guest, relay: relay))
            }
            .bind(unixDomainSocketPath: socket.path, cleanupExistingSocketFile: true).get()
        if let relay { channel.closeFuture.whenComplete { _ in relay.stop() } }
        track(channel)
        guard chmod(socket.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

private final class NativePortLease: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let guest: String
    private let relay: NativeLoopbackRelay?
    private var selected: UInt16?
    private var request = ByteBuffer()
    private var submitted = false

    init(guest: String, relay: NativeLoopbackRelay?) {
        self.guest = guest
        self.relay = relay
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard !submitted, request.readableBytes + bytes.readableBytes <= 4 else {
            context.close(promise: nil)
            return
        }
        request.writeBuffer(&bytes)
        guard request.readableBytes == 4, let host = request.readInteger(as: UInt16.self),
            let port = request.readInteger(as: UInt16.self), port >= 1024
        else {
            if request.readableBytes == 0 { context.close(promise: nil) }
            return
        }
        submitted = true
        if let relay {
            do {
                let selected = try relay.bind(host: host, guest: port)
                self.selected = selected
                var reply = context.channel.allocator.buffer(capacity: 2)
                reply.writeInteger(selected)
                context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            } catch {
                context.close(promise: nil)
            }
            return
        }
        let owner = context.channel
        let clients = NativePortClients()
        owner.closeFuture.whenComplete { _ in clients.close() }
        SandboxForwarding.relay(on: "127.0.0.1", port: host, to: guest, port: port, clients: clients).whenComplete {
            result in
            guard case .success(let listener) = result else {
                owner.close(promise: nil)
                return
            }
            owner.closeFuture.whenComplete { _ in listener.close(promise: nil) }
            guard let selected = listener.localAddress?.port, let port = UInt16(exactly: selected) else {
                owner.close(promise: nil)
                return
            }
            var reply = owner.allocator.buffer(capacity: 2)
            reply.writeInteger(port)
            owner.writeAndFlush(reply, promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let selected { relay?.release(selected) }
        selected = nil
    }
}

/// Each incoming and guest-side socket lives at most as long as the lease.
/// Accept and revoke may race on different NIO event loops.
final class NativePortClients: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [ObjectIdentifier: Channel] = [:]
    private var revoked = false

    func track(_ channel: Channel) -> Bool {
        let key = ObjectIdentifier(channel)
        let accepted = lock.withLock {
            guard !revoked else { return false }
            open[key] = channel
            return true
        }
        if accepted {
            channel.closeFuture.whenComplete { _ in self.lock.withLock { _ = self.open.removeValue(forKey: key) } }
        }
        return accepted
    }

    func close() {
        let channels = lock.withLock {
            revoked = true
            defer { open.removeAll() }
            return open
        }
        for channel in channels.values { channel.close(promise: nil) }
    }
}
