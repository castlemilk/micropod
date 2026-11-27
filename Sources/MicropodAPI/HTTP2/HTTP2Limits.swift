import Foundation
import MicropodCore
import NIOCore
import NIOHTTP2

/// Every bound the API's HTTP/2 transport enforces, set explicitly so a
/// swift-nio-http2 release that changes a default cannot change them.
///
/// SETTINGS sent to the client, flood protections inside NIOHTTP2Handler,
/// the transport's own limits (handlers in flight, request bodies) and its
/// deadlines. The request deadlines and the idle bound follow the HTTP/1.1
/// `ConnectionPolicy`, so both transports time out alike.
struct HTTP2Limits: Sendable {
    // SETTINGS
    var maxConcurrentStreams = 100
    var maxHeaderListSize = 65_536
    var maxFrameSize = 16_384
    var headerTableSize = 4_096
    var initialWindowSize = 1 << 20
    /// The connection-level inbound window NIO keeps topped up.
    var connectionWindowSize = 4 << 20

    // Flood protections (NIOHTTP2Handler)
    var maxSequentialContinuationFrames = 5
    var maxSequentialEmptyDataFrames = 1
    var maxBufferedControlFrames = 1_000
    var maxRecentlyResetStreams = 32
    var resetFrames = RateLimit(count: 200, window: .seconds(30))
    var streamErrors = RateLimit(count: 200, window: .seconds(30))
    /// PING (ACKs included), SETTINGS, PRIORITY, ALTSVC and ORIGIN frames
    /// a client may send. grpc-go sends a BDP PING per data round trip, so
    /// this is far above NIO's 200 per 30 s: a 60 s grpc-go 1.84 follow of
    /// a container logging as fast as it can (~95 MB/min, scripts/h2-interop.sh
    /// --machine, 2026-11-27) peaked at 873 and 854 per 10 s, about 7x under it.
    var controlFrames = RateLimit(count: 6_000, window: .seconds(10))
    var maxConnectionGlitches = 200
    /// Log each connection's busiest control-frame window at its close
    /// (`MICROPOD_API_H2_LOG_CONTROL_FRAMES=1`; soak runs).
    var logControlFrames = false

    // The transport's own
    /// Handlers in flight on one connection, counted until each returned
    /// its answer or its stream ended (a stream the client reset still
    /// holds its handler); past it a stream is refused with REFUSED_STREAM.
    var handlersPerConnection = 100
    /// Handlers in flight on all HTTP/2 connections of one listener.
    var handlersPerListener = 256
    /// Response bodies one connection may hold in memory, answered by
    /// handlers that already gave their places back, while the client has
    /// not taken them (`HTTP2HandlerSlot.answered`). Past it an answer
    /// keeps its handler place until it is written.
    var unsentResponseBytes = 4 << 20
    /// HTTP/2 connections one listener serves at once. Each costs three
    /// descriptors (the client's socket and a socketpair).
    var maxConnections = 64
    /// One request's body (413, or gRPC RESOURCE_EXHAUSTED).
    var streamBodyBytes = HTTPRequestFraming.Limits.api.maxBodyBytes
    /// Request bodies buffered on one connection (RST_STREAM
    /// ENHANCE_YOUR_CALM), checked before a frame is buffered.
    var connectionBodyBytes = 2 * HTTPRequestFraming.Limits.api.maxBodyBytes

    // Deadlines
    /// A request's head and body, from its HEADERS to END_STREAM.
    var requestDeadline: TimeAmount = .seconds(120)
    /// Silence within a request before it has all arrived.
    var requestIdle: TimeAmount = .seconds(30)
    /// A connection that never opens a stream is closed.
    var firstStreamDeadline: TimeAmount = .seconds(30)
    /// A response write the client does not take (flow control, a full
    /// socket) resets its stream and stops its source.
    var writeStall: TimeAmount = .seconds(120)
    /// A connection with no stream open gets GOAWAY(NO_ERROR).
    var connectionIdle: TimeAmount = .seconds(120)
    /// Streams in flight at GOAWAY (idle, `stop()`) get this long to finish.
    var goAwayGrace: TimeAmount = .seconds(5)

    struct RateLimit: Sendable, Equatable {
        var count: Int
        var window: TimeAmount
    }

    init() {}

    /// The live bounds: the request deadlines and idle bound of `policy`,
    /// the connection cap from its kept-connection bound, and environment
    /// overrides (milliseconds or counts) for tests and soak runs:
    /// `MICROPOD_API_H2_CONTROL_FRAMES` (per 10 s, at most 20000),
    /// `MICROPOD_API_H2_FIRST_STREAM_MS`, `MICROPOD_API_H2_WRITE_STALL_MS`,
    /// `MICROPOD_API_H2_GRACE_MS`, `MICROPOD_API_H2_LOG_CONTROL_FRAMES`.
    init(policy: HTTPServer.ConnectionPolicy, environment: [String: String] = ProcessInfo.processInfo.environment) {
        func amount(_ interval: DispatchTimeInterval) -> TimeAmount {
            switch interval {
            case .seconds(let value): return .seconds(Int64(value))
            case .milliseconds(let value): return .milliseconds(Int64(value))
            case .microseconds(let value): return .microseconds(Int64(value))
            case .nanoseconds(let value): return .nanoseconds(Int64(value))
            case .never: return .hours(24 * 365)
            @unknown default: return .seconds(120)
            }
        }
        func milliseconds(_ key: String) -> TimeAmount? {
            environment[key].flatMap { Int64($0) }.map { .milliseconds(max(1, $0)) }
        }
        requestDeadline = amount(policy.requestDeadline)
        requestIdle = amount(policy.requestIdle)
        connectionIdle = amount(policy.keepAliveIdle)
        maxConnections = Self.connectionCap(maxKeptConnections: policy.maxKeptConnections)
        if let count = environment["MICROPOD_API_H2_CONTROL_FRAMES"].flatMap({ Int($0) }), count > 0 {
            controlFrames.count = min(count, 20_000)
        }
        firstStreamDeadline = milliseconds("MICROPOD_API_H2_FIRST_STREAM_MS") ?? firstStreamDeadline
        writeStall = milliseconds("MICROPOD_API_H2_WRITE_STALL_MS") ?? writeStall
        goAwayGrace = milliseconds("MICROPOD_API_H2_GRACE_MS") ?? goAwayGrace
        logControlFrames = environment["MICROPOD_API_H2_LOG_CONTROL_FRAMES"] == "1"
    }

    /// 64, or a quarter of the kept-connection bound when that is less:
    /// an HTTP/2 connection also holds one kept place for its whole life.
    static func connectionCap(maxKeptConnections: Int) -> Int { min(64, max(0, maxKeptConnections / 4)) }

    /// HTTP/2 is served unless `MICROPOD_API_HTTP2=0`; then a preface gets
    /// the HTTP/1.1 answer it always had (505).
    static func enabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["MICROPOD_API_HTTP2"] != "0"
    }

    var settings: HTTP2Settings {
        [
            HTTP2Setting(parameter: .maxConcurrentStreams, value: maxConcurrentStreams),
            HTTP2Setting(parameter: .maxHeaderListSize, value: maxHeaderListSize),
            HTTP2Setting(parameter: .maxFrameSize, value: maxFrameSize),
            HTTP2Setting(parameter: .headerTableSize, value: headerTableSize),
            HTTP2Setting(parameter: .initialWindowSize, value: initialWindowSize),
            HTTP2Setting(parameter: .enablePush, value: 0),
        ]
    }

    var connectionConfiguration: NIOHTTP2Handler.ConnectionConfiguration {
        var configuration = NIOHTTP2Handler.ConnectionConfiguration()
        configuration.initialSettings = settings
        configuration.headerBlockValidation = .enabled
        configuration.contentLengthValidation = .enabled
        configuration.maximumSequentialEmptyDataFrames = maxSequentialEmptyDataFrames
        configuration.maximumBufferedControlFrames = maxBufferedControlFrames
        configuration.maximumSequentialContinuationFrames = maxSequentialContinuationFrames
        configuration.maximumRecentlyResetStreams = maxRecentlyResetStreams
        configuration.maximumConnectionGlitches = maxConnectionGlitches
        configuration.targetWindowSize = connectionWindowSize
        configuration.controlFrameRateLimit.maximumCount = controlFrames.count
        configuration.controlFrameRateLimit.windowLength = controlFrames.window
        return configuration
    }

    var streamConfiguration: NIOHTTP2Handler.StreamConfiguration {
        var configuration = NIOHTTP2Handler.StreamConfiguration()
        configuration.targetWindowSize = initialWindowSize
        configuration.streamResetFrameRateLimit.maximumCount = resetFrames.count
        configuration.streamResetFrameRateLimit.windowLength = resetFrames.window
        configuration.streamErrorRateLimit.maximumCount = streamErrors.count
        configuration.streamErrorRateLimit.windowLength = streamErrors.window
        return configuration
    }
}
