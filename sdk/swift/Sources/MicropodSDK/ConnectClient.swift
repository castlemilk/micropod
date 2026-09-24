import Foundation
import SwiftProtobuf
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal Connect-RPC (JSON) transport over URLSession, with an
/// interceptor chain for retry/timeout/tracing. Supports unary calls and
/// server-streaming calls via Connect envelope framing.
///
/// Wire contract (JSON codec):
/// - unary:  POST {base}/{service}/{method}  body = message JSON
/// - stream: POST same path, content-type application/connect+json,
///           request + response bodies are Connect envelopes
///           [flags:1][length:4 big-endian][payload]
///           flags 0x02 marks the EndStream trailer envelope.
public struct ConnectClient: Sendable {
    public let baseURL: URL
    public let interceptors: [ClientInterceptor]
    let session: URLSession

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        interceptors: [ClientInterceptor] = []
    ) {
        self.baseURL = baseURL
        self.session = session
        self.interceptors = interceptors
    }

    /// Client with the standard resiliency + instrumentation chain:
    /// tracing → retry → timeout → send.
    public static func standard(
        baseURL: URL,
        retry: RetryPolicy = .default,
        timeout: Duration = .seconds(30),
        traceProvider: TraceContextProvider? = RootTraceContextProvider(),
        session: URLSession = .shared,
        extra: [ClientInterceptor] = []
    ) -> ConnectClient {
        var chain: [ClientInterceptor] = []
        if let traceProvider {
            chain.append(TracingInterceptor(provider: traceProvider))
        }
        chain.append(RetryInterceptor(policy: retry))
        chain.append(TimeoutInterceptor(timeout))
        chain.append(contentsOf: extra)
        return ConnectClient(baseURL: baseURL, session: session, interceptors: chain)
    }

    // MARK: - Unary

    public func unary<Request: Message, Response: Message>(
        path: String,
        request: Request,
        response: Response.Type = Response.self,
        headers: [String: String] = [:]
    ) async throws -> Response {
        var ctx = RPCContext(path: path, isStreaming: false, headers: headers)
        ctx.headers["content-type"] = "application/json"
        ctx.headers["accept"] = "application/json"

        let body = try request.jsonUTF8Data()
        let data = try await MicropodSDK.intercept(ctx, chain: interceptors) { ctx in
            try await self.send(ctx, body: body)
        }
        do {
            return try Response(jsonUTF8Data: data)
        } catch {
            throw ConnectError(code: .internalError, message: "response decode failed: \(error)")
        }
    }

    // MARK: - Server streaming

    /// Returns an AsyncThrowingStream of decoded messages. The stream ends
    /// on the EndStream envelope; a trailer `error` field throws
    /// `ConnectError`.
    public func serverStream<Request: Message, Response: Message>(
        path: String,
        request: Request,
        response: Response.Type = Response.self,
        headers: [String: String] = [:]
    ) -> AsyncThrowingStream<Response, Error> {
        var streamHeaders = headers
        streamHeaders["content-type"] = "application/connect+json"
        streamHeaders["accept"] = "application/connect+json"
        streamHeaders["connect-protocol-version"] = "1"
        let ctx = RPCContext(path: path, isStreaming: true, headers: streamHeaders)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let requestBody = try Self.envelope(request.jsonUTF8Data(), flags: 0)
                    // The interceptor chain still applies (tracing, no retry).
                    _ = try await MicropodSDK.intercept(ctx, chain: interceptors) { ctx in
                        let (bytes, response) = try await self.session.bytes(for: self.urlRequest(ctx, body: requestBody))
                        guard let http = response as? HTTPURLResponse else {
                            throw ConnectError(code: .unknown, message: "non-HTTP response")
                        }
                        guard (200...299).contains(http.statusCode) else {
                            var errorData = Data()
                            for try await byte in bytes { errorData.append(byte) }
                            throw ConnectError.decode(errorData, httpStatus: http.statusCode)
                        }
                        try await Self.decodeEnvelopes(bytes) { payload, flags in
                            if flags & 0x02 != 0 {
                                // EndStream trailer — may carry an error.
                                if let trailer = try? JSONDecoder().decode(StreamTrailer.self, from: payload),
                                    let error = trailer.error
                                {
                                    throw ConnectError(
                                        code: ConnectCode(rawValue: error.code) ?? .unknown,
                                        message: error.message ?? ""
                                    )
                                }
                                return false
                            }
                            let message = try Response(jsonUTF8Data: payload)
                            continuation.yield(message)
                            return true
                        }
                        return Data()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamTrailer: Decodable {
        struct WireError: Decodable {
            let code: String
            let message: String?
        }
        let error: WireError?
    }

    // MARK: - Wire

    private func send(_ ctx: RPCContext, body: Data) async throws -> Data {
        let request = urlRequest(ctx, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectError(code: .unknown, message: "non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ConnectError.decode(data, httpStatus: http.statusCode)
        }
        return data
    }

    private func urlRequest(_ ctx: RPCContext, body: Data) -> URLRequest {
        // Drop the leading "/" so the RPC path composes under any base-path
        // prefix (e.g. a reverse-proxied /api mount).
        var request = URLRequest(url: baseURL.appending(path: String(ctx.path.dropFirst())))
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in ctx.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func envelope(_ payload: Data, flags: UInt8) -> Data {
        var frame = Data()
        frame.append(flags)
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        return frame
    }

    /// Incrementally parses the envelope stream, invoking `onEnvelope` per
    /// frame; returning false from it stops iteration early.
    private static func decodeEnvelopes(
        _ bytes: URLSession.AsyncBytes,
        onEnvelope: (Data, UInt8) throws -> Bool
    ) async throws {
        var buffer = Data()
        buffer.reserveCapacity(4096)
        for try await byte in bytes {
            buffer.append(byte)
            // Consume as many complete frames as the buffer holds.
            while buffer.count >= 5 {
                let base = buffer.startIndex
                let length =
                    Int(buffer[base + 1]) << 24 | Int(buffer[base + 2]) << 16
                    | Int(buffer[base + 3]) << 8 | Int(buffer[base + 4])
                guard buffer.count >= 5 + length else { break }
                let flags = buffer[base]
                let payload = Data(buffer[(base + 5)..<(base + 5 + length)])
                buffer = Data(buffer[(base + 5 + length)...])
                if try !onEnvelope(payload, flags) {
                    return
                }
            }
        }
    }
}
