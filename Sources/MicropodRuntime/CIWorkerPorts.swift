import Foundation
import MicropodCore
import NIOCore
import NIOPosix

extension SandboxForwarding {
    /// Each private guest connection leases one Mac loopback listener. The four-byte
    /// request contains the requested Mac port and the port on this VM's own NIC.
    func openNativePortBroker(at socket: URL, guest: String) async throws {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NativePortLease(guest: guest))
            }
            .bind(unixDomainSocketPath: socket.path, cleanupExistingSocketFile: true).get()
        track(channel)
        guard chmod(socket.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

private final class NativePortLease: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let guest: String
    private var request = ByteBuffer()
    private var submitted = false

    init(guest: String) { self.guest = guest }

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
