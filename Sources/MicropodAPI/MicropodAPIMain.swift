import Darwin
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

        let port = UInt16(ProcessInfo.processInfo.environment["MICROPOD_API_PORT"] ?? "45454") ?? 45454

        let isolated = ProcessInfo.processInfo.environment["MICROPOD_ISOLATED_RUNTIME"] == "1"
        let identity: IsolatedRuntimeIdentity?
        let client: ContainerCLIClient
        do {
            if isolated {
                let account = try IsolatedRuntimeIdentity.readRootOwned()
                let configuration = try IsolatedRuntimeAPIConfiguration.read(identity: account)
                guard getuid() == account.serviceUID, geteuid() == account.serviceUID,
                    getgid() == account.serviceGID,
                    try await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl")).run(
                        .init(arguments: ["managername"]), timeout: .seconds(5)
                    ).trimmingCharacters(in: .whitespacesAndNewlines) == "Background",
                    UInt32(
                        try await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl")).run(
                            .init(arguments: ["manageruid"]), timeout: .seconds(5)
                        ).trimmingCharacters(in: .whitespacesAndNewlines)) == account.serviceUID
                else { throw MicropodError.message("The managed API is outside its dedicated service namespace") }
                let root = IsolatedRuntimePolicy.root.appendingPathComponent(
                    "apple/versions/" + configuration.selection.directoryName)
                try await ManagedRuntimeInstaller(root: IsolatedRuntimePolicy.root.appendingPathComponent("apple"))
                    .verify(
                        .init(
                            selection: configuration.selection,
                            files: AppleRuntimeRelease.payload(for: configuration.selection) ?? [:]))
                identity = account
                client = ContainerCLIClient(executableURL: root.appendingPathComponent("bin/container"))
            } else {
                identity = nil
                // Every `container` command this server runs first asks
                // whether Apple's runtime is known to be down (one XPC ping,
                // kept for 2 s): a down runtime costs no child per request.
                let appleLiveness = AppleRuntimeLiveness()
                appleLiveness.start()
                client = ContainerCLIClient().gated(by: appleLiveness)
            }
        } catch {
            fputs("Managed API identity verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
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
            if let identity {
                let gateway = IsolatedRuntimeGateway(identity: identity)
                try await server.startPrivateSocket()
                try gateway.start()
                // launchd owns this service; the GUI and root helper may exit.
                // Parked like the owner path below: a continuation that is
                // never resumed is reported as leaked.
                while true {
                    try await Task.sleep(for: .seconds(86_400))
                    withExtendedLifetime(gateway) {}
                }
            }
            let unixSockEnv = ProcessInfo.processInfo.environment["MICROPOD_API_SOCK"]
            let unixSockPath: String? =
                unixSockEnv == "off"
                ? nil
                : (unixSockEnv?.isEmpty == false
                    ? (unixSockEnv! as NSString).expandingTildeInPath
                    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".micropod/api.sock").path)
            // Only a socket that is actually serving is advertised.
            var ownerSocket: String?
            if let unixSockPath { ownerSocket = await startOwnerSocket(server, path: unixSockPath) }
            try server.startListening()
            print(
                "Micropod API listening on http://127.0.0.1:\(port), http://[::1]:\(port)"
                    + (ownerSocket.map { ", unix://\($0)" } ?? "")
                    + " (cli: \(client.executableURL.path), backend: \(runtime.kind.rawValue))"
            )
            fflush(stdout)
            // Serve until killed. A continuation that is never resumed would
            // park this task too, but the runtime reports it as leaked.
            while true { try await Task.sleep(for: .seconds(86_400)) }
        } catch {
            fputs("API failed to start: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Serves the owner's private socket (`~/.micropod/api.sock`, or
    /// `MICROPOD_API_SOCK`), creating its directory 0700 when it does not
    /// exist yet. A socket that cannot be bound is logged as the failure it
    /// is and not served or advertised (nil); the loopback TCP API starts
    /// regardless, so clients fall back to it.
    static func startOwnerSocket(
        _ server: HTTPServer, path: String, log: (String) -> Void = { fputs($0 + "\n", stderr) }
    ) async -> String? {
        do {
            try HTTPServer.createPrivateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
            try await server.startPrivateSocket(path: path, admission: .ownerOnly, keepAlive: true)
            return path
        } catch {
            log("API private socket unix://\(path) failed, not serving it: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - HTTP plumbing

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"
}

struct HTTPRequest: Sendable {
    let method: HTTPMethod
    let path: String
    let query: [String: String]
    let body: Data
    /// Request headers, lowercased keys.
    let headers: [String: String]

    func string(_ key: String) -> String { query[key] ?? "" }
}

enum HTTPResponse {
    /// A complete upstream HTTP response, including duplex upgrades.
    case relay(@Sendable (NWConnection) async -> Void)
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

/// The API's HTTP/1.1 server on Network.framework.
///
/// Connections persist (RFC 9112 §9.3) on the loopback TCP listener and the
/// owner's socket: after a reply framed by Content-Length the connection
/// reads the next request, including one already pipelined behind it. A
/// reply closes it instead (`Connection: close`) when the request asked to
/// close, is HTTP/1.0 without `keep-alive`, or was refused before a handler
/// (bad framing, the request guard, admission); when the listener serves one
/// request per connection (the managed runtime's internal socket); when the
/// server already keeps `ConnectionPolicy.maxKeptConnections`; or once it is
/// stopping. Streams, the vsock bridge and relays are delimited by the close
/// that ends them, as before — except a stream whose request asks for
/// chunked framing (`X-Micropod-Stream-Framing: chunked`, see
/// `HTTPStreamFraming`) on a connection that may persist: its body is sent
/// in chunks, ends with the zero-length chunk, and the connection then serves
/// the next request. See `ConnectionPolicy` for the timeouts.
final class HTTPServer: @unchecked Sendable {
    let port: UInt16
    let handler: (HTTPRequest) async -> HTTPResponse
    let policy: ConnectionPolicy
    private let kept: KeptConnections

    init(
        port: UInt16, policy: ConnectionPolicy = .live, handler: @escaping (HTTPRequest) async -> HTTPResponse
    ) {
        self.port = port
        self.handler = handler
        self.policy = policy
        self.kept = KeptConnections(limit: policy.maxKeptConnections)
    }

    /// Connections the server currently keeps for another request.
    var keptConnections: Int { kept.count }

    /// Loopback addresses the API listens on: IPv4 and IPv6, so
    /// `http://localhost:45454` works whichever family the client's resolver
    /// tries first (docs, SDK examples and the explorer use `localhost`).
    static let loopbackAddresses = ["127.0.0.1", "::1"]

    /// Who reaches a listener, and so whether `LocalRequestGuard` runs
    /// before a handler.
    enum Admission: Sendable, Equatable {
        /// Loopback TCP, which any local process and any browser page can
        /// reach; and the managed runtime's internal socket, whose gateway
        /// relays other callers' requests: the Host, Content-Type and
        /// Origin checks apply.
        case guarded
        /// The owner's private socket: 0600, verified to be this user's,
        /// unreachable from a browser, and with no TCP port to name in
        /// Host. The one listener the guard does not run on.
        case ownerOnly
    }

    /// `startListening`, then serves until the process ends.
    func run() async throws {
        try startListening()
        try await Task.sleep(for: .seconds(3600 * 24 * 365))
    }

    /// Starts the loopback TCP listeners and returns. `keepAlive`: serve
    /// more than one request per connection (see the type's comment).
    func startListening(keepAlive: Bool = true) throws {
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
                self.startReading(connection, keepAlive: keepAlive)
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
    }

    /// Creates `directory` (and any missing parents) 0700 whatever the
    /// umask. One that already exists keeps its mode.
    static func createPrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Serves `path`, a Unix socket only this user may open (0600, and
    /// checked to be this user's socket once bound). By default it is the
    /// managed runtime's internal socket, whose requests stay `guarded`.
    /// Throws, serving nothing, when the socket cannot be bound or protected,
    /// or when another live process serves `path`: only a stale socket file
    /// is replaced, so a second API (a test, a scratch server) never takes
    /// the path from the one already running there.
    ///
    /// `keepAlive` is off by default, for the internal socket: its gateway
    /// (`IsolatedRuntimeGateway`) checks the caller's capability on a
    /// connection's first request head only, strips it, and then relays
    /// bytes. A second request on that connection would arrive unchecked,
    /// so this listener must answer one request per connection and close.
    func startPrivateSocket(
        path: String = IsolatedRuntimeAPIConfiguration.internalSocketURL.path, admission: Admission = .guarded,
        keepAlive: Bool = false
    ) async throws {
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else {
                throw MicropodError.message("The private API socket has another owner")
            }
            try Self.refuseLiveSocket(path)
            guard unlink(path) == 0 else {
                throw MicropodError.message("Could not replace the private API socket")
            }
        } else if errno != ENOENT {
            throw MicropodError.message("Could not inspect the private API socket")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: .global(qos: .userInitiated))
            self.startReading(connection, admission: admission, keepAlive: keepAlive)
        }
        listeners.append(listener)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = PrivateListenerStart(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if chmod(path, 0o600) == 0, Self.isOwnPrivateSocket(path) {
                            once.finish(.success(()))
                        } else {
                            once.finish(.failure(MicropodError.message("Could not protect the private API socket")))
                        }
                    case .failed(let error): once.finish(.failure(error))
                    case .cancelled: once.finish(.failure(MicropodError.message("Private API listener was cancelled")))
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    once.finish(.failure(MicropodError.message("Private API listener readiness timed out")))
                }
            }
        } catch {
            // Never leave a listener behind that may still come up unannounced.
            listener.cancel()
            listeners.removeAll { $0 === listener }
            throw error
        }
    }

    /// Throws when a live process accepts connections on `path`: replacing
    /// its socket file would leave that server running unreachable.
    static func refuseLiveSocket(_ path: String) throws {
        guard let pid = RuntimeUnixSocket.listeningPeerPID(path) else { return }
        let owner = pid > 0 ? "pid \(pid)" : "another process"
        throw MicropodError.message(
            "failedPrecondition: \(owner) is serving unix://\(path); refusing to replace its socket "
                + "(set MICROPOD_API_SOCK to another path, or to off)")
    }

    /// A socket of this user's that nobody else may open.
    static func isOwnPrivateSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0
    }

    private final class PrivateListenerStart: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            let pending = lock.withLock {
                let value = continuation
                continuation = nil
                return value
            }
            pending?.resume(with: result)
        }
    }

    private var listeners: [NWListener] = []

    /// Stops listening and closes the connections kept idle; one with a
    /// request in flight is answered and then closed.
    func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        for connection in kept.stop() { connection.cancel() }
    }

    /// One accepted connection and what its listener allows.
    private struct Peer: @unchecked Sendable {
        let connection: NWConnection
        let admission: Admission
        /// The listener serves more than one request per connection.
        let keepAlive: Bool
    }

    /// The read state of one request: its watchdogs and the receive loop
    /// race to finish it; whichever wins first decides.
    private final class PendingRead: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var generation = 0
        /// Waiting for the first byte of a request on a kept connection.
        private var idle: Bool

        init(idle: Bool = false) { self.idle = idle }

        enum Arrival { case finished, began, continuing }

        /// Bytes arrived: `.began` when they are the first of a request on a
        /// kept connection, `.finished` when a watchdog settled it first.
        func arrive() -> Arrival {
            lock.withLock {
                if finished { return .finished }
                if idle {
                    idle = false
                    return .began
                }
                return .continuing
            }
        }

        /// Marks the read finished; false if it already was.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }

        /// The keep-alive watchdog: finishes the read only while no byte of
        /// a request has arrived.
        func finishIdle() -> Bool {
            lock.withLock {
                guard !finished, idle else { return false }
                finished = true
                return true
            }
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

    private func startReading(_ connection: NWConnection, admission: Admission = .guarded, keepAlive: Bool) {
        let peer = Peer(connection: connection, admission: admission, keepAlive: keepAlive)
        let pending = PendingRead()
        armRequestTimers(peer, pending: pending)
        readRequest(peer, buffer: Data(), pending: pending)
    }

    /// After a reply that kept the connection: the request already buffered
    /// behind it (pipelined) is served at once; otherwise the connection
    /// waits idle for the next one.
    private func readNext(_ peer: Peer, leftover: Data) {
        guard leftover.isEmpty else {
            kept.release(peer.connection)
            let pending = PendingRead()
            armRequestTimers(peer, pending: pending)
            if handleBuffered(peer, leftover, pending: pending) { return }
            readRequest(peer, buffer: leftover, pending: pending)
            return
        }
        guard kept.park(peer.connection) else {
            peer.connection.cancel()
            return
        }
        let pending = PendingRead(idle: true)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + policy.keepAliveIdle) {
            [weak self] in
            // No byte of another request came: close without a reply.
            guard pending.finishIdle() else { return }
            self?.kept.release(peer.connection)
            peer.connection.cancel()
        }
        readRequest(peer, buffer: Data(), pending: pending)
    }

    /// The request's deadline and its first silence window.
    private func armRequestTimers(_ peer: Peer, pending: PendingRead) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + policy.requestDeadline) {
            [weak self] in
            guard pending.finish() else { return }
            self?.reject(peer.connection, status: 408, reason: "request not received in time")
        }
        armIdleTimer(peer.connection, pending: pending)
    }

    private func armIdleTimer(_ connection: NWConnection, pending: PendingRead) {
        let token = pending.touch()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + policy.requestIdle) {
            [weak self] in
            guard pending.isCurrent(token), pending.finish() else { return }
            self?.reject(connection, status: 408, reason: "request incomplete: client went idle")
        }
    }

    private func readRequest(_ peer: Peer, buffer: Data, pending: PendingRead) {
        let connection = peer.connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            self.received(
                peer, buffer: buffer, data: data, isComplete: isComplete, failed: error != nil, pending: pending)
        }
    }

    /// One receive's worth of a request: bytes to parse, or the peer gone.
    private func received(
        _ peer: Peer, buffer: Data, data: Data?, isComplete: Bool, failed: Bool, pending: PendingRead
    ) {
        let connection = peer.connection
        var newBuffer = buffer
        if let data, !data.isEmpty {
            switch pending.arrive() {
            case .finished:
                // A watchdog settled this read first (408, or an idle close).
                return
            case .began:
                // The next request on a kept connection: no longer idle,
                // and its own clocks start at this first byte.
                kept.release(connection)
                armRequestTimers(peer, pending: pending)
            case .continuing:
                armIdleTimer(connection, pending: pending)
            }
            newBuffer.append(data)
            if handleBuffered(peer, newBuffer, pending: pending) { return }
        }
        if isComplete || failed || data == nil || data?.isEmpty == true {
            // Peer closed (or the read failed) before a full request
            // arrived: say so if we can, then close. A kept connection
            // the client closed while idle just closes.
            guard pending.finish() else { return }
            kept.release(connection)
            if !newBuffer.isEmpty && !failed {
                reject(connection, status: 400, reason: "request truncated")
            } else {
                connection.cancel()
            }
            return
        }
        readRequest(peer, buffer: newBuffer, pending: pending)
    }

    /// Parses what has arrived of the current request: true once it is
    /// settled (handed to `dispatch`, or refused and closing), false to read
    /// more. Bytes after the request are the next one's, kept for it.
    private func handleBuffered(_ peer: Peer, _ buffer: Data, pending: PendingRead) -> Bool {
        switch HTTPParser.parse(buffer) {
        case .incomplete:
            return false
        case .reject(let status, let reason):
            guard pending.finish() else { return true }
            reject(peer.connection, status: status, reason: reason)
            return true
        case .request(let request, let persistence, let consumed):
            guard pending.finish() else { return true }
            let leftover =
                consumed < buffer.count
                ? buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: consumed)..<buffer.endIndex) : Data()
            dispatch(request, peer: peer, persistence: persistence, leftover: leftover)
            return true
        }
    }

    /// Answers a request that never reached a handler and closes.
    private func reject(_ connection: NWConnection, status: Int, reason: String) {
        connection.send(
            content: HTTPRequestFraming.errorResponse(status: status, reason: reason),
            completion: .contentProcessed { _ in connection.cancel() })
    }

    private func dispatch(
        _ request: HTTPRequest, peer: Peer, persistence: HTTPPersistence, leftover: Data
    ) {
        let connection = peer.connection
        let admission = peer.admission
        // Browser-facing CORS/PNA headers — computed once per request so
        // normal, streaming, and preflight responses are all covered.
        let cors = CORSPolicy.responseHeaders(for: request)
        // Cross-site / DNS-rebinding defence, before any handler runs (see
        // LocalRequestGuard): loopback Host, a non-simple Content-Type on
        // mutations, and an allowlisted Origin when one is sent. Only the
        // owner's private socket skips it (see `Admission`).
        if admission == .guarded {
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
        }
        Task {
            let claim: RuntimeAdmissionClaim?
            do {
                claim =
                    ProcessInfo.processInfo.environment["MICROPOD_ISOLATED_RUNTIME"] == "1"
                        && !["/health", "/v1/managed/maintenance"].contains(request.path)
                    ? try RuntimeAdmission.shared.claim("managed-api:" + request.path) : nil
            } catch {
                connection.send(
                    content: Self.serialize(
                        .json(
                            503,
                            ["code": "unavailable", "message": "Runtime maintenance has closed workload admission"])),
                    completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let response = await handler(request)
            switch response {
            case .relay(let forward):
                await forward(connection)
                try? claim?.completed()
                withExtendedLifetime(claim) {}
            case .bridge(let status, let attach):
                let head = Self.streamHead(
                    status: status, contentType: "application/octet-stream",
                    extraHeaders: cors)
                connection.send(
                    content: head,
                    completion: .contentProcessed { _ in
                        Task {
                            await attach(connection)
                            try? claim?.completed()
                            withExtendedLifetime(claim) {}
                        }
                    })
            case .stream(let status, let contentType, let events)
            where peer.keepAlive && persistence != .close && leftover.isEmpty
                && HTTPStreamFraming.wantsChunks(request.headers) && kept.reserve(connection):
                streamChunked(
                    status: status, contentType: contentType, events: events, cors: cors, peer: peer
                ) {
                    try? claim?.completed()
                    withExtendedLifetime(claim) {}
                }
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
                        let pump = Task {
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
                                // The stream ends here as it would at its last
                                // frame: a vanished reader must not strand the
                                // admission receipt.
                                guard delivered else {
                                    try? claim?.completed()
                                    withExtendedLifetime(claim) {}
                                    connection.cancel()
                                    return
                                }
                            }
                            try? claim?.completed()
                            withExtendedLifetime(claim) {}
                            // Half-close so the peer sees EOF only after every
                            // frame was processed.
                            connection.send(
                                content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                        }
                        // A failed send only reveals a vanished peer when
                        // there is something to send; a quiet stream (an idle
                        // container's logs) would never notice. The request
                        // body is already consumed, so any read completing —
                        // EOF or error — means the client hung up: cancel the
                        // pump, which drops the iterator and ends the source.
                        Self.watchForHangup(connection) { pump.cancel() }
                    })
            default:
                // The handler has settled; delivery failure cannot replay it.
                try? claim?.completed()
                withExtendedLifetime(claim) {}
                self.reply(response, cors: cors, peer: peer, persistence: persistence, leftover: leftover)
            }
        }
    }

    /// A stream on a connection that persists, for a client that asked for
    /// chunked framing: the head says `Transfer-Encoding: chunked`, every
    /// event goes out as one chunk (each send awaited, as for a closing
    /// stream), the zero-length chunk ends the body, and the connection then
    /// waits for the next request as after any kept reply. The client
    /// closing its side, or failing a send, stops the stream and the
    /// connection. A client that sends anything before the stream ended
    /// (this server does not pipeline behind a stream) has the connection
    /// closed after it. `finished` runs once the source is done or abandoned.
    private func streamChunked(
        status: Int, contentType: String, events: AsyncStream<Data>, cors: [(String, String)], peer: Peer,
        finished: @escaping @Sendable () -> Void
    ) {
        let connection = peer.connection
        let head = Self.streamHead(
            status: status, contentType: contentType,
            extraHeaders: cors + [("Transfer-Encoding", "chunked"), (HTTPStreamFraming.header, "chunked")],
            closing: false)
        let watch = StreamWatch()
        connection.send(
            content: head,
            completion: .contentProcessed { [weak self] _ in
                let pump = Task {
                    func send(_ bytes: Data) async -> Bool {
                        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                            connection.send(
                                content: bytes, completion: .contentProcessed { c.resume(returning: $0 == nil) })
                        }
                    }
                    for await chunk in events where !chunk.isEmpty {
                        guard await send(HTTPStreamFraming.chunk(chunk)) else { break }
                    }
                    finished()
                    guard !Task.isCancelled, await send(HTTPStreamFraming.lastChunk), let self else {
                        self?.kept.release(connection)
                        connection.cancel()
                        return
                    }
                    self.resumeAfterStream(peer, watch: watch)
                }
                Self.watchStream(connection, watch: watch) { pump.cancel() }
            })
    }

    /// The chunked stream ended: wait for the next request, as `readNext`
    /// does on an empty buffer. Its first bytes arrive through the receive
    /// the stream's watch already has outstanding.
    private func resumeAfterStream(_ peer: Peer, watch: StreamWatch) {
        guard kept.park(peer.connection) else {
            peer.connection.cancel()
            return
        }
        let pending = PendingRead(idle: true)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + policy.keepAliveIdle) {
            [weak self] in
            guard pending.finishIdle() else { return }
            self?.kept.release(peer.connection)
            peer.connection.cancel()
        }
        let resumed = watch.end { [weak self] data, isComplete, failed in
            guard let self else {
                peer.connection.cancel()
                return
            }
            self.received(peer, buffer: Data(), data: data, isComplete: isComplete, failed: failed, pending: pending)
        }
        if !resumed {
            // The client sent before the stream ended, or already closed.
            guard pending.finish() else { return }
            kept.release(peer.connection)
            peer.connection.cancel()
        }
    }

    /// While a chunked stream runs, its connection's one reader: the client
    /// closing stops the stream. After the stream ended the bytes go to the
    /// next request (`StreamWatch.end`).
    static func watchStream(_ connection: NWConnection, watch: StreamWatch, onHangup: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            switch watch.received(data, closed: isComplete || error != nil, failed: error != nil) {
            case .hangUp: onHangup()
            case .handedOff: break
            case .watch: watchStream(connection, watch: watch, onHangup: onHangup)
            }
        }
    }

    /// Writes a reply framed by Content-Length, then serves the
    /// connection's next request when the listener, the request and the
    /// server's bound all allow it; otherwise says `Connection: close` and
    /// closes once the reply is out.
    private func reply(
        _ response: HTTPResponse, cors: [(String, String)], peer: Peer, persistence: HTTPPersistence,
        leftover: Data
    ) {
        let connection = peer.connection
        let keep = peer.keepAlive && persistence != .close && kept.reserve(connection)
        var headers = cors
        if keep && persistence == .announced { headers.append(("Connection", "keep-alive")) }
        let data = Self.serialize(response, extraHeaders: headers, closing: !keep)
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard keep, error == nil, let self else {
                    if keep { self?.kept.release(connection) }
                    connection.cancel()
                    return
                }
                self.readNext(peer, leftover: leftover)
            })
    }

    /// Calls `onHangup` once the peer closes its side or the connection
    /// fails. Stray bytes after the request (none are expected) are read
    /// and ignored.
    static func watchForHangup(_ connection: NWConnection, onHangup: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
            if isComplete || error != nil {
                onHangup()
            } else {
                watchForHangup(connection, onHangup: onHangup)
            }
        }
    }

    static func streamHead(
        status: Int, contentType: String, extraHeaders: [(String, String)] = [], closing: Bool = true
    ) -> Data {
        // A closing stream's status line keeps the bytes it has always had
        // (the reason phrase repeats the version and code; clients read only
        // the code). A chunked stream is new and says it plainly.
        var head = closing ? "HTTP/1.1 \(status) \(reasonLine(for: status))\r\n" : "\(reasonLine(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for (key, value) in extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "Cache-Control: no-cache\r\n"
        head += closing ? "Connection: close\r\n\r\n" : "\r\n"
        return Data(head.utf8)
    }

    /// A framed reply. `closing`: it ends the connection, and says so with
    /// `Connection: close`; otherwise the client may send another request.
    static func serialize(
        _ response: HTTPResponse, extraHeaders: [(String, String)] = [], closing: Bool = true
    ) -> Data {
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
        case .stream, .bridge, .relay:
            // Streams/bridges are written via streamHead + live chunks;
            // this path is unreachable for well-formed responses.
            return Data()
        }
        headers.append(contentsOf: extraHeaders)
        headers.append(("X-Micropod-Codecs", "json,proto"))

        var head = "\(statusLine)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        if closing { head += "Connection: close\r\n" }
        head += "\r\n"
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
        /// `consumed`: the bytes of the buffer this request occupied;
        /// anything after them belongs to the next (pipelined) request.
        case request(HTTPRequest, persistence: HTTPPersistence, consumed: Int)
        /// Answer with `status` and close.
        case reject(status: Int, reason: String)
    }

    static func parse(_ data: Data, limits: HTTPRequestFraming.Limits = .api) -> Outcome {
        switch HTTPRequestFraming.parse(data, limits: limits) {
        case .incomplete:
            return .incomplete
        case .invalid(let status, let reason):
            return .reject(status: status, reason: reason)
        case .complete(let head, let body, let consumed):
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
                HTTPRequest(method: method, path: path, query: query, body: body, headers: head.headers),
                persistence: HTTPPersistence(
                    version: head.version,
                    // Every Connection field counts, not just the last.
                    connection: head.fields.filter { $0.name.lowercased() == "connection" }.map(\.value)
                        .joined(separator: ",")),
                consumed: consumed)
        }
    }
}
