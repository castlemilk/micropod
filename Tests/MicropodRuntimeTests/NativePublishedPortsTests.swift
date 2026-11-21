import MicropodCore
import NIOCore
import NIOPosix
import XCTest

@testable import MicropodRuntime

final class NativePublishedPortsTests: XCTestCase {
    // The peer speaks first, then waits for a TCP half-close before replying.
    private final class ReplyAfterFIN: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        var body = ByteBuffer()

        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "ready")), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var chunk = unwrapInboundIn(data)
            body.writeBuffer(&chunk)
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? ChannelEvent, case .inputClosed = event {
                let channel = context.channel
                context.writeAndFlush(wrapOutboundOut(body)).whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }

    private func server() throws -> Channel {
        try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { $0.pipeline.addHandler(ReplyAfterFIN()) }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    private final class Echo: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.writeAndFlush(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? ChannelEvent, case .inputClosed = event {
                let channel = context.channel
                context.writeAndFlush(wrapOutboundOut(ByteBuffer())).whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }

    func testFullDuplexBulkPreservesBytesAndHalfClose() async throws {
        let upstream = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { upstream.close(promise: nil) }
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1")
        defer { relay.stop() }
        let port = try relay.bind(host: 0, guest: UInt16(try XCTUnwrap(upstream.localAddress?.port)))
        let client = try connect(port)
        let pattern = Data((0...255).map(UInt8.init))
        var data = Data()
        for _ in 0..<65536 { data.append(pattern) }
        let payload = data
        let writer = Task.detached {
            try client.write(contentsOf: payload)
            if shutdown(client.fileDescriptor, SHUT_WR) < 0 { throw POSIXError(.EIO) }
        }
        XCTAssertEqual(try client.readToEnd(), payload)
        try await writer.value
    }

    private func connect(_ port: UInt16) throws -> FileHandle {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        for opt in [SO_RCVTIMEO, SO_SNDTIMEO] {
            XCTAssertEqual(setsockopt(fd, SOL_SOCKET, opt, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))), 0)
        }
        var one: Int32 = 1
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))), 0)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: Int(port))
        let rc = address.withSockAddr { Darwin.connect(fd, $0, socklen_t($1)) }
        guard rc == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return handle
    }

    func testServerFirstHalfCloseAndBackpressure() throws {
        let upstream = try server()
        defer { try? upstream.close().wait() }
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1", profile: true)
        let port = try relay.bind(host: 0, guest: UInt16(try XCTUnwrap(upstream.localAddress?.port)))
        let client = try connect(port)
        XCTAssertEqual(try client.read(upToCount: 5), Data("ready".utf8))
        let pattern = Data((0...255).map(UInt8.init))
        var payload = Data()
        for _ in 0..<32768 { payload.append(pattern) }
        try client.write(contentsOf: payload)
        XCTAssertEqual(shutdown(client.fileDescriptor, SHUT_WR), 0)
        XCTAssertEqual(try client.readToEnd(), payload)
        relay.release(port)
    }

    func testRevocationIsExclusiveAndOnlyClosesOwnedStreams() throws {
        let upstream = try server()
        defer { try? upstream.close().wait() }
        let target = UInt16(try XCTUnwrap(upstream.localAddress?.port))
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1")
        let first = try relay.bind(host: 0, guest: target)
        let second = try relay.bind(host: 0, guest: target)
        XCTAssertThrowsError(try relay.bind(host: first, guest: target))
        let a = try connect(first)
        let b = try connect(second)
        XCTAssertEqual(try a.read(upToCount: 5), Data("ready".utf8))
        XCTAssertEqual(try b.read(upToCount: 5), Data("ready".utf8))
        relay.release(first)
        XCTAssertTrue(try a.read(upToCount: 1)?.isEmpty ?? true)
        XCTAssertThrowsError(try connect(first))
        XCTAssertEqual(try relay.bind(host: first, guest: target), first)
        try b.write(contentsOf: Data([42]))
        XCTAssertEqual(shutdown(b.fileDescriptor, SHUT_WR), 0)
        XCTAssertEqual(try b.readToEnd(), Data([42]))
        relay.stop()
        XCTAssertThrowsError(try connect(first))
        XCTAssertThrowsError(try relay.bind(host: 0, guest: target))
    }

    func testRefusedGuestClosesClient() throws {
        let upstream = try server()
        let target = UInt16(try XCTUnwrap(upstream.localAddress?.port))
        try upstream.close().wait()
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1")
        let port = try relay.bind(host: 0, guest: target)
        let client = try connect(port)
        XCTAssertTrue(try client.read(upToCount: 1)?.isEmpty ?? true)
        relay.release(port)
    }

    func testRevocationClosesActiveClientsAndRejectsLateConnections() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let address = try XCTUnwrap(server.localAddress)
        let clients = NativePortClients()
        let active = try await ClientBootstrap(group: group).connect(to: address).get()
        defer { active.close(promise: nil) }
        XCTAssertTrue(clients.track(active))
        let closed = expectation(description: "active client closed")
        active.closeFuture.whenComplete { _ in closed.fulfill() }
        clients.close()
        await fulfillment(of: [closed], timeout: 2)
        let late = try await ClientBootstrap(group: group).connect(to: address).get()
        defer { late.close(promise: nil) }
        XCTAssertFalse(clients.track(late))
    }

    private static func address(_ hostIP: String?) throws -> JSONValue? {
        let ports = try NativeConfigBuilder.publishedPorts([
            PortSpec(hostPort: 55432, containerPort: 5432, hostIP: hostIP)
        ])
        guard case .object(let port) = ports.first else { return nil }
        return port["hostAddress"]
    }

    func testEmptyHostIPBecomesAllInterfaces() throws {
        XCTAssertEqual(try Self.address(""), .string("0.0.0.0"))
    }

    func testNilHostIPBecomesAllInterfaces() throws {
        XCTAssertEqual(try Self.address(nil), .string("0.0.0.0"))
    }

    func testExplicitHostIPIsKept() throws {
        XCTAssertEqual(try Self.address("127.0.0.1"), .string("127.0.0.1"))
    }
}
