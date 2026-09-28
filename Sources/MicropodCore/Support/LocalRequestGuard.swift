import Foundation

/// Request admission for Micropod's unauthenticated local HTTP listeners
/// (MicropodAPI on :45454, the Docker shim's TCP listener on :45455).
///
/// Binding to loopback keeps the network out, but not the browser: any web
/// page can `fetch("http://127.0.0.1:45454/...")`, and a CORS-"simple"
/// request (POST with `text/plain`, a form post, a body-less POST) goes out
/// without a preflight — the server acts on it even though the page cannot
/// read the answer. DNS rebinding goes further: `evil.example` re-resolves to
/// 127.0.0.1, so the page's requests are same-origin and it *can* read them.
///
/// Three checks close both:
/// - **Host** must name the listener by a loopback literal (or, for the
///   shim, any IP literal / local-only name). A rebinding page always sends
///   its own DNS name as Host; a page can never be served from an IP literal
///   origin it does not control, so IP-literal hosts are safe.
/// - **Content-Type** (API only): a mutating request must carry one of the
///   Connect/gRPC/JSON types. None of them is CORS-safelisted, so a browser
///   has to preflight — and the preflight only succeeds for allowlisted
///   origins.
/// - **Origin**: when present it must be allowlisted (API), or — for the
///   Docker shim, whose clients never send one — must be absent.
public enum LocalRequestGuard {
    public enum Verdict: Equatable, Sendable {
        case allow
        case reject(status: Int, reason: String)
    }

    /// Media types a mutating API request may carry (parameters such as
    /// `; charset=utf-8` are ignored). None is CORS-safelisted.
    public static let allowedContentTypes: Set<String> = [
        "application/json",
        "application/connect+json",
        "application/proto",
        "application/connect+proto",
        "application/grpc",
        "application/grpc+proto",
        "application/grpc+json",
        "application/grpc-web",
        "application/grpc-web+proto",
        "application/grpc-web+json",
    ]

    // MARK: - Host

    /// Splits a Host header into (lowercased hostname, port?). IPv6 literals
    /// keep their brackets: `[::1]:45454` → ("[::1]", 45454).
    static func splitHost(_ raw: String) -> (host: String, port: UInt16?)? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[...close])
            let rest = value[value.index(after: close)...]
            if rest.isEmpty { return (host, nil) }
            guard rest.first == ":", let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (value, nil)
        case 2:
            guard !parts[0].isEmpty, let port = UInt16(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default: return nil
        }
    }

    /// The loopback names the API answers to.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    /// API rule: exactly `127.0.0.1:<port>`, `localhost:<port>` or
    /// `[::1]:<port>`. A missing Host (not valid HTTP/1.1) is refused too.
    public static func isAllowedAPIHost(_ host: String?, port: UInt16) -> Bool {
        guard let host, let parsed = splitHost(host), parsed.port == port else { return false }
        return loopbackHosts.contains(parsed.host)
    }

    /// Docker shim rule (TCP listener only; the unix socket is not reachable
    /// from a browser). Docker clients send `Host: <addr>:<port>` over TCP —
    /// 127.0.0.1, localhost or, inside a VM, the vmnet gateway IP — and the
    /// Go client's `api.moby.localhost` (older: `docker`) dummy host when it
    /// talks through a socket forwarder. Allowed: any IP literal (a web page
    /// cannot own an IP-literal origin, so this is rebinding-safe),
    /// `localhost` and `*.localhost` (RFC 6761: never resolve off-host), and
    /// `docker`. The port, when given, must be the listener's.
    public static func isAllowedShimHost(_ host: String?, port: UInt16) -> Bool {
        // HTTP/1.0 clients may omit Host; a browser never does.
        guard let host else { return true }
        guard let parsed = splitHost(host) else { return false }
        if let given = parsed.port, given != port { return false }
        let name = parsed.host
        if name == "localhost" || name.hasSuffix(".localhost") || name == "docker" { return true }
        return isIPLiteral(name)
    }

    static func isIPLiteral(_ host: String) -> Bool {
        if host.hasPrefix("["), host.hasSuffix("]") {
            var addr = in6_addr()
            return String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &addr) } == 1
        }
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    // MARK: - Content-Type

    /// The media type without parameters, lowercased.
    static func mediaType(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        let bare = contentType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = bare.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isAllowedContentType(_ contentType: String?) -> Bool {
        guard let type = mediaType(contentType) else { return false }
        return allowedContentTypes.contains(type)
    }

    // MARK: - Verdicts

    /// MicropodAPI admission, evaluated before any handler runs.
    ///
    /// - `headers`: lowercased keys.
    /// - `bodyLength`: bytes of request body received.
    /// - `originAllowed`: the CORS allowlist (``CORSPolicy`` in MicropodAPI).
    ///
    /// Content-Type is required on every POST (a body-less POST is still a
    /// CORS-simple request), and on PUT/PATCH/DELETE whenever they carry a
    /// body. Browsers always preflight PUT/PATCH/DELETE, so a body-less
    /// `curl -X DELETE` keeps working without weakening anything.
    public static func evaluateAPI(
        method: String, headers: [String: String], bodyLength: Int, port: UInt16,
        originAllowed: (String) -> Bool
    ) -> Verdict {
        guard isAllowedAPIHost(headers["host"], port: port) else {
            return .reject(
                status: 403,
                reason: "forbidden: Host must be 127.0.0.1:\(port), localhost:\(port) or [::1]:\(port)")
        }
        if let origin = headers["origin"], !origin.isEmpty, !originAllowed(origin) {
            return .reject(status: 403, reason: "forbidden: origin \(origin) is not allowed")
        }
        let upper = method.uppercased()
        let needsType =
            upper == "POST" || (["PUT", "PATCH", "DELETE"].contains(upper) && bodyLength > 0)
        if needsType, !isAllowedContentType(headers["content-type"]) {
            return .reject(
                status: 415,
                reason:
                    "unsupported media type: use Content-Type application/json (Connect unary), "
                    + "application/connect+json (Connect streams), application/proto or application/grpc")
        }
        return .allow
    }

    /// Docker shim TCP admission. Content-Type cannot discriminate here: the
    /// Docker Go client itself sends `text/plain` on body-less POST/PUT
    /// (`docker start`, `docker pull`) and `application/x-tar` for builds.
    /// Browsers, though, attach `Origin` to every cross-origin non-GET
    /// request (and `Sec-Fetch-*` to every request), which Docker clients
    /// never send — so their presence alone refuses the request.
    public static func evaluateShim(headers: [String: String], port: UInt16) -> Verdict {
        guard isAllowedShimHost(headers["host"], port: port) else {
            return .reject(status: 403, reason: "forbidden: Host \(headers["host"] ?? "") is not a local address")
        }
        if headers["origin"] != nil || headers["sec-fetch-site"] != nil || headers["sec-fetch-mode"] != nil {
            return .reject(status: 403, reason: "forbidden: browser requests are not accepted")
        }
        return .allow
    }
}
