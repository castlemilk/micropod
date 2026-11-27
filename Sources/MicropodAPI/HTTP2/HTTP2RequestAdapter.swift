import Foundation
import NIOHPACK

/// An HTTP/2 request's header block, mapped onto the `HTTPRequest` every
/// handler (and the request guard) already reads, so both transports hand
/// the same request to the same code.
///
/// `:authority` becomes `host`, the one field `LocalRequestGuard` checks
/// Host by; a `host` field that names something else is refused, so the
/// guard can never be shown one name while the request carries another.
/// The fields the guard and the gRPC framing read (`host`, `origin`,
/// `content-type`, `content-length`, `grpc-timeout`) may appear once. Other
/// repeated fields keep their last value, as the HTTP/1.1 parser does.
enum HTTP2RequestAdapter {
    struct Head: Sendable, Equatable {
        let method: HTTPMethod
        /// `:path`, undecoded (path and query).
        let target: String
        /// Lowercased names; `host` from `:authority`.
        let headers: [String: String]
    }

    enum Outcome: Equatable {
        case head(Head)
        /// Answer with `status` (no handler runs).
        case refuse(status: Int, reason: String)
    }

    /// Fields that may appear once.
    static let singletons: Set<String> = [
        ":authority", ":method", ":path", ":scheme", "host", "origin", "content-type", "content-length",
        "grpc-timeout",
    ]

    /// Ignored over HTTP/2: chunked framing is HTTP/1.1's.
    static let dropped: Set<String> = ["x-micropod-stream-framing"]

    static func head(_ fields: HPACKHeaders) -> Outcome {
        var seen: [String: String] = [:]
        var headers: [String: String] = [:]
        for (name, value, _) in fields {
            let key = name.lowercased()
            if singletons.contains(key), seen[key] != nil {
                return .refuse(status: 400, reason: "repeated \(key) field")
            }
            seen[key] = value
            guard !key.hasPrefix(":"), !dropped.contains(key) else { continue }
            headers[key] = value
        }
        guard let rawMethod = seen[":method"] else { return .refuse(status: 400, reason: "missing :method") }
        guard rawMethod != "CONNECT", let method = HTTPMethod(rawValue: rawMethod) else {
            return .refuse(status: 405, reason: "method \(rawMethod) not allowed")
        }
        guard seen[":scheme"] == "http" else {
            return .refuse(status: 400, reason: "scheme must be http (cleartext HTTP/2 only)")
        }
        guard let target = seen[":path"], target.hasPrefix("/") else {
            return .refuse(status: 400, reason: ":path must start with /")
        }
        switch (seen[":authority"], seen["host"]) {
        case (let authority?, let host?) where authority != host:
            return .refuse(status: 400, reason: "host field differs from :authority")
        case (let authority?, _):
            headers["host"] = authority
        case (nil, _):
            break
        }
        return .head(Head(method: method, target: target, headers: headers))
    }

    /// The request a handler sees.
    static func request(_ head: Head, body: Data) -> HTTPRequest {
        let (path, query) = HTTPParser.splitTarget(head.target)
        return HTTPRequest(method: head.method, path: path, query: query, body: body, headers: head.headers)
    }
}
