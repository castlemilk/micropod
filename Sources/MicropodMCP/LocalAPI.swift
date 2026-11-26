import Darwin
import Foundation
import MicropodCore

/// The local Micropod API daemon — owner of engine config, sandbox VMs and
/// the HVF machine's cache and rig routes. Requests prefer the 0600 Unix
/// domain socket (`~/.micropod/api.sock`; `MICROPOD_API_SOCK` names another,
/// `off` disables it) and use loopback HTTP when the socket is absent or
/// cannot be connected.
///
/// A request is sent once. Loopback HTTP carries it only when the socket
/// refused the connection, before a byte was written: after that the daemon
/// may already be pruning caches or rolling back a payload, so a timeout or
/// a dropped reply is reported as such and never replayed over TCP.
struct LocalAPI: Sendable {
    /// Used when it exists at call time; nil when disabled.
    var socketPath: String?
    var baseURL: URL
    var socketTimeoutSeconds = 60
    var httpTimeout: TimeInterval = 120

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> LocalAPI {
        let port = environment["MICROPOD_API_PORT"] ?? "45454"
        let socket = environment["MICROPOD_API_SOCK"]
        let socketPath: String?
        switch socket {
        case "off": socketPath = nil
        case let path? where !path.isEmpty: socketPath = (path as NSString).expandingTildeInPath
        default:
            socketPath =
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".micropod/api.sock")
                .path
        }
        return LocalAPI(
            socketPath: socketPath,
            baseURL: URL(string: "http://127.0.0.1:\(port)") ?? URL(fileURLWithPath: "/"))
    }

    // MARK: Requests

    func callRaw(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> String {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        if let socketPath, FileManager.default.fileExists(atPath: socketPath) {
            switch await Self.exchange(socketPath, method, path, payload, timeoutSeconds: socketTimeoutSeconds) {
            case .replied(let status, let data):
                return try Self.result(status, data)
            case .notSent:
                break
            case .lost(let detail):
                throw MicropodError.message(
                    "Micropod API: \(method) \(path) reached \(socketPath) but \(detail). It was not resent: "
                        + "the daemon may have applied it, so check its state before calling again.")
            }
        }
        return try await callHTTP(method, path, payload)
    }

    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let raw = try await callRaw(method, path, body)
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
    }

    /// A Connect unary call on the daemon (`/api/micropod.v1.<service>/<method>`).
    func connect(_ service: String, _ method: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await call("POST", "/api/micropod.v1.\(service)/\(method)", body)
    }

    private func callHTTP(_ method: String, _ path: String, _ payload: Data?) async throws -> String {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw MicropodError.message("invalid API path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = httpTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where Self.connectFailures.contains(error.code) {
            throw MicropodError.message(
                "Micropod API daemon not reachable at \(baseURL) — start MicropodAPI or Micropod.app")
        } catch {
            throw MicropodError.message(
                "Micropod API: \(method) \(path) to \(baseURL) failed after it was sent (\(error.localizedDescription)). "
                    + "The daemon may have applied it, so check its state before calling again.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MicropodError.message("Micropod API: \(method) \(path) got no HTTP reply")
        }
        return try Self.result(http.statusCode, data)
    }

    /// URL errors raised before a request reaches the daemon.
    private static let connectFailures: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
    ]

    private static func result(_ status: Int, _ data: Data) throws -> String {
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            throw MicropodError.message(
                json["error"] as? String ?? json["message"] as? String ?? "API error (HTTP \(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Unix socket

    enum Exchange: Sendable, Equatable {
        case replied(status: Int, body: Data)
        /// The connection failed before any byte was written.
        case notSent(String)
        /// Something failed after the request was (perhaps partly) written.
        case lost(String)
    }

    /// One HTTP/1.1 request over the socket, closed after the reply.
    static func exchange(
        _ socketPath: String, _ method: String, _ path: String, _ body: Data?, timeoutSeconds: Int
    ) async -> Exchange {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: exchangeBlocking(socketPath, method, path, body, timeoutSeconds: timeoutSeconds))
            }
        }
    }

    private static func exchangeBlocking(
        _ socketPath: String, _ method: String, _ path: String, _ body: Data?, timeoutSeconds: Int
    ) -> Exchange {
        let fd: Int32
        do {
            fd = try RuntimeUnixSocket.connect(socketPath, expectedUID: getuid())
            try RuntimeUnixSocket.timeout(fd, seconds: timeoutSeconds)
        } catch {
            return .notSent(error.localizedDescription)
        }
        defer { Darwin.close(fd) }
        let payload = body ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        // From the first write on, the daemon may act on the request.
        do {
            try RuntimeUnixSocket.write(Data(head.utf8) + payload, to: fd)
        } catch {
            return .lost("writing the request failed (\(error.localizedDescription))")
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .lost("no reply came within \(timeoutSeconds) s")
                }
                return .lost("reading the reply failed (\(String(cString: strerror(errno))))")
            }
            if count == 0 { break }
            response.append(contentsOf: buffer.prefix(count))
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else {
            return .lost(
                response.isEmpty ? "the daemon closed the connection without a reply" : "the reply was malformed")
        }
        let headerText = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let statusLine = headerText.split(separator: "\r\n", maxSplits: 1).first ?? ""
        guard let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else {
            return .lost("the reply had no HTTP status")
        }
        return .replied(status: status, body: Data(response[split.upperBound...]))
    }

    // MARK: Paths

    /// `raw` as one percent-encoded path segment. Ids come from the model:
    /// whitespace, control characters, `/`, `?` or `#` would rewrite the
    /// request line or the route, so such an id is refused, not encoded.
    static func pathSegment(_ raw: String, name: String) throws -> String {
        let refused = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/?#\\"))
        guard !raw.isEmpty, raw != ".", raw != "..", !raw.unicodeScalars.contains(where: refused.contains) else {
            throw MCPArgumentError(
                message: "\(name) \(String(reflecting: raw)) is not a valid id: it must be non-empty and contain "
                    + "no whitespace, control characters, '/', '\\', '?' or '#'")
        }
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }

    // MARK: Engines other than Apple's

    /// The engine owning `id` when it isn't Apple's — sandbox micro-VMs and
    /// Docker containers live in the API daemon (sandbox VMs in its very
    /// process), so tools must reach them through it. nil for Apple
    /// containers, unknown ids, or no daemon: the caller's usual path.
    func nonAppleEngine(for id: String) async -> String? {
        guard !id.isEmpty, let reply = try? await connect("ContainerService", "GetContainer", ["id": id]),
            let runtime = reply["runtime"] as? String, !runtime.isEmpty, runtime != "apple"
        else { return nil }
        return runtime
    }

    /// The daemon's containers on engines other than Apple's.
    func nonAppleContainers() async -> [[String: Any]] {
        guard let reply = try? await connect("ContainerService", "ListContainers", [:]) else { return [] }
        return (reply["containers"] as? [[String: Any]] ?? []).filter {
            let runtime = $0["runtime"] as? String ?? "apple"
            return !runtime.isEmpty && runtime != "apple"
        }
    }

    /// The daemon's images or volumes (`GET path` → `{key: [...]}`) kept by
    /// engines other than Apple's: the entries it stamps with `runtime`.
    /// Empty without a daemon.
    func nonAppleResources(_ path: String, key: String) async -> [[String: Any]] {
        guard let reply = try? await call("GET", path) else { return [] }
        return (reply[key] as? [[String: Any]] ?? []).filter {
            let runtime = $0["runtime"] as? String ?? "apple"
            return !runtime.isEmpty && runtime != "apple"
        }
    }

    /// The last `lines` log lines. The daemon's log route follows the
    /// container, so read until `lines` arrive or it goes quiet.
    func tailLogs(_ id: String, lines: Int) async throws -> [String] {
        let segment = try Self.pathSegment(id, name: "id")
        guard let url = URL(string: baseURL.absoluteString + "/v1/containers/\(segment)/logs?tail=\(lines)") else {
            throw MicropodError.message("invalid container id: \(id)")
        }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MicropodError.message("logs for \(id) unavailable from the API daemon")
        }
        let collected = LineBox()
        let reader = Task {
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                collected.append(String(line.dropFirst(6)).replacingOccurrences(of: "\\n", with: "\n"))
                if collected.count >= lines { break }
            }
        }
        // The tail arrives at once; after that the stream only waits.
        var quietSince = ContinuousClock.now
        var seen = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while !reader.isCancelled, ContinuousClock.now < deadline, collected.count < lines {
            try? await Task.sleep(for: .milliseconds(100))
            if collected.count != seen {
                seen = collected.count
                quietSince = .now
            } else if ContinuousClock.now - quietSince > .milliseconds(700) {
                break
            }
        }
        reader.cancel()
        return collected.lines
    }

    /// `/v1/runtimes` → one line per engine.
    static func describe(_ json: [String: Any]) -> String {
        let runtimes = json["runtimes"] as? [[String: Any]] ?? []
        return runtimes.map { r in
            let name = r["name"] as? String ?? "?"
            let marker = (r["default"] as? Bool ?? false) ? "*" : " "
            let available =
                (r["available"] as? Bool ?? false) ? "available" : "unavailable: \(r["reason"] as? String ?? "")"
            let enabled = (r["enabled"] as? Bool ?? false) ? "enabled" : "disabled"
            return
                "\(marker) \(name)\t\(r["kind"] as? String ?? "")\t\(available)\t\(enabled)\t\(r["endpoint"] as? String ?? "")"
        }.joined(separator: "\n")
    }
}

/// Lines collected by a background reader.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var count: Int { lock.withLock { storage.count } }
    var lines: [String] { lock.withLock { storage } }
}
