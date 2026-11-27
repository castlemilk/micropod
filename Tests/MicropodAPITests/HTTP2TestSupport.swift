import Darwin
import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix

@testable import MicropodAPI

/// What one HTTP/2 stream answered.
struct H2Response: Sendable {
    var status: Int?
    var headers: [(String, String)] = []
    var body = Data()
    var trailers: [(String, String)]?
    var reset: HTTP2ErrorCode?
    /// The connection closed before the stream ended.
    var lost = false

    func header(_ name: String) -> String? { headers.first { $0.0 == name }?.1 }
    func trailer(_ name: String) -> String? { trailers?.first { $0.0 == name }?.1 }
    /// gRPC status: from the trailers, or the headers of a Trailers-Only answer.
    var grpcStatus: Int? { (trailer("grpc-status") ?? header("grpc-status")).flatMap { Int($0) } }
    var grpcMessage: String? { trailer("grpc-message") ?? header("grpc-message") }
    /// The gRPC messages of the body.
    var grpcMessages: [Data] {
        var reader = ConnectEnvelopeReader()
        return reader.feed(body).map(\.payload)
    }
}

/// A NIO HTTP/2 client (prior knowledge) for the API's listeners.
final class H2Client: @unchecked Sendable {
    let channel: any Channel
    private let multiplexer: NIOHTTP2Handler.StreamMultiplexer
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    private init(channel: any Channel, multiplexer: NIOHTTP2Handler.StreamMultiplexer) {
        self.channel = channel
        self.multiplexer = multiplexer
    }

    static func unix(_ path: String) async throws -> H2Client {
        try await connect {
            try await ClientBootstrap(group: group).channelInitializer(initializer).connect(unixDomainSocketPath: path)
                .get()
        }
    }

    static func tcp(_ port: UInt16) async throws -> H2Client {
        try await connect {
            try await ClientBootstrap(group: group).channelInitializer(initializer).connect(
                host: "127.0.0.1", port: Int(port)
            ).get()
        }
    }

    @Sendable private static func initializer(_ channel: any Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            let handler = NIOHTTP2Handler(
                mode: .client, eventLoop: channel.eventLoop, connectionConfiguration: .init(),
                streamConfiguration: .init()
            ) { $0.eventLoop.makeSucceededVoidFuture() }
            try channel.pipeline.syncOperations.addHandler(handler)
        }
    }

    private static func connect(_ open: () async throws -> any Channel) async throws -> H2Client {
        let channel = try await open()
        let multiplexer = try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: NIOHTTP2Handler.self).syncMultiplexer()
        }.get()
        return H2Client(channel: channel, multiplexer: multiplexer)
    }

    func close() { channel.close(promise: nil) }

    /// One request. `authority`: nil leaves it out. `body`: one DATA frame
    /// ending the stream (none, and the HEADERS end it, when nil).
    func request(
        method: String = "GET", path: String, authority: String? = "localhost", scheme: String = "http",
        headers extra: [(String, String)] = [], body: Data? = nil, timeout: TimeAmount = .seconds(10),
        onStream: (@Sendable (any Channel) -> Void)? = nil
    ) async throws -> H2Response {
        var headers = HPACKHeaders()
        headers.add(name: ":method", value: method)
        headers.add(name: ":scheme", value: scheme)
        headers.add(name: ":path", value: path)
        if let authority { headers.add(name: ":authority", value: authority) }
        for (name, value) in extra { headers.add(name: name, value: value) }
        let done = channel.eventLoop.makePromise(of: H2Response.self)
        let stream: any Channel
        do {
            stream = try await multiplexer.createStreamChannel { stream in
                stream.eventLoop.makeCompletedFuture {
                    try stream.pipeline.syncOperations.addHandler(H2Collector(done: done))
                }
            }.get()
        } catch {
            done.fail(error)
            throw error
        }
        onStream?(stream)
        let headersFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: body == nil))
        stream.write(headersFrame, promise: nil)
        if let body {
            stream.write(
                HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: body)), endStream: true)),
                promise: nil)
        }
        stream.flush()
        let timer = channel.eventLoop.scheduleTask(in: timeout) {
            done.fail(H2TestError(description: "no answer within \(timeout)"))
        }
        defer { timer.cancel() }
        return try await done.futureResult.get()
    }

    /// A gRPC unary or server-streaming call with one message.
    func grpc(
        _ path: String, _ message: Data, contentType: String = "application/grpc", authority: String = "localhost",
        extra: [(String, String)] = [], timeout: TimeAmount = .seconds(10)
    ) async throws -> H2Response {
        try await request(
            method: "POST", path: path, authority: authority,
            headers: [("content-type", contentType), ("te", "trailers")] + extra, body: GRPCWire.message(message),
            timeout: timeout)
    }
}

struct H2TestError: Error, CustomStringConvertible { let description: String }

private final class H2Collector: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    private let done: EventLoopPromise<H2Response>
    private var response = H2Response()
    private var finished = false

    init(done: EventLoopPromise<H2Response>) { self.done = done }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers(let frame):
            let fields = frame.headers.map { ($0.name, $0.value) }
            if response.status == nil, let status = frame.headers.first(name: ":status").flatMap({ Int($0) }) {
                response.status = status
                response.headers = fields.filter { !$0.0.hasPrefix(":") }
            } else {
                response.trailers = fields
            }
            if frame.endStream { finish() }
        case .data(let frame):
            if case .byteBuffer(let buffer) = frame.data { response.body.append(contentsOf: buffer.readableBytesView) }
            if frame.endStream { finish() }
        case .rstStream(let code):
            response.reset = code
            finish()
        default: break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            response.lost = true
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done.succeed(response)
    }
}

/// Raw HTTP/2 frames over a blocking socket, for the misbehaviour the NIO
/// client will not send: floods, resets, oversized headers.
final class H2Raw: @unchecked Sendable {
    let wire: GoldenWire
    private var encoder = HPACKEncoder(allocator: ByteBufferAllocator())

    init(_ wire: GoldenWire) { self.wire = wire }

    static func frame(type: UInt8, flags: UInt8 = 0, stream: UInt32 = 0, _ payload: Data = Data()) -> Data {
        var bytes = Data([
            UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF),
        ])
        bytes.append(type)
        bytes.append(flags)
        bytes.append(contentsOf: withUnsafeBytes(of: (stream & 0x7FFF_FFFF).bigEndian) { Array($0) })
        bytes.append(payload)
        return bytes
    }

    /// The preface, SETTINGS (`settings`: id and value pairs) and the ACK
    /// of the server's SETTINGS, so its limits apply at once.
    func start(settings: [(UInt16, UInt32)] = []) throws {
        var payload = Data()
        for (id, value) in settings {
            payload.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0) })
            payload.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
        }
        try wire.send(HTTP2Preface.bytes + Self.frame(type: 0x4, payload) + Self.frame(type: 0x4, flags: 0x1))
    }

    func data(stream: UInt32, _ bytes: Data, endStream: Bool = false) throws {
        try wire.send(Self.frame(type: 0x0, flags: endStream ? 0x1 : 0, stream: stream, bytes))
    }

    func ping() throws { try wire.send(Self.frame(type: 0x6, Data(count: 8))) }

    func block(_ fields: [(String, String)]) -> Data {
        var buffer = ByteBuffer()
        try! encoder.encode(headers: HPACKHeaders(fields), to: &buffer)
        return Data(buffer.readableBytesView)
    }

    static func request(_ path: String, method: String = "GET", authority: String = "localhost") -> [(String, String)] {
        [(":method", method), (":scheme", "http"), (":path", path), (":authority", authority)]
    }

    func headers(stream: UInt32, _ fields: [(String, String)], endStream: Bool = true) throws {
        try wire.send(Self.frame(type: 0x1, flags: 0x4 | (endStream ? 0x1 : 0), stream: stream, block(fields)))
    }

    func reset(stream: UInt32, code: UInt32 = 0x8) throws {
        try wire.send(Self.frame(type: 0x3, stream: stream, Data(withUnsafeBytes(of: code.bigEndian) { Array($0) })))
    }

    /// Frames until the server closes (or `timeout`): their types, and
    /// GOAWAY's error code when one came, and each RST_STREAM's stream and code.
    func drain(timeout: TimeInterval = 5, until: ((UInt8, UInt32) -> Bool)? = nil) -> (
        types: [UInt8], goAway: UInt32?, closed: Bool, resets: [(stream: UInt32, code: UInt32)]
    ) {
        var types: [UInt8] = []
        var goAway: UInt32?
        var resets: [(UInt32, UInt32)] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            guard let chunk = try? wire.read(1, timeout: max(0.01, deadline.timeIntervalSinceNow)) else {
                break
            }
            buffer.append(chunk)
            while buffer.count >= 9 {
                let length =
                    Int(buffer[buffer.startIndex]) << 16 | Int(buffer[buffer.startIndex + 1]) << 8
                    | Int(buffer[buffer.startIndex + 2])
                guard buffer.count >= 9 + length else { break }
                let type = buffer[buffer.startIndex + 3]
                let id = buffer[(buffer.startIndex + 5)..<(buffer.startIndex + 9)]
                let stream = id.reduce(0) { $0 << 8 | UInt32($1) } & 0x7FFF_FFFF
                types.append(type)
                if type == 0x7, length >= 8 {
                    let start = buffer.startIndex + 13
                    goAway = buffer[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
                }
                if type == 0x3, length == 4 {
                    let start = buffer.startIndex + 9
                    resets.append((stream, buffer[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }))
                }
                buffer = Data(buffer.dropFirst(9 + length))
                if let until, until(type, stream) { return (types, goAway, false, resets) }
            }
        }
        let closed = (try? wire.readToEOF(timeout: 0.5)) != nil
        return (types, goAway, closed, resets)
    }
}

/// Runs blocking socket work off Swift's cooperative pool.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { done in
        DispatchQueue.global().async { done.resume(with: Result { try body() }) }
    }
}
