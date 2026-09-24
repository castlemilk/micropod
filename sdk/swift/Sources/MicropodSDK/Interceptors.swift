import Foundation
import OSLog

/// A single RPC in flight. Interceptors may mutate headers/metadata before
/// it is sent and observe the outcome.
public struct RPCContext: Sendable {
    /// Fully-qualified Connect path, e.g. "/micropod.v1.MicropodService/RunContainer".
    public let path: String
    /// Logical service + method for attributes and signposts.
    public let service: String
    public let method: String
    /// True for server-streaming calls — these are never retried.
    public let isStreaming: Bool
    /// Mutable request headers (trace propagation, auth, etc.).
    public var headers: [String: String]

    public init(path: String, isStreaming: Bool, headers: [String: String] = [:]) {
        self.path = path
        self.isStreaming = isStreaming
        self.headers = headers
        let trimmed = path.split(separator: "/")
        self.service = trimmed.count > 1 ? String(trimmed[trimmed.count - 2]) : path
        self.method = trimmed.last.map(String.init) ?? path
    }
}

/// Middleware seam — mirrors the Go `connect.Interceptor` and the
/// connect-es `Interceptor`. Interceptors wrap `next`; they can mutate the
/// context, retry, time out, or record telemetry.
public protocol ClientInterceptor: Sendable {
    func call(_ ctx: RPCContext, next: @escaping @Sendable (RPCContext) async throws -> Data) async throws -> Data
}

/// Applies a chain of interceptors around a terminal send.
public func intercept(
    _ ctx: RPCContext,
    chain: [ClientInterceptor],
    terminal: @escaping @Sendable (RPCContext) async throws -> Data
) async throws -> Data {
    var next = terminal
    for interceptor in chain.reversed() {
        let inner = next
        next = { try await interceptor.call($0, next: inner) }
    }
    return try await next(ctx)
}

// MARK: - Retry

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var initialBackoff: Duration
    public var maxBackoff: Duration
    public var multiplier: Double
    public var retryableCodes: Set<ConnectCode>

    public init(
        maxAttempts: Int = 3,
        initialBackoff: Duration = .milliseconds(100),
        maxBackoff: Duration = .seconds(2),
        multiplier: Double = 2,
        retryableCodes: Set<ConnectCode> = ConnectError.defaultRetryableCodes
    ) {
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.multiplier = multiplier
        self.retryableCodes = retryableCodes
    }

    public static let `default` = RetryPolicy()
}

/// Retries unary calls on transient codes with exponential backoff + jitter.
/// Streaming calls pass through untouched — mid-flight streams can't be
/// replayed safely.
public struct RetryInterceptor: ClientInterceptor {
    let policy: RetryPolicy

    public init(policy: RetryPolicy = .default) {
        self.policy = policy
    }

    private static func nanos(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e9 + Double(duration.components.attoseconds) / 1e9
    }

    public func call(_ ctx: RPCContext, next: @escaping @Sendable (RPCContext) async throws -> Data) async throws -> Data {
        guard !ctx.isStreaming else { return try await next(ctx) }
        var backoffNanos = Self.nanos(policy.initialBackoff)
        let maxBackoffNanos = Self.nanos(policy.maxBackoff)
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await next(ctx)
            } catch let error as ConnectError {
                guard attempt < policy.maxAttempts, policy.retryableCodes.contains(error.code) else {
                    throw error
                }
                // ±25% jitter to avoid thundering-herd retries.
                let sleepNanos = Int64(backoffNanos + Double.random(in: -0.25 ... 0.25) * backoffNanos)
                try await Task.sleep(for: .nanoseconds(sleepNanos))
                backoffNanos = min(backoffNanos * policy.multiplier, maxBackoffNanos)
            } catch {
                throw error
            }
        }
    }
}

// MARK: - Timeout

/// Applies a per-call deadline. URLSession's own timeout covers the socket;
/// this races the whole call so retries and stream setup count against the
/// same budget.
public struct TimeoutInterceptor: ClientInterceptor {
    let timeout: Duration

    public init(_ timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    public func call(_ ctx: RPCContext, next: @escaping @Sendable (RPCContext) async throws -> Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await next(ctx) }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw ConnectError(code: .deadlineExceeded, message: "deadline exceeded after \(self.timeout)")
            }
            guard let result = try await group.next() else {
                throw ConnectError(code: .internalError, message: "empty task group")
            }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Tracing

/// W3C trace context — injectable so a real OTel/swift-otel integration can
/// supply the ambient span; the default provider mints a fresh root context
/// per call so `traceparent` correlation works with zero dependencies.
public struct TraceContext: Sendable {
    public let traceID: String
    public let spanID: String
    public let sampled: Bool

    public init(traceID: String, spanID: String, sampled: Bool = true) {
        self.traceID = traceID
        self.spanID = spanID
        self.sampled = sampled
    }

    /// `traceparent` header value per W3C Trace Context (version 00).
    public var traceparent: String {
        "00-\(traceID)-\(spanID)-\(sampled ? "01" : "00")"
    }
}

public protocol TraceContextProvider: Sendable {
    /// Return the ambient context to propagate, or nil to skip injection.
    /// The SDK does not presume an OTel dependency — bridge `trace.spanContext()`
    /// from your tracer here.
    func currentContext(for rpc: RPCContext) -> TraceContext?
}

/// Generates a fresh root trace context per RPC — useful for correlation
/// when no ambient trace exists.
public struct RootTraceContextProvider: TraceContextProvider {
    public init() {}
    public func currentContext(for rpc: RPCContext) -> TraceContext? {
        func hex(_ bytes: Int) -> String {
            (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        }
        return TraceContext(traceID: hex(16), spanID: hex(8))
    }
}

/// Injects `traceparent` + `tracestate` headers and records an
/// `OSSignposter` interval per RPC (subsystem `com.micropod.sdk`,
/// category `rpc`) — visible in Instruments' Points of Interest /
/// os_signpost tracks. Pair `provider` with your OTel span to make the
/// propagated context part of a real distributed trace.
public struct TracingInterceptor: ClientInterceptor {
    let provider: TraceContextProvider
    let signposter: OSSignposter

    public init(provider: TraceContextProvider = RootTraceContextProvider()) {
        self.provider = provider
        self.signposter = OSSignposter(subsystem: "com.micropod.sdk", category: "rpc")
    }

    public func call(_ ctx: RPCContext, next: @escaping @Sendable (RPCContext) async throws -> Data) async throws -> Data {
        var ctx = ctx
        if let trace = provider.currentContext(for: ctx) {
            ctx.headers["traceparent"] = trace.traceparent
        }
        let interval = signposter.beginInterval("rpc", id: .exclusive, "\(ctx.service)/\(ctx.method)")
        defer { signposter.endInterval("rpc", interval) }
        return try await next(ctx)
    }
}
