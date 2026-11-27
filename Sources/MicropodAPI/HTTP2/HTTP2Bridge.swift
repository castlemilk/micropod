import Darwin
import Foundation
import NIOCore
import Network

/// Carries an accepted Network.framework connection's bytes to NIO, which
/// serves HTTP/2 on it, and NIO's bytes back.
///
/// Network.framework owns the API's listeners (the owner's Unix socket and
/// loopback TCP) and gives no descriptor to hand to NIO. So an HTTP/2
/// connection gets a socketpair: NIO's HTTP/2 server adopts one end, and
/// this bridge pumps between the `NWConnection` and the other end, which NIO
/// also adopts (so both directions get NIO's non-blocking I/O). The bytes
/// already read to recognise the preface go first. Each direction waits for
/// its last write before reading again, so a slow side holds the other back
/// instead of filling memory. NIO's side closing (after its last frame, the
/// trailers included) ends the client's connection once every byte before
/// it was sent, or after `HTTP2Limits.closeDrain` when the client does not
/// take them: its connection is then cancelled with the bytes unsent. While
/// NIO's side is open, a client that takes none of the bytes sent to it for
/// `HTTP2Limits.connectionWriteStall` is cut off the same way.
enum HTTP2Bridge {
    /// Both ends of a new socketpair, close-on-exec, non-blocking, without
    /// SIGPIPE and with 256 KiB buffers each way (a Unix stream socket's
    /// default send buffer is 8 KiB). Nil when the descriptors cannot be had.
    ///
    /// macOS has no SOCK_CLOEXEC; between `socketpair` and `fcntl` a child
    /// started by `fork`+`exec` could inherit the ends. Every child this
    /// process starts goes through `posix_spawn` with
    /// POSIX_SPAWN_CLOEXEC_DEFAULT (`HVFProcesses.spawn`) or Foundation's
    /// `Process`, which also closes every descriptor but stdio in the child.
    static func socketpair() -> (pump: Int32, server: Int32)? {
        var fds: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        for fd in fds {
            var one: Int32 = 1
            var size: Int32 = 256 * 1024
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                close(fds[0])
                close(fds[1])
                return nil
            }
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        return (fds[0], fds[1])
    }

    /// Bridge connections open now (tests: none outlives its connection).
    static let live = LiveCount()
}

/// The pump end's handler: client bytes in from the `NWConnection`, NIO's
/// bytes out to it.
final class HTTP2BridgeHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let connection: NWConnection
    private var initial: Data?
    /// Sends to the client not yet completed.
    private var sending = 0
    /// NIO asked for a read while sends were outstanding.
    private var readWanted = false
    /// NIO's side closed: end the client's connection once `sending` is 0.
    private var ending = false
    private var ended = false
    private var removed = false
    /// 1 once removed, for the sends that complete after it on the
    /// connection's queue: the event loop may have stopped by then.
    private let gone = LiveCount()
    /// How long the client has to take the last bytes once NIO's side closed.
    private let drain: TimeAmount
    /// Cancels the client's connection when `drain` ran out.
    private var deadline: Deadline?
    /// How long sends to the client may be outstanding with none completing.
    private let stall: TimeAmount
    /// Closes the server's channel when the client was cut off for a stall.
    private let onStall: @Sendable () -> Void
    /// When the oldest outstanding send was handed over, or a send last completed.
    private var progress = NIODeadline.now()
    private var stallTimer: Scheduled<Void>?
    /// The client was cut off for a stall: nothing more is sent to it.
    private var cut = false

    /// `DispatchWorkItem.cancel` may be called from any thread.
    private final class Deadline: @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ work: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: work) }
    }

    init(
        connection: NWConnection, initial: Data, drain: TimeAmount, stall: TimeAmount,
        onStall: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.initial = initial
        self.drain = drain
        self.stall = stall
        self.onStall = onStall
    }

    func handlerAdded(context: ChannelHandlerContext) { HTTP2Bridge.live.add(1) }
    func handlerRemoved(context: ChannelHandlerContext) {
        removed = true
        gone.add(1)
        HTTP2Bridge.live.add(-1)
        unwatch()
        expire()
        if !ended { end() }
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        if let initial, !initial.isEmpty {
            self.initial = nil
            channel.writeAndFlush(channel.allocator.buffer(bytes: initial)).whenComplete { [connection] result in
                switch result {
                case .success: Self.receive(from: connection, into: channel)
                case .failure: channel.close(promise: nil)
                }
            }
        } else {
            Self.receive(from: connection, into: channel)
        }
        context.fireChannelActive()
    }

    /// Client → NIO: one receive, written in full before the next.
    private static func receive(from connection: NWConnection, into channel: any Channel) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                channel.writeAndFlush(channel.allocator.buffer(bytes: data)).whenComplete { result in
                    switch result {
                    case .success where isComplete: channel.close(mode: .output, promise: nil)
                    case .success where error != nil: channel.close(promise: nil)
                    case .success: receive(from: connection, into: channel)
                    // NIO's side closed (after a GOAWAY, say): stop taking the
                    // client's bytes, but read what NIO wrote before its
                    // close, so the GOAWAY still reaches the client.
                    case .failure: break
                    }
                }
            } else if error != nil {
                channel.close(promise: nil)
            } else if isComplete {
                // The client closed its side: so does the pump's, and NIO
                // sees EOF.
                channel.close(mode: .output, promise: nil)
            } else {
                receive(from: connection, into: channel)
            }
        }
    }

    /// NIO → client.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        guard !cut else { return }
        if sending == 0 { progress = .now() }
        sending += 1
        watch(context)
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        connection.send(
            content: bytes,
            completion: .contentProcessed { [gone] error in
                guard gone.value == 0 else { return }
                bound.eventLoop.execute {
                    let (handler, context) = bound.value
                    handler.sending -= 1
                    handler.progress = .now()
                    guard !handler.removed else { return }
                    if error != nil {
                        context.close(promise: nil)
                    }
                    handler.drained(context)
                }
            })
    }

    /// Reads from NIO wait for the client to take what was read before.
    func read(context: ChannelHandlerContext) {
        if sending > 0 {
            readWanted = true
        } else {
            context.read()
        }
    }

    private func drained(_ context: ChannelHandlerContext) {
        guard sending == 0 else { return }
        if ending {
            end()
        } else if readWanted {
            readWanted = false
            context.read()
        }
    }

    /// One timer while sends are outstanding, re-armed from the last
    /// progress when it fires: a send that completes costs no timer.
    private func watch(_ context: ChannelHandlerContext) {
        guard stallTimer == nil, sending > 0, !ending, !cut else { return }
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        stallTimer = context.eventLoop.scheduleTask(deadline: progress + stall) {
            let (handler, context) = bound.value
            handler.stallTimer = nil
            guard !handler.removed, !handler.ending, handler.sending > 0 else { return }
            if NIODeadline.now() - handler.progress >= handler.stall {
                handler.stalled(context)
            } else {
                handler.watch(context)
            }
        }
    }

    private func unwatch() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    /// The client took none of the bytes sent to it for `stall`, with NIO's
    /// side still open: nothing NIO writes (a stream's RST_STREAM, a GOAWAY)
    /// can reach it, so no stream of the connection ends and it never goes
    /// idle. Its connection is cancelled with the bytes unsent, which gives
    /// its places back, and both channels close.
    private func stalled(_ context: ChannelHandlerContext) {
        cut = true
        ended = true
        connection.forceCancel()
        onStall()
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ending = true
        unwatch()
        expire()
        if sending == 0 { end() }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    /// NIO's side is gone, so nothing here waits on the client any more. A
    /// send completes only once the client took its bytes: one that stopped
    /// reading would keep its connection, descriptor and unsent bytes for
    /// good. After `drain` the connection is cancelled whatever is unsent.
    private func expire() {
        guard deadline == nil, !cut else { return }
        let connection = self.connection
        let deadline = Deadline { connection.forceCancel() }
        self.deadline = deadline
        // Not the event loop's clock: the loops stop with the server.
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .nanoseconds(Int(drain.nanoseconds)), execute: deadline.item)
    }

    /// Close the client's connection after every byte NIO wrote (the sends
    /// still outstanding go first).
    private func end() {
        guard !ended else { return }
        ended = true
        let connection = self.connection
        let deadline = self.deadline
        connection.send(
            content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
                deadline?.item.cancel()
            })
    }
}
