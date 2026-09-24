import Foundation

/// Browser-facing CORS policy for the local API.
///
/// The daemon binds loopback only, but a `fetch` from a public https origin
/// (the hosted docs explorer) to `http://localhost:45454` is a
/// public→private transition: Chrome sends a CORS preflight carrying
/// `Access-Control-Request-Private-Network` and requires the
/// `Access-Control-Allow-Private-Network` response header, plus an allowed
/// Origin on every response.
///
/// Origins are allowlisted, not `*` — an unauthenticated local API that
/// reflects arbitrary origins would let any website drive the container
/// engine. Defaults: the hosted docs + any localhost/127.0.0.1 origin for
/// local development. Override with `MICROPOD_API_CORS_ORIGINS` (comma list,
/// `*` accepted deliberately for private-network debugging).
enum CORSPolicy {
    static let hostedDocsOrigin = "https://castlemilk.github.io"

    private static func configuredOrigins() -> [String] {
        if let raw = ProcessInfo.processInfo.environment["MICROPOD_API_CORS_ORIGINS"],
            !raw.isEmpty
        {
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return [hostedDocsOrigin]
    }

    /// The value to reflect into `Access-Control-Allow-Origin`, or nil when
    /// the request's origin isn't allowed (response still goes out — the
    /// browser just won't expose it to the page).
    static func allowedOrigin(for request: HTTPRequest) -> String? {
        guard let origin = request.headers["origin"], !origin.isEmpty else {
            return nil
        }
        for allowed in configuredOrigins() {
            if allowed == "*" || allowed.caseInsensitiveCompare(origin) == .orderedSame {
                return origin
            }
        }
        if isLocalOrigin(origin) {
            return origin
        }
        return nil
    }

    /// Loopback origins — local dev servers, `vite dev`, the explorer run
    /// from `next start`, etc.
    private static func isLocalOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host.hasPrefix("localhost:")
    }

    /// CORS + Private-Network-Access headers for this request. Empty when
    /// no Origin is present or the origin isn't allowed. On preflights
    /// (OPTIONS) also emits the Allow-* set.
    static func responseHeaders(for request: HTTPRequest) -> [(String, String)] {
        guard let origin = allowedOrigin(for: request) else { return [] }
        var headers: [(String, String)] = [
            ("Access-Control-Allow-Origin", origin),
            ("Vary", "Origin"),
        ]
        if request.method == .options {
            headers += [
                ("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"),
                (
                    "Access-Control-Allow-Headers",
                    "Content-Type, Connect-Protocol-Version, Connect-Timeout-Ms, Authorization"
                ),
                ("Access-Control-Allow-Private-Network", "true"),
                ("Access-Control-Max-Age", "7200"),
            ]
        }
        return headers
    }
}
