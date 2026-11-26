import CPublishedTCP
import MicropodCore
import NIOCore
import NIOPosix
import Network
import XCTest

@testable import MicropodRuntime

final class NativePublishedPortsTests: XCTestCase {
    func testLocalNetworkDiagnosticRequiresAnExplicitDenialOnAWaitingPath() {
        let waiting = NWConnection.State.waiting(.posix(.EHOSTUNREACH))
        XCTAssertEqual(
            NativeLoopbackRelay.localNetworkOutcome(waiting, reason: .localNetworkDenied), "local-network-denied")
        XCTAssertNil(NativeLoopbackRelay.localNetworkOutcome(waiting, reason: .notAvailable))
        XCTAssertNil(NativeLoopbackRelay.localNetworkOutcome(.preparing, reason: .localNetworkDenied))
        XCTAssertEqual(NativeLoopbackRelay.localNetworkOutcome(.ready, reason: .notAvailable), "ready")
    }

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
        XCTAssertFalse(relay.takeGuestTraffic())
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
        XCTAssertTrue(relay.takeGuestTraffic())
        XCTAssertFalse(relay.takeGuestTraffic())
    }

    func testBrokerConfirmsGuestPortRevocationBeforeReuse() async throws {
        let forwarding = SandboxForwarding()
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("mp-" + UUID().uuidString.prefix(8))
        _ = try await forwarding.openNativePortBroker(
            at: socket, guest: "127.0.0.1", gateway: "127.0.0.1",
            relayConfig: CIWorkerPortRelay(mode: "kqueue-throughput", workers: "4"), profile: false)
        defer { forwarding.stop() }
        func openControl() throws -> FileHandle {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let address = try SocketAddress(unixDomainSocketPath: socket.path)
            guard address.withSockAddr({ Darwin.connect(fd, $0, socklen_t($1)) }) == 0 else {
                throw POSIXError(.ECONNREFUSED)
            }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            return file
        }
        // A zero guest port denotes the read-only fence for the other field.
        func query() throws -> Data? {
            let ctl = try openControl()
            try ctl.write(contentsOf: Data([0x84, 0x12, 0, 0]))
            return try ctl.read(upToCount: 1)
        }
        let owner = try openControl()
        // Fragment the preparation frame. A second connection must observe
        // the pending owner even before the first one sends its bind request.
        try owner.write(contentsOf: Data([0x84, 0x12]))
        try owner.write(contentsOf: Data([0, 1]))
        XCTAssertEqual(try owner.read(upToCount: 1), Data([0x50]))
        XCTAssertEqual(try query(), Data([0]))
        try owner.write(contentsOf: Data([0, 0]))
        let port = try XCTUnwrap(owner.read(upToCount: 2))
        XCTAssertEqual(port.count, 2)
        XCTAssertEqual(try query(), Data([0]))
        try owner.write(contentsOf: Data([0x52]))
        XCTAssertEqual(try owner.read(upToCount: 1), Data([0x52]))
        XCTAssertEqual(try query(), Data([0x52]))
        let next = try openControl()
        try next.write(contentsOf: Data([0x84, 0x12, 0, 1]))
        XCTAssertEqual(try next.read(upToCount: 1), Data([0x50]))
        try next.write(contentsOf: port)
        XCTAssertEqual(try next.read(upToCount: 2), port)
        XCTAssertEqual(try query(), Data([0]))
        try next.close()
        for _ in 0..<100 {
            if try query() == Data([0x52]) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Broker did not retire the disconnected owner")
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

    private final class CloseOnRequest: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.close(promise: nil)
        }
    }

    func testGuestFINBeforeFirstReplyIsCountedOnceWithoutReplayingRequest() throws {
        let upstream = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(CloseOnRequest()) }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? upstream.close().wait() }
        let relay = try XCTUnwrap(mp_tcp_relay_create_data("127.0.0.1"))
        defer { mp_tcp_relay_destroy(relay) }
        var port: UInt16 = 0
        let listener = try XCTUnwrap(
            mp_tcp_listen(relay, 0, UInt16(try XCTUnwrap(upstream.localAddress?.port)), &port, 1))
        var stats = mp_tcp_stats()
        defer {
            mp_tcp_release(listener, &stats)
            XCTAssertEqual(stats.accepted, 1)
            XCTAssertEqual(stats.connected, 1)
            XCTAssertEqual(stats.upload_bytes, 4)
            XCTAssertEqual(stats.download_bytes, 0)
            XCTAssertEqual(stats.connect_retries, 0)
            XCTAssertEqual(stats.setup_closes, 0)
            XCTAssertEqual(stats.closes_before_response, 1)
        }
        let client = try connect(port)
        try client.write(contentsOf: Data("once".utf8))
        var ready = pollfd(fd: client.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            mp_tcp_relay_drain(relay, 1)
            if poll(&ready, 1, 5) > 0 {
                XCTAssertTrue(try client.read(upToCount: 1)?.isEmpty ?? true)
                return
            }
        }
        XCTFail("Client did not receive the upstream FIN")
    }

    func testBackendResetBeforeFirstByteReachesClientAndNextConnectionCanReply() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                var length = size
                guard Darwin.bind(fd, $0, size) == 0, listen(fd, 8) == 0, getsockname(fd, $0, &length) == 0
                else { throw POSIXError(.EIO) }
            }
        }
        let relay = try XCTUnwrap(mp_tcp_relay_create_data("127.0.0.1"))
        defer { mp_tcp_relay_destroy(relay) }
        var port: UInt16 = 0
        let listener = try XCTUnwrap(mp_tcp_listen(relay, 0, UInt16(bigEndian: address.sin_port), &port, 1))
        var stats = mp_tcp_stats()
        defer {
            mp_tcp_release(listener, &stats)
            XCTAssertEqual(stats.accepted, 16)
            XCTAssertEqual(stats.resets_forwarded, 8)
            XCTAssertEqual(stats.stream_errors, 8)
            XCTAssertEqual(stats.closes_before_response, 8)
            XCTAssertEqual(stats.connect_retries, 0)
        }
        func waitReadable(_ socket: Int32) throws {
            var f = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let limit = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < limit {
                mp_tcp_relay_drain(relay, 1)
                if poll(&f, 1, 2) > 0 { return }
            }
            throw POSIXError(.ETIMEDOUT)
        }
        for i in 0..<16 {
            let client = try connect(port)
            try client.write(contentsOf: Data([UInt8(i)]))
            try waitReadable(fd)
            let upstream = accept(fd, nil, nil)
            guard upstream >= 0 else { throw POSIXError(.EIO) }
            do {
                let server = FileHandle(fileDescriptor: upstream, closeOnDealloc: true)
                defer { try? server.close() }
                try waitReadable(upstream)
                XCTAssertEqual(try server.read(upToCount: 1), Data([UInt8(i)]))
                if i.isMultiple(of: 2) {
                    var abortive = linger(l_onoff: 1, l_linger: 0)
                    XCTAssertEqual(
                        setsockopt(upstream, SOL_SOCKET, SO_LINGER, &abortive, socklen_t(MemoryLayout<linger>.size)), 0)
                } else {
                    try server.write(contentsOf: Data([UInt8(i)]))
                    XCTAssertEqual(shutdown(upstream, SHUT_WR), 0)
                }
            }
            try waitReadable(client.fileDescriptor)
            var byte: UInt8 = 0
            let count = recv(client.fileDescriptor, &byte, 1, 0)
            if i.isMultiple(of: 2) {
                let error = errno
                XCTAssertEqual(count, -1)
                XCTAssertEqual(error, ECONNRESET)
            } else {
                XCTAssertEqual(count, 1)
                XCTAssertEqual(byte, UInt8(i))
            }
            try client.close()
            mp_tcp_relay_drain(relay, 1)
        }
    }

    private final class CloseOnAccept: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        func channelActive(context: ChannelHandlerContext) { context.close(promise: nil) }
    }

    func testIdleGuestFINIsDistinctFromAFailureAfterRequestWrite() throws {
        let upstream = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(CloseOnAccept()) }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? upstream.close().wait() }
        let relay = try XCTUnwrap(mp_tcp_relay_create_data("127.0.0.1"))
        defer { mp_tcp_relay_destroy(relay) }
        var port: UInt16 = 0
        let listener = try XCTUnwrap(
            mp_tcp_listen(relay, 0, UInt16(try XCTUnwrap(upstream.localAddress?.port)), &port, 1))
        var stats = mp_tcp_stats()
        defer {
            mp_tcp_release(listener, &stats)
            XCTAssertEqual(stats.idle_guest_closes, 1)
            XCTAssertEqual(stats.closes_before_response, 0)
            XCTAssertEqual(stats.stream_errors, 0)
        }
        let client = try connect(port)
        var readable = pollfd(fd: client.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            mp_tcp_relay_drain(relay, 1)
            if poll(&readable, 1, 5) > 0 {
                XCTAssertTrue(try client.read(upToCount: 1)?.isEmpty ?? true)
                return
            }
        }
        XCTFail("Client did not see the idle guest close")
    }

    func testGuestHandshakeWaitsForItsInterfaceAndForwardsBufferedBytesOnce() throws {
        let server = try server()
        defer { try? server.close().wait() }
        let relay = try XCTUnwrap(mp_tcp_relay_create("127.0.0.1"))
        defer { mp_tcp_relay_destroy(relay) }
        // This documentation address is absent from the test Mac. The target
        // still answers over loopback, so an unscoped dial would be observable.
        XCTAssertEqual(mp_tcp_relay_scope(relay, "192.0.2.253"), 0)
        var port: UInt16 = 0
        let listener = try XCTUnwrap(
            mp_tcp_listen(relay, 0, UInt16(try XCTUnwrap(server.localAddress?.port)), &port, 1))
        var stats = mp_tcp_stats()
        defer {
            mp_tcp_release(listener, &stats)
            XCTAssertEqual(stats.accepted, 1)
            XCTAssertEqual(stats.connected, 1)
            XCTAssertEqual(stats.recovered, 1)
            XCTAssertGreaterThan(stats.route_waits, 0)
            XCTAssertEqual(stats.first_dial_stage.map { String(cString: $0) }, "find-gateway-interface")
            XCTAssertEqual(stats.first_dial_errno, EADDRNOTAVAIL)
            XCTAssertEqual(stats.connect_errors, 0)
        }
        let client = try connect(port)
        try client.write(contentsOf: Data("once".utf8))
        XCTAssertEqual(shutdown(client.fileDescriptor, SHUT_WR), 0)
        mp_tcp_relay_drain(relay, 0)
        XCTAssertEqual(mp_tcp_take_path_failure(relay), 1)
        XCTAssertEqual(mp_tcp_take_path_failure(relay), 0)
        XCTAssertEqual(mp_tcp_take_guest_data(relay), 0)
        var event = pollfd(fd: client.fileDescriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&event, 1, 180), 0)
        XCTAssertEqual(mp_tcp_relay_scope(relay, "127.0.0.1"), 0)
        let deadline = ContinuousClock.now + .seconds(3)
        var received = Data()
        while ContinuousClock.now < deadline && received.count < 9 {
            mp_tcp_relay_drain(relay, 0)
            if poll(&event, 1, 5) > 0 {
                // Drive the relay on this thread. Consume only bytes already
                // available so a partial response cannot block the next drain.
                var bytes = [UInt8](repeating: 0, count: 32)
                let count = recv(client.fileDescriptor, &bytes, bytes.count, MSG_DONTWAIT)
                if count > 0 {
                    received.append(contentsOf: bytes.prefix(count))
                } else if count == 0 {
                    break
                } else if errno != EAGAIN && errno != EINTR {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        }
        XCTAssertEqual(received, Data("readyonce".utf8))
        XCTAssertEqual(mp_tcp_take_guest_data(relay), 1)
        XCTAssertEqual(mp_tcp_take_guest_data(relay), 0)
    }

    func testReleaseCancelsAllPendingRetriesAcrossWorkers() throws {
        let server = try server()
        defer { try? server.close().wait() }
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1", gateway: "192.0.2.253")
        defer { relay.stop() }
        let target = UInt16(try XCTUnwrap(server.localAddress?.port))
        let port = try relay.bind(host: 0, guest: target)
        let clients = try (0..<32).map { _ in try connect(port) }
        var event = pollfd(fd: clients[0].fileDescriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&event, 1, 160), 0)
        relay.release(port)
        XCTAssertEqual(try relay.bind(host: port, guest: target), port)
        for client in clients {
            var event = pollfd(fd: client.fileDescriptor, events: Int16(POLLIN), revents: 0)
            XCTAssertGreaterThan(poll(&event, 1, 1000), 0)
            XCTAssertTrue(try client.read(upToCount: 1)?.isEmpty ?? true)
        }
        relay.release(port)
    }

    func testNIORollbackBindsPrivateSource() async throws {
        let upstream = try server()
        defer { upstream.close(promise: nil) }
        let target = UInt16(try XCTUnwrap(upstream.localAddress?.port))
        let clients = NativePortClients()
        defer { clients.close() }
        let listener = try await SandboxForwarding.relay(
            on: "127.0.0.1", port: 0, to: "127.0.0.1", port: target, clients: clients, source: "127.0.0.1"
        ).get()
        defer { listener.close(promise: nil) }
        let socket = try connect(UInt16(try XCTUnwrap(listener.localAddress?.port)))
        XCTAssertEqual(try socket.read(upToCount: 5), Data("ready".utf8))
        let missing = try await SandboxForwarding.relay(
            on: "127.0.0.1", port: 0, to: "127.0.0.1", port: target, clients: clients, source: "192.0.2.253"
        ).get()
        defer { missing.close(promise: nil) }
        let rejected = try connect(UInt16(try XCTUnwrap(missing.localAddress?.port)))
        XCTAssertTrue(try rejected.read(upToCount: 1)?.isEmpty ?? true)
    }

    func testRefusedGuestClosesClient() throws {
        let upstream = try server()
        let target = UInt16(try XCTUnwrap(upstream.localAddress?.port))
        try upstream.close().wait()
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1", gateway: "127.0.0.1", dataWorkers: 0)
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
