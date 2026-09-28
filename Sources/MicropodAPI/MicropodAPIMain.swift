import Foundation
import MicropodCore
import MicropodRuntime
import Network

// MicropodAPI — a local HTTP/1.1 JSON API over the same service layer the
// desktop app and MCP server use. Docker-shaped routes where it makes sense:
//
//   GET  /health
//   GET  /v1/system                      status + disk usage
//   GET  /v1/containers                  list containers
//   POST /v1/containers                  run a container
//   POST /v1/containers/create           create without starting
//   POST /v1/containers/:id/{start,stop,restart,kill}
//   DELETE /v1/containers/:id
//   GET  /v1/containers/:id/logs?tail=N  SSE stream
//   GET  /v1/images                      list images
//   POST /v1/images/pull                 {reference}
//   DELETE /v1/images/:ref
//   GET  /v1/volumes                     list volumes
//   POST /v1/volumes                     create {name,size}
//   DELETE /v1/volumes/:name
//   GET  /v1/networks                    list networks
//   POST /v1/networks                    create {name,internal,subnet}
//   DELETE /v1/networks/:name
//   GET  /v1/stats                       latest resource snapshot
//   POST /v1/compose/up                  {path,profiles}
//   POST /v1/compose/down                {name}
//   POST /v1/exec                        {id,command,workdir,env}
//   POST /v1/system/update               trigger a background app update check (Sparkle)
//   GET  /v1/system/update               last-known updater status
//
// Environment: MICROPOD_API_PORT (default 45454), MICROPOD_CONTAINER_CLI_PATH.

@main
struct MicropodAPI {
    static func main() async {
        // When spawned by the app, die with it — no orphaned apiserver.
        ParentDeathWatch.install()

        let cliPath =
            ProcessInfo.processInfo.environment["MICROPOD_CONTAINER_CLI_PATH"]
            ?? "/usr/local/bin/container"
        let port = UInt16(ProcessInfo.processInfo.environment["MICROPOD_API_PORT"] ?? "45454") ?? 45454

        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: cliPath))
        let runtime = await RuntimeBackendResolver.resolve(client: client)
        // Started before the runtime (or against an unverified apiserver):
        // re-resolve lazily and swap to native once it answers. The request
        // path never waits on more than a short ping for that.
        let holder = RuntimeHolder(
            initial: runtime,
            resolve: { await RuntimeBackendResolver.resolve(client: client, pingTimeout: .seconds(2)) })
        let api = APIHandlers(
            client: client,
            system: SystemService(client: client),
            images: ImageService(client: client),
            networks: NetworkService(client: client),
            compose: ComposeService(client: client),
            runtime: holder)

        let server = HTTPServer(port: port, handler: api.handle)
        do {
            try await server.run()
            print(
                "Micropod API listening on http://127.0.0.1:\(port) and http://[::1]:\(port) (cli: \(cliPath), backend: \(runtime.kind.rawValue))"
            )
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        } catch {
            fputs("API failed to start: \(error)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - HTTP plumbing

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case options = "OPTIONS"
}

struct HTTPRequest {
    let method: HTTPMethod
    let path: String
    let query: [String: String]
    let body: Data
    /// Request headers, lowercased keys.
    let headers: [String: String]

    func string(_ key: String) -> String { query[key] ?? "" }
}

enum HTTPResponse {
    case json(Int, [String: Any])
    case text(Int, String)
    /// Raw body + content type — for byte-exact payloads like proto-JSON
    /// encodings and Connect error objects.
    case data(Int, String, Data)
    case stream(Int, String, AsyncStream<Data>)
    /// Raw duplex take-over: the head is written, then the closure owns the
    /// connection until it returns (used by the guest vsock bridge).
    case bridge(Int, @Sendable (NWConnection) async -> Void)
}

final class HTTPServer: @unchecked Sendable {
    let port: UInt16
    let handler: (HTTPRequest) async -> HTTPResponse

    init(port: UInt16, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    /// Loopback addresses the API listens on: IPv4 and IPv6, so
    /// `http://localhost:45454` works whichever family the client's resolver
    /// tries first (docs, SDK examples and the explorer use `localhost`).
    static let loopbackAddresses = ["127.0.0.1", "::1"]

    func run() async throws {
        // Loopback only: the API is unauthenticated and can launch privileged
        // workloads, so it must never be reachable from the network.
        // (`NWListener(using:on:)` alone binds every interface.)
        for address in Self.loopbackAddresses {
            let parameters = NWParameters.tcp
            // Network.framework reserves a port per process across
            // addresses: without this the second (::1) listener fails
            // EADDRINUSE. Probed: another process still cannot bind either
            // address (with or without SO_REUSEADDR/SO_REUSEPORT), so this
            // opens no port-sharing hole.
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .global(qos: .userInitiated))
                self.startReading(connection)
            }
            listener.stateUpdateHandler = { [port] state in
                if case .failed(let error) = state {
                    // IPv6 may be disabled on the host: the IPv4 listener
                    // still serves; say so instead of failing silently.
                    fputs("API listener \(address):\(port) failed: \(error)\n", stderr)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            listeners.append(listener)
        }
        // Serve until killed.
        try await Task.sleep(for: .seconds(3600 * 24 * 365))
    }

    private var listeners: [NWListener] = []

    /// A request must make progress: the head and body have to finish
    /// arriving within `requestDeadline`, with no silence longer than
    /// `idleTimeout` in between. A stuck or malicious client gets 408
    /// instead of holding the connection forever. Overridable (milliseconds)
    /// via `MICROPOD_API_READ_IDLE_TIMEOUT_MS` / `MICROPOD_API_READ_DEADLINE_MS`
    /// so tests need not wait 30 s.
    static let idleTimeout = timeout(env: "MICROPOD_API_READ_IDLE_TIMEOUT_MS", defaultMilliseconds: 30_000)
    static let requestDeadline = timeout(env: "MICROPOD_API_READ_DEADLINE_MS", defaultMilliseconds: 120_000)

    private static func timeout(env: String, defaultMilliseconds: Int) -> DispatchTimeInterval {
        let raw = ProcessInfo.processInfo.environment[env].flatMap { Int($0) }
        return .milliseconds(max(1, raw ?? defaultMilliseconds))
    }

    /// Per-connection read state: the watchdog and the receive loop race to
    /// finish the connection; whichever wins first decides.
    private final class PendingRead: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var generation = 0

        /// Marks the read finished; false if it already was.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }

        /// Starts a new idle window; returns its token.
        func touch() -> Int {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
            return generation
        }

        func isCurrent(_ token: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !finished && generation == token
        }
    }

    private func startReading(_ connection: NWConnection) {
        let pending = PendingRead()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) { [weak self] in
            guard pending.finish() else { return }
            self?.reject(connection, status: 408, reason: "request not received in time")
        }
        armIdleTimer(connection, pending: pending)
        readRequest(connection, buffer: Data(), pending: pending)
    }

    private func armIdleTimer(_ connection: NWConnection, pending: PendingRead) {
        let token = pending.touch()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.idleTimeout) {
            [weak self] in
            guard pending.isCurrent(token), pending.finish() else { return }
            self?.reject(connection, status: 408, reason: "request incomplete: client went idle")
        }
    }

    private func readRequest(_ connection: NWConnection, buffer: Data, pending: PendingRead) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var newBuffer = buffer
            if let data, !data.isEmpty {
                newBuffer.append(data)
                self.armIdleTimer(connection, pending: pending)
                switch HTTPParser.parse(newBuffer) {
                case .request(let request):
                    guard pending.finish() else { return }
                    self.dispatch(request, connection: connection)
                    return
                case .reject(let status, let reason):
                    guard pending.finish() else { return }
                    self.reject(connection, status: status, reason: reason)
                    return
                case .incomplete:
                    break
                }
            }
            if isComplete || error != nil || data == nil || data?.isEmpty == true {
                // Peer closed (or the read failed) before a full request
                // arrived: say so if we can, then close.
                guard pending.finish() else { return }
                if !newBuffer.isEmpty && error == nil {
                    self.reject(connection, status: 400, reason: "request truncated")
                } else {
                    connection.cancel()
                }
                return
            }
            self.readRequest(connection, buffer: newBuffer, pending: pending)
        }
    }

    /// Answers a request that never reached a handler and closes.
    private func reject(_ connection: NWConnection, status: Int, reason: String) {
        connection.send(
            content: HTTPRequestFraming.errorResponse(status: status, reason: reason),
            completion: .contentProcessed { _ in connection.cancel() })
    }

    private func dispatch(_ request: HTTPRequest, connection: NWConnection) {
        // Browser-facing CORS/PNA headers — computed once per request so
        // normal, streaming, and preflight responses are all covered.
        let cors = CORSPolicy.responseHeaders(for: request)
        // Cross-site / DNS-rebinding defence, before any handler runs (see
        // LocalRequestGuard): loopback Host, a non-simple Content-Type on
        // mutations, and an allowlisted Origin when one is sent.
        let verdict = LocalRequestGuard.evaluateAPI(
            method: request.method.rawValue, headers: request.headers, bodyLength: request.body.count,
            port: port, originAllowed: { _ in CORSPolicy.allowedOrigin(for: request) != nil })
        if case .reject(let status, let reason) = verdict {
            let code = status == 415 ? "invalid_argument" : "permission_denied"
            let body =
                (try? JSONSerialization.data(
                    withJSONObject: ["code": code, "message": reason, "error": reason])) ?? Data()
            connection.send(
                content: Self.serialize(.data(status, "application/json", body), extraHeaders: cors),
                completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        Task {
            let response = await handler(request)
            switch response {
            case .bridge(let status, let attach):
                let head = Self.streamHead(
                    status: status, contentType: "application/octet-stream",
                    extraHeaders: cors)
                connection.send(
                    content: head,
                    completion: .contentProcessed { _ in
                        Task { await attach(connection) }
                    })
            case .stream(let status, let contentType, let events):
                // SSE/connect-stream: write the head without Content-Length,
                // then stream each event on the live connection. Every send
                // is awaited: cancelling right after the last fire-and-forget
                // send drops the final frame (the Connect EndStream trailer),
                // which connect-go reports as "unexpected EOF".
                let head = Self.streamHead(
                    status: status, contentType: contentType, extraHeaders: cors)
                connection.send(
                    content: head,
                    completion: .contentProcessed { _ in
                        Task {
                            for await chunk in events {
                                let delivered = await withCheckedContinuation {
                                    (c: CheckedContinuation<Bool, Never>) in
                                    connection.send(
                                        content: chunk,
                                        completion: .contentProcessed { error in
                                            c.resume(returning: error == nil)
                                        })
                                }
                                // Peer went away: stop pulling from the source
                                // (dropping the iterator cancels the producer)
                                // instead of pumping frames into a dead socket.
                                guard delivered else {
                                    connection.cancel()
                                    return
                                }
                            }
                            // Half-close so the peer sees EOF only after every
                            // frame was processed.
                            connection.send(
                                content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                        }
                    })
            default:
                let data = Self.serialize(response, extraHeaders: cors)
                connection.send(
                    content: data,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            }
        }
    }

    static func streamHead(
        status: Int, contentType: String, extraHeaders: [(String, String)] = []
    ) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonLine(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for (key, value) in extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    static func serialize(_ response: HTTPResponse, extraHeaders: [(String, String)] = []) -> Data {
        let statusLine: String
        var headers: [(String, String)] = []
        var body: Data = Data()

        switch response {
        case .json(let status, let object):
            statusLine = reasonLine(for: status)
            headers.append(("Content-Type", "application/json"))
            body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        case .text(let status, let text):
            statusLine = reasonLine(for: status)
            headers.append(("Content-Type", "text/plain"))
            body = Data(text.utf8)
        case .data(let status, let contentType, let raw):
            statusLine = reasonLine(for: status)
            headers.append(("Content-Type", contentType))
            body = raw
        case .stream, .bridge:
            // Streams/bridges are written via streamHead + live chunks;
            // this path is unreachable for well-formed responses.
            return Data()
        }
        headers.append(contentsOf: extraHeaders)

        var head = "\(statusLine)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reasonLine(for status: Int) -> String {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 412: reason = "Precondition Failed"
        case 415: reason = "Unsupported Media Type"
        case 429: reason = "Too Many Requests"
        // Connect `canceled` (nginx convention; no IANA phrase).
        case 499: reason = "Client Closed Request"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        case 504: reason = "Gateway Timeout"
        default: reason = "Unknown"
        }
        return "HTTP/1.1 \(status) \(reason)"
    }
}

/// Request parsing for MicropodAPI: framing (binary-safe head/body split,
/// Content-Length and chunked bodies, limits) is ``HTTPRequestFraming``;
/// this maps the head onto ``HTTPRequest``.
enum HTTPParser {
    enum Outcome {
        case incomplete
        case request(HTTPRequest)
        /// Answer with `status` and close.
        case reject(status: Int, reason: String)
    }

    static func parse(_ data: Data, limits: HTTPRequestFraming.Limits = .api) -> Outcome {
        switch HTTPRequestFraming.parse(data, limits: limits) {
        case .incomplete:
            return .incomplete
        case .invalid(let status, let reason):
            return .reject(status: status, reason: reason)
        case .complete(let head, let body, _):
            guard let method = HTTPMethod(rawValue: head.method) else {
                return .reject(status: 405, reason: "method \(head.method) not allowed")
            }
            let targetParts = head.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let path = String(targetParts[0])
            var query: [String: String] = [:]
            if targetParts.count > 1 {
                for pair in targetParts[1].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard let key = kv.first else { continue }
                    query[String(key)] =
                        kv.count > 1 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
                }
            }
            return .request(
                HTTPRequest(method: method, path: path, query: query, body: body, headers: head.headers))
        }
    }
}
