import Foundation

/// gRPC over HTTP/2, transcoded onto the Connect handlers the API already
/// has: a gRPC request becomes the Connect request the same handler takes
/// over HTTP/1.1, and the handler's Connect answer becomes gRPC's framing
/// and trailers. No second implementation of any RPC exists.
///
/// - A unary call's one length-prefixed message becomes a Connect unary
///   body (`application/proto`, or `application/json` for `+json`).
/// - A server-streaming call's message keeps its envelope (Connect's and
///   gRPC's prefix are the same five bytes) and becomes
///   `application/connect+proto` (or `+json`).
/// - A 200 unary answer becomes one message and `grpc-status: 0`; anything
///   else is Trailers-Only with the status its Connect error code (or, for
///   a body without one, its HTTP status) maps to.
/// - A stream's data envelopes pass through as gRPC messages; its Connect
///   EndStream becomes the trailers. A stream that ends without one ends
///   with INTERNAL.
enum GRPCWire {
    /// The standard health service (`GRPCHealth`).
    static let healthService = "grpc.health.v1.Health"

    enum Codec: Sendable, Equatable {
        case proto, json

        /// The Connect content type a unary call is handed to its handler with.
        var unaryContentType: String { self == .proto ? "application/proto" : "application/json" }
        /// … and a server-streaming call.
        var streamContentType: String {
            self == .proto ? "application/connect+proto" : "application/connect+json"
        }
    }

    /// The gRPC codec a request's content type names: `application/grpc`
    /// and `application/grpc+proto` are binary, `application/grpc+json`
    /// JSON. Nil for anything else (gRPC-Web included).
    static func codec(contentType: String?) -> Codec? {
        guard
            let type = contentType?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces).lowercased()
        else { return nil }
        switch type {
        case "application/grpc", "application/grpc+proto": return .proto
        case "application/grpc+json": return .json
        default: return nil
        }
    }

    /// A gRPC call this server answers from its headers alone: a method no
    /// service declares, or one that streams from the client (none is
    /// served). Its request body is never waited for.
    static func answersFromHeaders(_ head: HTTP2RequestAdapter.Head) -> Bool {
        guard head.method == .post, codec(contentType: head.headers["content-type"]) != nil else { return false }
        let path = HTTPParser.splitTarget(head.target).path
        return !serves(path.hasPrefix("/api/") ? String(path.dropFirst(4)) : path)
    }

    /// Whether a bare gRPC path names a unary or server-streaming method
    /// this server has (the health service's Check and Watch included).
    static func serves(_ bare: String) -> Bool {
        guard let route = RPCCatalog.route(bare) else { return false }
        if route.service == healthService { return route.method == "Check" || route.method == "Watch" }
        let kind = RPCCatalog.kind(service: route.service, method: route.method)
        return kind == .unary || kind == .serverStream
    }

    /// One uncompressed length-prefixed message.
    static func message(_ payload: Data) -> Data { ConnectEnvelope.frame(payload, flags: 0) }

    enum Body: Equatable {
        case message(Data)
        /// A message with the compressed flag: this server accepts identity only.
        case compressed
        /// Zero, or more than one, message (or a cut one): unary and
        /// server-streaming calls carry exactly one.
        case malformed(String)
    }

    /// The single message of a request body.
    static func singleMessage(_ body: Data) -> Body {
        var reader = ConnectEnvelopeReader()
        let frames = reader.feed(body)
        guard reader.pending == 0 else { return .malformed("request message cut short") }
        guard frames.count == 1 else { return .malformed("expected one request message, got \(frames.count)") }
        if frames[0].flags & 0x01 != 0 { return .compressed }
        return .message(frames[0].payload)
    }

    enum Timeout: Equatable {
        case none
        case after(Duration)
        case malformed
    }

    /// `grpc-timeout`: at most eight digits and a unit (H M S m u n).
    static func timeout(_ value: String?) -> Timeout {
        guard let value else { return .none }
        guard let unit = value.last, value.count >= 2, value.count <= 9 else { return .malformed }
        let digits = value.dropLast()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let amount = Int64(digits) else { return .malformed }
        switch unit {
        case "H": return .after(.seconds(amount * 3600))
        case "M": return .after(.seconds(amount * 60))
        case "S": return .after(.seconds(amount))
        case "m": return .after(.milliseconds(amount))
        case "u": return .after(.microseconds(amount))
        case "n": return .after(.nanoseconds(amount))
        default: return .malformed
        }
    }

    /// `grpc-message`: percent-encoded outside printable ASCII, and `%` itself.
    static func percentEncode(_ message: String) -> String {
        var encoded = ""
        for byte in message.utf8 {
            if byte >= 0x20, byte <= 0x7E, byte != 0x25 {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    /// The gRPC status for an HTTP status without a Connect code
    /// (gRPC's http-grpc-status-mapping).
    static func status(forHTTP status: Int) -> Int {
        switch status {
        case 200: return 0
        case 400: return 13
        case 401: return 16
        case 403: return 7
        case 404: return 12
        case 429, 502, 503, 504: return 14
        default: return 2
        }
    }

    /// A non-200 answer's gRPC status and message: the Connect error body's
    /// `code` (and `message`), else the HTTP status's.
    static func status(ofError status: Int, body: Data) -> (code: Int, message: String) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message =
            (object?["message"] as? String) ?? (object?["error"] as? String)
            ?? String(decoding: body.prefix(512), as: UTF8.self)
        if let raw = object?["code"] as? String, let code = ConnectWireCode(rawValue: raw) {
            return (code.grpcStatus, message)
        }
        return (Self.status(forHTTP: status), message)
    }

    /// A Connect EndStream message's status: `{}` is OK, `{"error": …}` its code.
    static func status(ofEndStream payload: Data) -> (code: Int, message: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return (13, "malformed end of stream")
        }
        guard let error = object["error"] as? [String: Any] else { return (0, "") }
        let code = (error["code"] as? String).flatMap(ConnectWireCode.init(rawValue:))?.grpcStatus ?? 2
        return (code, error["message"] as? String ?? "")
    }

    /// The trailer fields of a status.
    static func trailers(_ code: Int, _ message: String) -> [(String, String)] {
        var fields = [("grpc-status", String(code))]
        if !message.isEmpty { fields.append(("grpc-message", percentEncode(message))) }
        return fields
    }
}

/// Splits a byte stream into Connect (or gRPC) envelopes —
/// `[flags:1][length:4 big-endian][payload]` — however the bytes arrive.
struct ConnectEnvelopeReader {
    private var buffer = Data()
    /// The most one message may hold.
    var maxMessageBytes = 64 * 1024 * 1024

    /// Bytes held of an envelope not yet complete.
    var pending: Int { buffer.count }
    /// An envelope declared longer than `maxMessageBytes`.
    private(set) var oversized = false

    mutating func feed(_ bytes: Data) -> [(flags: UInt8, payload: Data)] {
        buffer.append(bytes)
        var frames: [(UInt8, Data)] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length =
                Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16 | Int(buffer[offset + 3]) << 8
                | Int(buffer[offset + 4])
            guard length <= maxMessageBytes else {
                oversized = true
                break
            }
            guard buffer.endIndex - offset >= 5 + length else { break }
            frames.append((buffer[offset], Data(buffer[(offset + 5)..<(offset + 5 + length)])))
            offset += 5 + length
        }
        buffer = Data(buffer[offset...])
        return frames
    }
}

extension ConnectWireCode {
    /// gRPC's numeric status for this Connect code (the two share one table).
    var grpcStatus: Int {
        switch self {
        case .canceled: return 1
        case .unknown: return 2
        case .invalidArgument: return 3
        case .deadlineExceeded: return 4
        case .notFound: return 5
        case .alreadyExists: return 6
        case .permissionDenied: return 7
        case .resourceExhausted: return 8
        case .failedPrecondition: return 9
        case .aborted: return 10
        case .outOfRange: return 11
        case .unimplemented: return 12
        case .internal: return 13
        case .unavailable: return 14
        case .dataLoss: return 15
        case .unauthenticated: return 16
        }
    }
}
