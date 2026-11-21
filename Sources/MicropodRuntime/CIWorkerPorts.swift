import Foundation
import MicropodCore
import NIOCore
import NIOPosix

struct CIWorkerPortRelay {
    static let parallelWorkers = 1...4
    let usesKqueue: Bool
    let boundedGuestWindow: Bool
    let dataWorkers: Int

    init(mode: String?, workers: String? = nil) throws {
        boundedGuestWindow = mode == "kqueue-interactive"
        let parallel = boundedGuestWindow || mode == "kqueue-throughput"
        usesKqueue = mode == nil || mode == "kqueue" || parallel
        if let workers {
            guard parallel else {
                throw MicropodError.message(
                    "MICROPOD_CI_PORT_RELAY_WORKERS requires kqueue-throughput or kqueue-interactive")
            }
            guard let count = Int(workers), Self.parallelWorkers.contains(count) else {
                throw MicropodError.message("MICROPOD_CI_PORT_RELAY_WORKERS must be between 1 and 4")
            }
            dataWorkers = count
        } else {
            dataWorkers = parallel ? 2 : 0
        }
    }
}

extension SandboxForwarding {
    /// Each private guest connection leases one Mac loopback listener. The four-byte
    /// request contains the requested Mac port and the port on this VM's own NIC.
    func openNativePortBroker(
        at socket: URL, guest: String, gateway: String, relayConfig: CIWorkerPortRelay, profile: Bool
    ) async throws
        -> NativeLoopbackRelay?
    {
        // A native published lease must originate from its worker gateway.
        let relay =
            relayConfig.usesKqueue
            ? try NativeLoopbackRelay(
                guest: guest, gateway: gateway, dataWorkers: relayConfig.dataWorkers,
                boundedGuestWindow: relayConfig.boundedGuestWindow, profile: profile)
            : nil
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NativePortLease(guest: guest, gateway: gateway, relay: relay))
            }
            .bind(unixDomainSocketPath: socket.path, cleanupExistingSocketFile: true).get()
        if let relay { channel.closeFuture.whenComplete { _ in relay.stop() } }
        track(channel)
        guard chmod(socket.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return relay
    }
}

private final class NativePortLease: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let guest: String
    private let gateway: String
    private let relay: NativeLoopbackRelay?
    private var selected: UInt16?
    private var request = ByteBuffer()
    private var submitted = false
    private var pendingGuest: UInt16?

    init(guest: String, gateway: String, relay: NativeLoopbackRelay?) {
        self.guest = guest
        self.gateway = gateway
        self.relay = relay
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        if submitted {
            // Direct publication waits for this acknowledgement before recycling the
            // guest port. release() drains every previously accepted stream owner.
            guard bytes.readableBytes == 1, bytes.readInteger(as: UInt8.self) == 0x52,
                let selected, let relay
            else {
                context.close(promise: nil)
                return
            }
            relay.release(selected)
            self.selected = nil
            let channel = context.channel
            var ack = channel.allocator.buffer(capacity: 1)
            ack.writeInteger(UInt8(0x52))
            channel.writeAndFlush(ack).whenComplete { _ in channel.close(promise: nil) }
            return
        }
        let length = pendingGuest == nil ? 4 : 2
        guard request.readableBytes + bytes.readableBytes <= length else {
            context.close(promise: nil)
            return
        }
        request.writeBuffer(&bytes)
        guard request.readableBytes == length, let host = request.readInteger(as: UInt16.self) else { return }
        if let pendingGuest, let relay {
            bind(context: context, host: host, port: pendingGuest)
            relay.finishPreparation(guest: pendingGuest)
            self.pendingGuest = nil
            return
        }
        guard let port = request.readInteger(as: UInt16.self) else { return }
        if port == 1, host >= 1024, let relay {
            guard relay.prepare(guest: host) else {
                context.close(promise: nil)
                return
            }
            pendingGuest = host
            var ready = context.channel.allocator.buffer(capacity: 1)
            ready.writeInteger(UInt8(0x50))
            context.writeAndFlush(wrapOutboundOut(ready), promise: nil)
            return
        }
        // Reserved query frame for a guest that lost the original revocation
        // response. The guest still holds the TCP port, excluding any new owner.
        if port == 0, host >= 1024, let relay {
            submitted = true
            let channel = context.channel
            var reply = channel.allocator.buffer(capacity: 1)
            reply.writeInteger(UInt8(relay.hasReleased(guest: host) ? 0x52 : 0))
            channel.writeAndFlush(reply).whenComplete { _ in channel.close(promise: nil) }
            return
        }
        guard port >= 1024 else {
            context.close(promise: nil)
            return
        }
        bind(context: context, host: host, port: port)
    }

    private func bind(context: ChannelHandlerContext, host: UInt16, port: UInt16) {
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
        SandboxForwarding.relay(on: "127.0.0.1", port: host, to: guest, port: port, clients: clients, source: gateway)
            .whenComplete {
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
        if let pendingGuest { relay?.finishPreparation(guest: pendingGuest) }
        if let selected { relay?.release(selected) }
        pendingGuest = nil
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
