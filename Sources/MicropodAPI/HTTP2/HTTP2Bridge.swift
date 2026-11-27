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
/// it was sent.
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

    init(connection: NWConnection, initial: Data) {
        self.connection = connection
        self.initial = initial
    }

    func handlerAdded(context: ChannelHandlerContext) { HTTP2Bridge.live.add(1) }
    func handlerRemoved(context: ChannelHandlerContext) {
        removed = true
        HTTP2Bridge.live.add(-1)
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
                    case .failure: channel.close(promise: nil)
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
        sending += 1
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        connection.send(
            content: bytes,
            completion: .contentProcessed { error in
                bound.eventLoop.execute {
                    let (handler, context) = bound.value
                    handler.sending -= 1
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

    func channelInactive(context: ChannelHandlerContext) {
        ending = true
        if sending == 0 { end() }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    /// Every byte NIO wrote was sent: close the client's connection after it.
    private func end() {
        guard !ended else { return }
        ended = true
        let connection = self.connection
        connection.send(
            content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
