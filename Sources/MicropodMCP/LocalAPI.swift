import Darwin
import Foundation
import MicropodCore
import SwiftProtobuf

/// The local Micropod API daemon — owner of the engines, sandbox VMs and the
/// HVF machine — spoken to in binary Connect (`application/proto`) over one
/// persistent HTTP/1.1 connection on its 0600 Unix domain socket
/// (`~/.micropod/api.sock`; `MICROPOD_API_SOCK` names another, `off`
/// disables it), or over loopback TCP when the socket is absent or refuses
/// the connection.
///
/// A request is sent once. Loopback TCP carries it only when the socket
/// refused the connection, before a byte was written: after that the daemon
/// may already be pruning caches or rolling back a payload, so a timeout or
/// a dropped reply is reported as such and never replayed. Before reusing
/// an idle connection the client looks at it without writing — a peer that
/// closed it (or one idle past `idleReconnect`) is replaced first, which is
/// safe because nothing was sent — and calls are serialised on it, so no
/// two requests ever share it at once.
///
/// Since nothing is resent, each call waits as long as its route can take:
/// `socketTimeoutSeconds` for ordinary calls, `longCallSeconds` for those
/// that reply only when the work is done (a pull, a run that pulls, an
/// exec, a prune, a payload rollback, a sandbox run).
///
/// Server streams (logs, sandbox processes, pulls) go over the same
/// connection: the client asks for chunked framing
/// (`X-Micropod-Stream-Framing: chunked`), reads the stream to its end and
/// keeps the connection. One it stops reading early (enough log lines, a
/// deadline) is closed, which ends the stream on the server; the next call
/// dials again.
struct LocalAPI: Sendable {
    /// Used when it exists at call time; nil when disabled.
    var socketPath: String?
    var baseURL: URL
    var socketTimeoutSeconds: Int
    var httpTimeout: TimeInterval
    var longCallSeconds: Int
    private let socketConnection: APIConnection?
    private let tcpConnection: APIConnection

    init(
        socketPath: String?, baseURL: URL, socketTimeoutSeconds: Int = 120, httpTimeout: TimeInterval = 120,
        longCallSeconds: Int = 1800
    ) {
        self.socketPath = socketPath
        self.baseURL = baseURL
        self.socketTimeoutSeconds = socketTimeoutSeconds
        self.httpTimeout = httpTimeout
        self.longCallSeconds = longCallSeconds
        socketConnection = socketPath.map { APIConnection(.unix($0)) }
        tcpConnection = APIConnection(.tcp(port: baseURL.port ?? 45454))
    }

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

    /// No daemon took the connection, on the socket or over TCP: nothing
    /// was sent. Tools that can run without the daemon do so on this error.
    struct Unreachable: Error, LocalizedError {
        let detail: String
        var errorDescription: String? {
            "Micropod API daemon not reachable (\(detail)) — start MicropodAPI or Micropod.app"
        }
    }

    /// The daemon answered with a Connect error.
    struct RemoteError: Error, LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    /// Connections dialed so far (socket, then TCP).
    var connectionsOpened: (socket: Int, tcp: Int) {
        (socketConnection?.opened ?? 0, tcpConnection.opened)
    }

    // MARK: Unary

    /// `micropod.v1.<service>/<method>` in binary protobuf, decoded as `R`.
    /// `timeout`: seconds to wait for the reply (default `socketTimeoutSeconds`).
    func unary<R: Message>(
        _ service: String, _ method: String, _ request: some Message, as: R.Type, timeout: Int? = nil
    ) async throws -> R {
        let path = "/api/micropod.v1.\(service)/\(method)"
        let body = try request.serializedData()
        let seconds = timeout ?? socketTimeoutSeconds
        var refused = "loopback TCP"
        if let socketPath, let socketConnection, FileManager.default.fileExists(atPath: socketPath) {
            switch await socketConnection.exchange(
                path, contentType: "application/proto", body: body, timeoutSeconds: seconds)
            {
            case .replied(let status, let contentType, let data):
                return try Self.result(R.self, status, contentType, data)
            case .notSent(let detail):
                refused = "\(socketPath): \(detail)"
            case .lost(let detail):
                throw Self.lost(method, path, at: socketPath, detail)
            }
        }
        switch await tcpConnection.exchange(path, contentType: "application/proto", body: body, timeoutSeconds: seconds)
        {
        case .replied(let status, let contentType, let data):
            return try Self.result(R.self, status, contentType, data)
        case .notSent(let detail):
            throw Unreachable(detail: socketPath == nil ? detail : "\(refused); \(baseURL): \(detail)")
        case .lost(let detail):
            throw Self.lost(method, path, at: baseURL.absoluteString, detail)
        }
    }

    /// A unary call whose reply carries nothing the caller needs.
    func call(_ service: String, _ method: String, _ request: some Message, timeout: Int? = nil) async throws {
        _ = try await unary(service, method, request, as: Micropod_V1_Empty.self, timeout: timeout)
    }

    private static func lost(_ method: String, _ path: String, at where_: String, _ detail: String) -> MicropodError {
        MicropodError.message(
            "Micropod API: \(method) (\(path)) reached \(where_) but \(detail). It was not resent: "
                + "the daemon may have applied it, so check its state before calling again.")
    }

    private static func result<R: Message>(_ type: R.Type, _ status: Int, _ contentType: String, _ data: Data) throws
        -> R
    {
        guard status == 200 else { throw remoteError(status, data) }
        guard contentType.hasPrefix("application/proto") else {
            throw MicropodError.message(
                "Micropod API answered \(contentType.isEmpty ? "no content type" : contentType), not application/proto")
        }
        return try R(serializedBytes: data)
    }

    static func remoteError(_ status: Int, _ data: Data) -> Error {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let message = json["message"] as? String ?? json["error"] as? String ?? "API error (HTTP \(status))"
        return RemoteError(code: json["code"] as? String ?? "unknown", message: message)
    }

    // MARK: Server streams

    /// A server-streaming call in binary Connect on the persistent
    /// connection. `onMessage` returns false to stop reading (the connection
    /// is then closed, which ends the stream on the server). Stops at the end
    /// of the stream, at `deadline`, or after `quiet` without a message. An
    /// error in the end-of-stream frame is thrown. Nothing is resent.
    func stream<R: Message>(
        _ service: String, _ method: String, _ request: some Message, as: R.Type,
        deadline: Duration, quiet: Duration? = nil, onMessage: @escaping @Sendable (R) -> Bool
    ) async throws {
        let path = "/api/micropod.v1.\(service)/\(method)"
        let body = ConnectFrames.envelope(try request.serializedData(), flags: 0)
        var refused = "loopback TCP"
        if let socketPath, let socketConnection, FileManager.default.fileExists(atPath: socketPath) {
            switch await socketConnection.stream(
                path, body, deadline: deadline, quiet: quiet, onFrame: Self.decoder(onMessage))
            {
            case .finished(let trailer): return try Self.check(trailer)
            case .rejected(let status, let data): throw Self.remoteError(status, data)
            case .notSent(let detail): refused = "\(socketPath): \(detail)"
            case .lost(let detail): throw Self.lost(method, path, at: socketPath, detail)
            }
        }
        switch await tcpConnection.stream(
            path, body, deadline: deadline, quiet: quiet, onFrame: Self.decoder(onMessage))
        {
        case .finished(let trailer): return try Self.check(trailer)
        case .rejected(let status, let data): throw Self.remoteError(status, data)
        case .notSent(let detail):
            throw Unreachable(detail: socketPath == nil ? detail : "\(refused); \(baseURL): \(detail)")
        case .lost(let detail): throw Self.lost(method, path, at: baseURL.absoluteString, detail)
        }
    }

    private static func decoder<R: Message>(_ onMessage: @escaping @Sendable (R) -> Bool)
        -> @Sendable (Data) throws -> Bool
    {
        { payload in onMessage(try R(serializedBytes: payload)) }
    }

    /// The end-of-stream frame's `{"error": {code, message}}`, if any.
    private static func check(_ trailer: Data?) throws {
        guard let trailer,
            let json = try? JSONSerialization.jsonObject(with: trailer) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return }
        throw RemoteError(
            code: error["code"] as? String ?? "unknown", message: error["message"] as? String ?? "stream failed")
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

    /// `ListRuntimes` → one line per engine.
    static func describe(_ response: Micropod_V1_ListRuntimesResponse) -> String {
        response.runtimes.map { r in
            let marker = r.default ? "*" : " "
            let available = r.available ? "available" : "unavailable: \(r.reason)"
            let enabled = r.enabled ? "enabled" : "disabled"
            return "\(marker) \(r.name)\t\(r.kind)\t\(available)\t\(enabled)\t\(r.endpoint)"
        }.joined(separator: "\n")
    }
}

// MARK: - Transport

/// Where the API listens.
enum APIEndpoint: Sendable, Equatable {
    case unix(String)
    case tcp(port: Int)

    /// A request's Host: the API checks it against its own loopback port.
    var host: String {
        switch self {
        case .unix: "localhost"
        case .tcp(let port): "127.0.0.1:\(port)"
        }
    }

    /// A connected socket, or why none could be made (nothing was sent).
    func connect(timeoutSeconds: Int) -> Result<Int32, MicropodError> {
        switch self {
        case .unix(let path):
            do {
                let fd = try RuntimeUnixSocket.connect(path, expectedUID: getuid())
                try RuntimeUnixSocket.timeout(fd, seconds: timeoutSeconds)
                return .success(fd)
            } catch {
                return .failure(.message(error.localizedDescription))
            }
        case .tcp(let port):
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return .failure(.message(String(cString: strerror(errno)))) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                return .failure(.message("connect 127.0.0.1:\(port): \(message)"))
            }
            do {
                try RuntimeUnixSocket.timeout(fd, seconds: timeoutSeconds)
            } catch {
                Darwin.close(fd)
                return .failure(.message(error.localizedDescription))
            }
            return .success(fd)
        }
    }
}

/// One HTTP/1.1 exchange's outcome.
enum Exchange: Sendable, Equatable {
    case replied(status: Int, contentType: String, body: Data)
    /// The connection failed before any byte was written.
    case notSent(String)
    /// Something failed after the request was (perhaps partly) written.
    case lost(String)
}

/// A persistent HTTP/1.1 connection to the API, one request at a time.
/// Blocking socket I/O runs on its own serial queue, never on the caller's
/// thread.
final class APIConnection: @unchecked Sendable {
    /// An idle connection older than this is replaced before a request: the
    /// server closes idle ones after 120 s (MICROPOD_API_KEEPALIVE_IDLE_MS),
    /// and 90 s is Go's IdleConnTimeout, which the server's default outlasts.
    static let idleReconnect: Duration = .seconds(90)

    let endpoint: APIEndpoint
    private let queue = DispatchQueue(label: "micropod.mcp.api-connection")
    private let lock = NSLock()
    // Touched only on `queue`.
    private var fd: Int32 = -1
    private var lastUsed = ContinuousClock.now
    private var dialed = 0

    init(_ endpoint: APIEndpoint) { self.endpoint = endpoint }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    var opened: Int { lock.withLock { dialed } }

    func exchange(_ path: String, contentType: String, body: Data, timeoutSeconds: Int) async -> Exchange {
        await withCheckedContinuation { done in
            queue.async {
                done.resume(
                    returning: self.exchangeOnQueue(
                        path, contentType: contentType, body: body, timeoutSeconds: timeoutSeconds))
            }
        }
    }

    private func drop() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// The connection a request goes out on: the kept one when the server
    /// still holds it and it has not idled past `idleReconnect`, else a new
    /// one; nil (and why) when none could be made.
    private func ready(timeoutSeconds: Int) -> String? {
        if fd >= 0, ContinuousClock.now - lastUsed > Self.idleReconnect || !HTTPWire.isOpenAndQuiet(fd) {
            drop()
        }
        if fd < 0 {
            switch endpoint.connect(timeoutSeconds: timeoutSeconds) {
            case .failure(let error): return error.localizedDescription
            case .success(let connected):
                fd = connected
                lock.withLock { dialed += 1 }
            }
        } else {
            try? RuntimeUnixSocket.timeout(fd, seconds: timeoutSeconds)
        }
        return nil
    }

    /// A server stream on this connection (see `LocalAPI.stream`).
    func stream(
        _ path: String, _ body: Data, deadline: Duration, quiet: Duration?,
        onFrame: @escaping @Sendable (Data) throws -> Bool
    ) async -> APIStream.Outcome {
        await withCheckedContinuation { done in
            queue.async {
                done.resume(returning: self.streamOnQueue(path, body, deadline, quiet, onFrame))
            }
        }
    }

    private func streamOnQueue(
        _ path: String, _ body: Data, _ deadline: Duration, _ quiet: Duration?,
        _ onFrame: @Sendable (Data) throws -> Bool
    ) -> APIStream.Outcome {
        if let refused = ready(timeoutSeconds: max(1, Int(deadline.components.seconds))) { return .notSent(refused) }
        let head =
            "POST \(path) HTTP/1.1\r\nHost: \(endpoint.host)\r\nContent-Type: application/connect+proto\r\n"
            + "Connect-Protocol-Version: 1\r\nX-Micropod-Stream-Framing: chunked\r\n"
            + "Content-Length: \(body.count)\r\n\r\n"
        do {
            try RuntimeUnixSocket.write(Data(head.utf8) + body, to: fd)
        } catch {
            drop()
            return .lost("writing the request failed (\(error.localizedDescription))")
        }
        let outcome = APIStream.read(fd: fd, deadline: deadline, quiet: quiet, onFrame: onFrame)
        lastUsed = .now
        if !outcome.reusable { drop() }
        return outcome.outcome
    }

    private func exchangeOnQueue(_ path: String, contentType: String, body: Data, timeoutSeconds: Int) -> Exchange {
        if let refused = ready(timeoutSeconds: timeoutSeconds) { return .notSent(refused) }
        let head =
            "POST \(path) HTTP/1.1\r\nHost: \(endpoint.host)\r\nContent-Type: \(contentType)\r\n"
            + "Connect-Protocol-Version: 1\r\nContent-Length: \(body.count)\r\n\r\n"
        // From the first write on, the daemon may act on the request.
        do {
            try RuntimeUnixSocket.write(Data(head.utf8) + body, to: fd)
        } catch {
            drop()
            return .lost("writing the request failed (\(error.localizedDescription))")
        }
        var reader = HTTPWire.Reader(fd: fd)
        switch reader.response(timeoutSeconds: timeoutSeconds) {
        case .failure(let failure):
            drop()
            return .lost(failure.detail)
        case .success(let response):
            lastUsed = .now
            // Bytes past the reply would be a reply to nothing: never reuse.
            if response.closes || reader.hasBuffered { drop() }
            return .replied(status: response.status, contentType: response.contentType, body: response.body)
        }
    }
}

/// Reading one server stream's reply.
enum APIStream {
    enum Outcome: Sendable {
        /// The stream ended (its end-of-stream frame's JSON, if it sent one).
        case finished(Data?)
        /// The server answered with an error instead of a stream.
        case rejected(status: Int, body: Data)
        case notSent(String)
        case lost(String)
    }

    /// Reads the reply on `fd`; `reusable` when the body was read to its end
    /// and the server keeps the connection.
    static func read(
        fd: Int32, deadline: Duration, quiet: Duration?, onFrame: @Sendable (Data) throws -> Bool
    ) -> (outcome: Outcome, reusable: Bool) {
        let end = ContinuousClock.now + deadline
        var reader = HTTPWire.Reader(fd: fd)
        let response: HTTPWire.Response
        switch reader.head(until: end) {
        case .failure(let failure): return (.lost(failure.detail), false)
        case .success(let head): response = head
        }
        guard response.status == 200 else {
            switch reader.body(of: response, until: end) {
            case .success(let data):
                return (.rejected(status: response.status, body: data), !response.closes && !reader.hasBuffered)
            case .failure(let failure): return (.lost(failure.detail), false)
            }
        }
        reader.chunked = response.chunked
        // `quiet` counts from the last message once one came; before the
        // first, only the deadline applies (a tail can take a while).
        var lastFrame: ContinuousClock.Instant?
        while true {
            let wait = quiet.flatMap { gap in lastFrame.map { min(end, $0 + gap) } } ?? end
            switch reader.frame(until: wait) {
            case .frame(let flags, let payload):
                lastFrame = .now
                if flags & 0x02 != 0 {
                    // The body ends with the last chunk; read it to keep the connection.
                    let finished = response.chunked && reader.finishBody(until: end)
                    return (.finished(payload), finished && !response.closes && !reader.hasBuffered)
                }
                do {
                    guard try onFrame(payload) else { return (.finished(nil), false) }
                } catch {
                    return (.lost("a stream message did not decode (\(error.localizedDescription))"), false)
                }
            case .timedOut:
                // The deadline, or `quiet` after the last message: the
                // caller's own end (a log tail), not the server's.
                return (.finished(nil), false)
            case .closed:
                // A server ends every stream with its end-of-stream frame;
                // a close before it is an API (or the runtime behind it)
                // that went away mid-stream, never a success.
                return (.lost("the stream ended without its end-of-stream frame"), false)
            case .failed(let detail):
                return (.lost(detail), false)
            }
        }
    }
}

/// Connect envelope framing: a flags byte, a big-endian length, the payload.
enum ConnectFrames {
    static func envelope(_ payload: Data, flags: UInt8) -> Data {
        var frame = Data([flags])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

/// Reading HTTP/1.1 replies from a blocking socket.
enum HTTPWire {
    /// Nothing to read and not closed: a connection the server still keeps.
    static func isOpenAndQuiet(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if peeked < 0 { return errno == EAGAIN || errno == EWOULDBLOCK }
        // 0: the peer closed it; > 0: bytes nobody asked for.
        return false
    }

    struct Response {
        var status: Int
        var contentType: String
        var contentLength: Int?
        var closes: Bool
        /// `Transfer-Encoding: chunked` (a stream the client asked to keep).
        var chunked = false
        var body: Data
    }

    enum Frame {
        case frame(flags: UInt8, payload: Data)
        case timedOut
        case closed
        case failed(String)
    }

    struct Reader {
        let fd: Int32
        private var buffer = Data()
        private var eof = false
        /// The body is chunked: frames are read from `decoded`.
        var chunked = false
        private var decoded = Data()
        private var lastChunkSeen = false

        init(fd: Int32) { self.fd = fd }

        var hasBuffered: Bool { !buffer.isEmpty }

        /// Reads more; false at EOF. `timeout` errors are returned.
        private mutating func fill(until deadline: ContinuousClock.Instant?) -> Result<Bool, ReadError> {
            if let deadline {
                let left = deadline - .now
                guard left > .zero else { return .failure(.timedOut) }
                var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = Int32(
                    clamping: max(
                        1, left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000))
                let ready = Darwin.poll(&poll, 1, ms)
                if ready == 0 { return .failure(.timedOut) }
                if ready < 0, errno != EINTR { return .failure(.failed(String(cString: strerror(errno)))) }
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return .failure(.timedOut) }
                    return .failure(.failed("reading the reply failed (\(String(cString: strerror(errno))))"))
                }
                if count == 0 {
                    eof = true
                    return .success(false)
                }
                buffer.append(contentsOf: chunk[0..<count])
                return .success(true)
            }
        }

        enum ReadError: Error {
            case timedOut
            case failed(String)
        }

        mutating func head(until deadline: ContinuousClock.Instant?) -> Result<Response, Failure> {
            let separator = Data("\r\n\r\n".utf8)
            while buffer.range(of: separator) == nil {
                guard buffer.count < 65536 else { return .failure(Failure("the reply head was too long")) }
                switch fill(until: deadline) {
                case .success(true): continue
                case .success(false):
                    return .failure(
                        Failure(
                            buffer.isEmpty
                                ? "the daemon closed the connection without a reply" : "the reply was cut short"))
                case .failure(.timedOut): return .failure(Failure("no reply came in time"))
                case .failure(.failed(let detail)): return .failure(Failure(detail))
                }
            }
            guard let split = buffer.range(of: separator) else { return .failure(Failure("the reply was malformed")) }
            let text = String(decoding: buffer[buffer.startIndex..<split.lowerBound], as: UTF8.self)
            buffer = Data(buffer[split.upperBound...])
            let lines = text.components(separatedBy: "\r\n")
            let statusParts = lines.first?.split(separator: " ") ?? []
            guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
                return .failure(Failure("the reply had no HTTP status"))
            }
            var response = Response(status: status, contentType: "", contentLength: nil, closes: false, body: Data())
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch name {
                case "content-type": response.contentType = value.lowercased()
                case "content-length": response.contentLength = Int(value)
                case "connection" where value.lowercased().contains("close"): response.closes = true
                case "transfer-encoding":
                    // Only a stream the client asked to keep comes chunked.
                    if value.lowercased() == "chunked" { response.chunked = true } else { response.closes = true }
                default: break
                }
            }
            if statusParts[0] == "HTTP/1.0" { response.closes = true }
            return .success(response)
        }

        mutating func body(of response: Response, until deadline: ContinuousClock.Instant?) -> Result<Data, Failure> {
            if let length = response.contentLength {
                while buffer.count < length {
                    switch fill(until: deadline) {
                    case .success(true): continue
                    case .success(false): return .failure(Failure("the reply was cut short"))
                    case .failure(.timedOut): return .failure(Failure("the reply stopped arriving"))
                    case .failure(.failed(let detail)): return .failure(Failure(detail))
                    }
                }
                let body = Data(buffer.prefix(length))
                buffer = Data(buffer.dropFirst(length))
                return .success(body)
            }
            // Close-delimited.
            while !eof {
                switch fill(until: deadline) {
                case .success: continue
                case .failure(.timedOut): return .failure(Failure("the reply stopped arriving"))
                case .failure(.failed(let detail)): return .failure(Failure(detail))
                }
            }
            defer { buffer = Data() }
            return .success(buffer)
        }

        /// A whole reply, waiting `timeoutSeconds` (SO_RCVTIMEO) at most for
        /// each read.
        mutating func response(timeoutSeconds: Int) -> Result<Response, Failure> {
            switch head(until: nil) {
            case .failure(let failure):
                return .failure(
                    failure.detail == "no reply came in time"
                        ? Failure("no reply came within \(timeoutSeconds) s") : failure)
            case .success(var response):
                switch body(of: response, until: nil) {
                case .failure(let failure): return .failure(failure)
                case .success(let data):
                    response.body = data
                    if response.contentLength == nil { response.closes = true }
                    return .success(response)
                }
            }
        }

        mutating func frame(until deadline: ContinuousClock.Instant) -> Frame {
            if chunked { return chunkedFrame(until: deadline) }
            while buffer.count < 5 || buffer.count < 5 + Self.frameLength(buffer) {
                switch fill(until: deadline) {
                case .success(true): continue
                case .success(false): return buffer.isEmpty ? .closed : .failed("the stream was cut short")
                case .failure(.timedOut): return .timedOut
                case .failure(.failed(let detail)): return .failed(detail)
                }
            }
            return Self.takeFrame(&buffer)
        }

        /// The next envelope from a chunked body.
        private mutating func chunkedFrame(until deadline: ContinuousClock.Instant) -> Frame {
            while decoded.count < 5 || decoded.count < 5 + Self.frameLength(decoded) {
                guard !lastChunkSeen else { return decoded.isEmpty ? .closed : .failed("the stream was cut short") }
                switch nextChunk(until: deadline) {
                case .success: continue
                case .failure(.timedOut): return .timedOut
                case .failure(.failed(let detail)): return .failed(detail)
                }
            }
            return Self.takeFrame(&decoded)
        }

        /// Reads one chunk into `decoded` (or the last chunk).
        private mutating func nextChunk(until deadline: ContinuousClock.Instant) -> Result<Void, ReadError> {
            let crlf = Data("\r\n".utf8)
            while buffer.range(of: crlf) == nil {
                switch fill(until: deadline) {
                case .success(true): continue
                case .success(false): return .failure(.failed("the stream was cut short"))
                case .failure(let error): return .failure(error)
                }
            }
            guard let line = buffer.range(of: crlf),
                let size = Int(
                    String(decoding: buffer[buffer.startIndex..<line.lowerBound], as: UTF8.self)
                        .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "",
                    radix: 16), size >= 0
            else { return .failure(.failed("the stream's chunk framing was malformed")) }
            let start = line.upperBound - buffer.startIndex
            while buffer.count < start + size + 2 {
                switch fill(until: deadline) {
                case .success(true): continue
                case .success(false): return .failure(.failed("the stream was cut short"))
                case .failure(let error): return .failure(error)
                }
            }
            if size == 0 {
                // The last chunk, then the end of the (empty) trailer section.
                lastChunkSeen = true
                buffer = Data(buffer.dropFirst(start + 2))
                return .success(())
            }
            decoded.append(buffer[(buffer.startIndex + start)..<(buffer.startIndex + start + size)])
            buffer = Data(buffer.dropFirst(start + size + 2))
            return .success(())
        }

        /// After the end-of-stream frame: reads up to the last chunk. True
        /// when the body ended cleanly and nothing else is buffered.
        mutating func finishBody(until deadline: ContinuousClock.Instant) -> Bool {
            while !lastChunkSeen {
                guard case .success = nextChunk(until: deadline) else { return false }
            }
            return decoded.isEmpty
        }

        private static func frameLength(_ data: Data) -> Int {
            guard data.count >= 5 else { return 0 }
            let s = data.startIndex
            return Int(data[s + 1]) << 24 | Int(data[s + 2]) << 16 | Int(data[s + 3]) << 8 | Int(data[s + 4])
        }

        private static func takeFrame(_ data: inout Data) -> Frame {
            let flags = data[data.startIndex]
            let length = frameLength(data)
            let payload = Data(data[(data.startIndex + 5)..<(data.startIndex + 5 + length)])
            data = Data(data.dropFirst(5 + length))
            return .frame(flags: flags, payload: payload)
        }
    }

    struct Failure: Error {
        let detail: String
        init(_ detail: String) { self.detail = detail }
    }
}
