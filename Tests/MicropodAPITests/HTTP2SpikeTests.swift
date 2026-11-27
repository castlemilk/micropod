import Darwin
import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix
import XCTest

@testable import MicropodAPI

/// The premise the HTTP/2 transport rests on: one end of a socketpair,
/// adopted by NIO with `ClientBootstrap.withConnectedSocket`, carries a
/// server-mode HTTP/2 connection (SETTINGS exchanged, a stream answered).
final class HTTP2SpikeTests: XCTestCase {
    func testASocketpairEndAdoptedByNIOServesHTTP2() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let settings = group.next().makePromise(of: [HTTP2Setting].self)

        let server = try ClientBootstrap(group: group).channelInitializer { channel in
            channel.configureHTTP2Pipeline(
                mode: .server,
                inboundStreamInitializer: { stream in
                    stream.pipeline.addHandler(SpikeEcho())
                }
            ).map { _ in }
        }.withConnectedSocket(fds[0]).wait()

        let client = try ClientBootstrap(group: group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    NIOHTTP2Handler(mode: .client, connectionConfiguration: .init(), streamConfiguration: .init()))
                try channel.pipeline.syncOperations.addHandler(SettingsWatch(promise: settings))
            }
        }.withConnectedSocket(fds[1]).wait()

        let received = try settings.futureResult.wait()
        XCTAssertTrue(received.contains { $0.parameter == .maxConcurrentStreams }, "the server's SETTINGS arrived")
        try client.close().wait()
        try server.closeFuture.wait()
    }
}

private final class SpikeEcho: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
}

private final class SettingsWatch: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    let promise: EventLoopPromise<[HTTP2Setting]>
    init(promise: EventLoopPromise<[HTTP2Setting]>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .settings(.settings(let values)) = unwrapInboundIn(data).payload { promise.succeed(values) }
    }
}
