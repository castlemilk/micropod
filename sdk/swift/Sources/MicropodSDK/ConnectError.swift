import Foundation

/// Connect/gRPC status codes surfaced by the Micropod API.
public enum ConnectCode: String, Sendable, Codable, CaseIterable {
    case canceled
    case unknown
    case invalidArgument = "invalid_argument"
    case deadlineExceeded = "deadline_exceeded"
    case notFound = "not_found"
    case alreadyExists = "already_exists"
    case permissionDenied = "permission_denied"
    case resourceExhausted = "resource_exhausted"
    case failedPrecondition = "failed_precondition"
    case aborted
    case outOfRange = "out_of_range"
    case unimplemented
    case internalError = "internal"
    case unavailable
    case dataLoss = "data_loss"
    case unauthenticated
}

/// An error returned by a Connect endpoint (or raised client-side for
/// transport failures and timeouts).
public struct ConnectError: Error, Sendable {
    public let code: ConnectCode
    public let message: String
    /// HTTP status, when the error came from the wire.
    public let httpStatus: Int?

    public init(code: ConnectCode, message: String, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
    }

    /// Codes that are safe to retry for idempotent-unaware unary calls:
    /// transient transport/quota states, not application rejections.
    public static let defaultRetryableCodes: Set<ConnectCode> = [
        .unavailable, .deadlineExceeded, .resourceExhausted, .aborted,
    ]

    static func decode(_ data: Data, httpStatus: Int?) -> ConnectError {
        struct WireError: Decodable {
            struct Detail: Decodable {}
            let code: String
            let message: String?
        }
        if let wire = try? JSONDecoder().decode(WireError.self, from: data),
            let code = ConnectCode(rawValue: wire.code)
        {
            return ConnectError(code: code, message: wire.message ?? "", httpStatus: httpStatus)
        }
        let fallback: ConnectCode = switch httpStatus {
        case 408: .deadlineExceeded
        case 429: .resourceExhausted
        case 502, 503, 504: .unavailable
        case 404: .unimplemented
        case 401, 403: .unauthenticated
        default: .unknown
        }
        let text = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
        return ConnectError(code: fallback, message: String(text), httpStatus: httpStatus)
    }
}
