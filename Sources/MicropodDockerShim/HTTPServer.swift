import Foundation
import MicropodCore
import Network

struct ShimRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func q(_ name: String) -> String { query[name] ?? "" }
    func header(_ name: String) -> String {
        headers[name.lowercased()] ?? ""
    }

    /// Docker filter params arrive as repeated `filters={"k":["v"]}` JSON.
    func filters() -> [String: [String]] {
        guard let raw = query["filters"], let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result = [String: [String]]()
        for (key, value) in object {
            if let list = value as? [String] {
                result[key] = list
            } else if let single = value as? String {
                result[key] = [single]
            } else if let map = value as? [String: Any] {
                result[key] = map.keys.sorted()
            }
        }
        return result
    }
}

/// Per-connection handle handed to handlers. Writes go straight to the
/// client socket; after a hijack the same object yields inbound client bytes.
///
/// **Nothing is written after close.** A response can outlive its client — a
/// `/wait` ends long after the docker CLI that sent it has exited — and a
/// raw fd's number is reused by the next accept(2) once it is closed, so a
/// late write would land in another client's HTTP stream (live: "Unsolicited
/// response received on idle HTTP channel", `malformed HTTP version
/// "{\"StatusCode\":0}HTTP/1.1"`). Every send runs on one serial queue and
/// checks there that the connection is still open, and the fd is released
/// only on that queue — after every send queued before the close, and only
/// once the serve thread has stopped reading it — so no send and no recv
/// can reach a number that has been handed to someone else.
final class ShimConnection: @unchecked Sendable {
    private enum Transport {
        case network(NWConnection)
        /// Raw BSD fd (unix and TCP sockets): blocking sends, and the fd's
        /// release, serialized on `io`.
        case fileDescriptor(Int32)
    }

    private let transport: Transport
    private let io: DispatchQueue
    private let lock = NSLock()
    private var mode: Mode = .http
    /// Raw fd: whether the serve thread may still recv(2) on it. The fd is
    /// not released while it may.
    private var reading: Bool
    private var released = false
    /// Run once, when the connection closes: how a long poll learns that its
    /// client has gone.
    private var closeHandlers: [@Sendable () -> Void] = []

    private enum Mode {
        case http
        case hijacking
        case closed
    }

    private var inboundContinuations: [AsyncStream<Data>.Continuation] = []
    private var continueSent = false

    /// Sends the interim 100 Continue response once per pending request when
    /// the client asked for it (Go docker SDK does, for archive PUTs).
    func sendContinueIfNeeded(_ pending: Data) async {
        guard !markContinueSent(),
            let headEnd = pending.range(of: Data("\r\n\r\n".utf8))
        else { return }
        let head = String(
            decoding: pending[pending.startIndex..<headEnd.lowerBound], as: UTF8.self)
        guard head.lowercased().contains("expect: 100-continue") else { return }
        _ = await write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
    }

    /// Flips the sent flag and returns whether it was already set.
    private func markContinueSent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = continueSent
        continueSent = true
        return previous
    }

    var isFileDescriptor: Bool {
        if case .fileDescriptor = transport { return true }
        return false
    }

    /// Serialized per-connection work: pipelined keep-alive requests must not
    /// interleave response bytes, so handlers run in dispatch order.
    private var chain: Task<Void, Never> = Task {}

    func schedule(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = chain
        chain = Task {
            await previous.value
            await work()
        }
        lock.unlock()
    }

    func resetContinueFlag() {
        lock.lock()
        continueSent = false
        lock.unlock()
    }

    var hasSentContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continueSent
    }

    init(connection: NWConnection) {
        transport = .network(connection)
        io = DispatchQueue(label: "shim-nw-write", qos: .userInitiated)
        reading = false
        admissionPort = nil
    }

    /// `readerAttached`: a serve thread reads `fd` and calls `readerDetached`
    /// when it stops; the fd is released only after that.
    init(fileDescriptor fd: Int32, readerAttached: Bool = false, admissionPort: UInt16? = nil) {
        transport = .fileDescriptor(fd)
        io = DispatchQueue(label: "shim-fd-write-\(fd)", qos: .userInitiated)
        reading = readerAttached
        self.admissionPort = admissionPort
    }

    /// Set for TCP connections: the listener port every request's Host is
    /// checked against (``LocalRequestGuard/evaluateShim(headers:port:)``).
    /// Unix-socket connections (nil) are not reachable from a browser.
    let admissionPort: UInt16?

    enum WriteStatus: Sendable { case ok, failed }

    /// Sends `data`, or refuses (`.failed`, nothing sent) once the connection
    /// is closed. A failed send closes the connection: its stream can no
    /// longer be framed, and its client is usually gone.
    func write(_ data: Data) async -> WriteStatus {
        let status: WriteStatus
        switch transport {
        case .network(let connection):
            guard !isClosed else { return .failed }
            status = await withCheckedContinuation {
                (continuation: CheckedContinuation<WriteStatus, Never>) in
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        continuation.resume(returning: error == nil ? .ok : .failed)
                    })
            }
        case .fileDescriptor(let fd):
            status = await withCheckedContinuation {
                (continuation: CheckedContinuation<WriteStatus, Never>) in
                io.async { [self] in
                    // Checked on the queue the fd is released on, so the fd
                    // is still this connection's for the whole send.
                    guard !isClosed else {
                        continuation.resume(returning: .failed)
                        return
                    }
                    var sent = 0
                    data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        while sent < raw.count {
                            let n = Darwin.send(
                                fd, base.advanced(by: sent), raw.count - sent, 0)
                            if n <= 0 { break }
                            sent += n
                        }
                    }
                    continuation.resume(returning: sent == data.count ? .ok : .failed)
                }
            }
        }
        if status == .failed { close() }
        return status
    }

    /// Whether the connection is closed: its client hung up, a send failed,
    /// or the server ended the exchange.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mode == .closed
    }

    /// Runs `handler` once the connection closes — at once if it already has.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        guard mode != .closed else {
            lock.unlock()
            handler()
            return
        }
        closeHandlers.append(handler)
        lock.unlock()
    }

    /// The serve thread has stopped reading the fd: it may now be released.
    func readerDetached() {
        lock.lock()
        reading = false
        lock.unlock()
        releaseWhenDone()
    }

    /// Closes the fd, on `io` behind every send queued so far, once the
    /// connection is closed and nothing reads it any more. Exactly once.
    private func releaseWhenDone() {
        guard case .fileDescriptor(let fd) = transport else { return }
        io.async { [self] in
            lock.lock()
            let release = mode == .closed && !reading && !released
            if release { released = true }
            lock.unlock()
            if release { _ = Darwin.close(fd) }
        }
    }

    /// Switches the connection to raw byte forwarding: every subsequent
    /// client byte is yielded on a fresh inbound stream (exec stdin).
    ///
    /// A connection that has already closed stays closed and gets a stream
    /// that has already ended. Its client can leave while a handler is still
    /// on its way here (an `/attach` resolving its container, an exec start
    /// launching its process), and by then its fd number may be the next
    /// client's: reopening it would send the 101 and the output there, and
    /// the hijack's eventual close would shut that client's socket down.
    func beginHijack() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lock.lock()
        guard mode != .closed else {
            lock.unlock()
            continuation.finish()
            return stream
        }
        mode = .hijacking
        inboundContinuations.append(continuation)
        lock.unlock()
        return stream
    }

    /// Ends the connection: later writes are refused, close handlers run,
    /// and a raw fd is shut down now and released once it is safe to (see
    /// `releaseWhenDone`).
    func close() {
        lock.lock()
        guard mode != .closed else {
            lock.unlock()
            finishInbound()
            return
        }
        mode = .closed
        let handlers = closeHandlers
        closeHandlers = []
        if case .fileDescriptor(let fd) = transport {
            // Under the lock that orders it before any release, so the fd is
            // still ours. It delivers our FIN and wakes a send blocked on a
            // client that stopped reading and the serve thread's recv.
            // ENOTCONN here (the docker CLI half-closes right after the 101)
            // is harmless.
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        lock.unlock()
        switch transport {
        case .network(let connection):
            connection.cancel()
        case .fileDescriptor:
            releaseWhenDone()
        }
        finishInbound()
        for handler in handlers { handler() }
    }

    fileprivate func forwardInbound(_ data: Data) {
        lock.lock()
        let continuations = inboundContinuations
        lock.unlock()
        for continuation in continuations {
            continuation.yield(data)
        }
    }

    func finishInbound() {
        lock.lock()
        let continuations = inboundContinuations
        inboundContinuations = []
        lock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    var isHijacking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mode == .hijacking
    }

    fileprivate var networkConnection: NWConnection? {
        if case .network(let connection) = transport { return connection }
        return nil
    }
}

enum ShimResponse {
    case status(Int)
    case json(Int, Data)
    case raw(Int, [(String, String)], Data)
    /// Headers written immediately, then each chunk verbatim (no chunked
    /// encoding) until the stream ends — used for NDJSON event/log streams.
    case stream(Int, [(String, String)], AsyncStream<Data>)
    /// 101 UPGRADED then raw bidirectional bytes (exec start, attach).
    ///
    /// The content type must describe what actually follows: dockerd sends
    /// `multiplexed-stream` when the payload is stdcopy-framed and
    /// `raw-stream` only for a TTY container's unframed bytes. Clients key
    /// their demultiplexing off it.
    case hijacked(contentType: String = ShimResponse.multiplexedStream)

    static let rawStream = "application/vnd.docker.raw-stream"
    static let multiplexedStream = "application/vnd.docker.multiplexed-stream"

    /// Status code for metrics labels (hijacked connections report 101).
    var statusCode: Int {
        switch self {
        case .status(let code): return code
        case .json(let code, _): return code
        case .raw(let code, _, _): return code
        case .stream(let code, _, _): return code
        case .hijacked: return 101
        }
    }
}

/// Minimal HTTP/1.1 server over Network.framework supporting unix-socket +
/// TCP listeners, binary Content-Length bodies, unframed live streams, and
/// protocol-switch hijacks (`POST /exec/{id}/start`).
final class ShimHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (ShimRequest, ShimConnection) async -> ShimResponse

    private let handler: Handler
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "shim-listeners", qos: .userInitiated)
    private let portLock = NSLock()
    private var boundPortStorage: UInt16?

    var boundPort: UInt16? {
        portLock.lock()
        defer { portLock.unlock() }
        return boundPortStorage
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// A bound TCP listener. `close()` stops accepting (the accept loop polls
    /// so it notices within ~250 ms); established connections are untouched.
    final class TCPListener: @unchecked Sendable {
        let host: String
        let port: UInt16
        private let lock = NSLock()
        private var closed = false

        fileprivate init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        /// The accept loop owns the fd and closes it when it sees the flag.
        func close() {
            lock.lock()
            closed = true
            lock.unlock()
        }
    }

    /// Binds `host:port` (IPv4 literal; `nil` = every interface) and serves
    /// accepted connections. TCP is reachable from browsers, so every request
    /// on it passes ``LocalRequestGuard/evaluateShim(headers:port:)`` (Host
    /// allowlist, no Origin / Sec-Fetch-*) before reaching the handler.
    /// `peerAllowed` filters by the client's IPv4 address (a vmnet gateway
    /// listener only admits guests on that network).
    @discardableResult
    func listenTCP(
        host: String?, port: UInt16, peerAllowed: (@Sendable (String) -> Bool)? = nil
    ) throws -> TCPListener {
        // BSD sockets, not Network.framework: NWConnection.cancel() is a
        // no-op on established connections (probed: state stays `ready`,
        // TCP stays ESTABLISHED), so hijacked-stream EOF never reaches the
        // client and `docker start -a` hangs forever. Accepted TCP fds flow
        // through the same thread-per-connection `serve()` path as unix
        // sockets, where close() is shutdown()+close() and EOF is reliable.
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .ENODEV)
        }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(
            fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var nodelay: Int32 = 1
        _ = Darwin.setsockopt(
            fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        if let host, !host.isEmpty {
            var addr = in_addr()
            let parsed = host.withCString { Darwin.inet_pton(AF_INET, $0, &addr) }
            guard parsed == 1 else {
                Darwin.close(fd)
                throw POSIXError(.EADDRNOTAVAIL)
            }
            address.sin_addr = addr
        } else {
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXError.Code(rawValue: code) ?? .ENODEV)
        }
        // Report the ephemeral port when port == 0 (tests).
        var resolved = sockaddr_in()
        var resolvedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.getsockname(fd, $0, &resolvedLength)
            }
        }
        let boundPort = CFSwapInt16BigToHost(resolved.sin_port)
        guard Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .ENODEV)
        }
        portLock.lock()
        boundPortStorage = boundPort
        portLock.unlock()
        let listener = TCPListener(host: host ?? "*", port: boundPort)
        fputs("[shim] tcp listening on \(host ?? "*"):\(boundPort)\n", stderr)
        let acceptThread = Thread { [weak self] in
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while !listener.isClosed {
                pollFD.revents = 0
                let ready = Darwin.poll(&pollFD, 1, 250)
                if ready < 0 && errno != EINTR { break }
                guard ready > 0 else { continue }
                var peer = sockaddr_in()
                var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(fd, $0, &peerLength)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
                    break
                }
                if let peerAllowed {
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var peerAddr = peer.sin_addr
                    _ = Darwin.inet_ntop(AF_INET, &peerAddr, &text, socklen_t(INET_ADDRSTRLEN))
                    let peerIP = String(cString: text)
                    guard peerAllowed(peerIP) else {
                        fputs("[shim] refused tcp peer \(peerIP) on \(host ?? "*"):\(boundPort)\n", stderr)
                        Darwin.close(clientFD)
                        continue
                    }
                }
                self?.serve(fileDescriptor: clientFD, admissionPort: boundPort)
            }
            Darwin.close(fd)
            fputs("[shim] tcp listener \(host ?? "*"):\(boundPort) closed\n", stderr)
        }
        acceptThread.name = "shim-tcp-accept"
        acceptThread.stackSize = 256 * 1024
        acceptThread.start()
        return listener
    }

    func listenUnix(path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .ENODEV)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .ENODEV)
        }
        guard Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .ENODEV)
        }
        let acceptThread = Thread { [weak self] in
            while true {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 { break }
                self?.serve(fileDescriptor: clientFD)
            }
        }
        acceptThread.name = "shim-unix-accept"
        acceptThread.stackSize = 256 * 1024
        acceptThread.start()
    }

    /// Thread-per-connection read loop for raw-fd (unix socket) transports.
    /// Large bodies (build contexts) are only parsed once fully received —
    /// waiting on the chunked terminator or content-length — so recv-heavy
    /// uploads stay O(N) instead of re-decoding the whole buffer per recv.
    private func serve(fileDescriptor fd: Int32, admissionPort: UInt16? = nil) {
        let connection = ShimConnection(
            fileDescriptor: fd, readerAttached: true, admissionPort: admissionPort)
        Thread.detachNewThread { [weak self] in
            // The fd is released only once this thread no longer reads it.
            defer { connection.readerDetached() }
            var buffer = Data()
            var headerDone = false
            var bodyIsChunked = false
            var bodyStart = 0
            var contentLength = 0
            var terminatorScan = 0
            var lastChunkHit = 0
            let limits = HTTPRequestFraming.Limits.dockerShim
            let chunkSize = 256 * 1024
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            // The last-chunk line; trailers (if any) follow it. The full
            // decode below confirms, so a false hit inside chunk data only
            // costs one parse.
            let lastChunk = Data("\r\n0\r\n".utf8)
            // Set when the client half-closed a hijacked stream: we stop
            // reading but must leave the connection open to keep writing.
            var clientHalfClosedHijack = false
            // Set when a malformed / stalled request was refused: the
            // scheduled refusal owns the close (after in-flight responses).
            var refused = false
            func refuse(_ status: Int, _ reason: String) {
                fputs("[shim] refusing request: \(status) \(reason)\n", stderr)
                let response = HTTPRequestFraming.errorResponse(status: status, reason: reason)
                connection.schedule {
                    _ = await connection.write(response)
                    connection.close()
                }
                refused = true
            }
            readLoop: while !connection.isClosed {
                // A partially received request must keep making progress:
                // idle keep-alive connections (empty buffer) may wait
                // forever, but a stalled half-sent request gets a 408.
                if !buffer.isEmpty && !connection.isHijacking {
                    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = Darwin.poll(&pollFD, 1, Self.partialRequestIdleTimeoutMs)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if ready == 0 {
                        if connection.isHijacking || connection.isClosed { continue }
                        refuse(408, "request incomplete: client went idle")
                        break
                    }
                }
                let received = Darwin.recv(fd, chunk, chunkSize, 0)
                if received == 0 && connection.isHijacking {
                    // FIN on a hijacked stream means the client is done
                    // *sending*, not that the exchange is over. `docker run`
                    // has no stdin to forward and half-closes right after the
                    // 101, so tearing down here destroys the outbound half
                    // that carries the container's output — it then surfaces
                    // on the client's pooled connection as "Unsolicited
                    // response received on idle HTTP channel". The attached
                    // process's writer closes the connection when it exits.
                    clientHalfClosedHijack = true
                    break
                }
                if received <= 0 { break }
                let incoming = Data(bytes: chunk, count: received)
                if connection.isHijacking {
                    connection.forwardInbound(incoming)
                    continue
                }
                buffer.append(incoming)
                // Drain EVERY complete request already buffered before
                // blocking in recv again: pipelined requests (test: three on
                // one connection) must all be scheduled, not just the first.
                // Blocking first would deadlock a client that pipelines then
                // waits (it sends nothing more until it gets responses).
                parseLoop: while !connection.isHijacking, !buffer.isEmpty {
                    if !headerDone {
                        switch HTTPRequestFraming.parseHead(buffer, limits: limits) {
                        case .incomplete:
                            break parseLoop
                        case .invalid(let status, let reason):
                            refuse(status, reason)
                            break readLoop
                        case .head(let head):
                            bodyStart = head.bodyOffset
                            switch head.bodyFraming {
                            case .chunked:
                                bodyIsChunked = true
                                contentLength = 0
                            case .length(let length):
                                bodyIsChunked = false
                                contentLength = length
                            }
                        }
                        headerDone = true
                        terminatorScan = 0
                        if !connection.hasSentContinue {
                            let pending = buffer
                            Task { await connection.sendContinueIfNeeded(pending) }
                        }
                    }
                    if bodyIsChunked {
                        if buffer.count - bodyStart > limits.maxBodyBytes + limits.maxBodyBytes / 8 {
                            refuse(413, "request body exceeds \(limits.maxBodyBytes) bytes")
                            break readLoop
                        }
                        let scanFrom = buffer.index(
                            buffer.startIndex,
                            offsetBy: min(max(bodyStart - 2, terminatorScan - lastChunk.count), buffer.count))
                        guard let hit = buffer.range(of: lastChunk, in: scanFrom..<buffer.endIndex) else {
                            terminatorScan = buffer.count
                            break parseLoop
                        }
                        lastChunkHit = buffer.distance(from: buffer.startIndex, to: hit.lowerBound)
                    } else if contentLength > 0, buffer.count < bodyStart + contentLength {
                        break parseLoop
                    }
                    let request: ShimRequest
                    switch ShimRequestParser.parseOutcome(buffer, limits: limits) {
                    case .incomplete:
                        // Chunked: the last-chunk hit was inside data, or
                        // its trailers are still arriving. A hit near the
                        // end may be the real one: rescan it next time.
                        // One further back cannot be (trailers are bounded),
                        // so skip past it — no re-parse per recv.
                        if buffer.count - lastChunkHit <= Self.maxTrailerWindow {
                            terminatorScan = lastChunkHit + lastChunk.count
                        } else {
                            terminatorScan = buffer.count
                        }
                        break parseLoop
                    case .invalid(let status, let reason):
                        refuse(status, reason)
                        break readLoop
                    case .request(let parsed, let remainder):
                        request = parsed
                        buffer = remainder
                    }
                    headerDone = false
                    terminatorScan = 0
                    connection.resetContinueFlag()
                    guard let self else { return }
                    connection.schedule {
                        await self.handle(request, connection: connection, remainder: Data())
                    }
                }
            }
            connection.finishInbound()
            if !clientHalfClosedHijack && !refused {
                connection.close()
            }
        }
    }

    /// Bytes after a last-chunk line within which its trailers must end.
    static let maxTrailerWindow = 64 * 1024 + 16

    /// How long a partially received request may sit without new bytes
    /// before the shim answers 408 and closes. Default 60 s; overridable
    /// (milliseconds) via `MICROPOD_SHIM_READ_IDLE_TIMEOUT_MS`, and settable
    /// by tests.
    static var partialRequestIdleTimeoutMs: Int32 {
        get {
            timeoutLock.lock()
            defer { timeoutLock.unlock() }
            return partialRequestIdleTimeoutStorage
        }
        set {
            timeoutLock.lock()
            partialRequestIdleTimeoutStorage = max(1, newValue)
            timeoutLock.unlock()
        }
    }
    private static let timeoutLock = NSLock()
    nonisolated(unsafe) private static var partialRequestIdleTimeoutStorage: Int32 = {
        let raw = ProcessInfo.processInfo.environment["MICROPOD_SHIM_READ_IDLE_TIMEOUT_MS"].flatMap {
            Int32($0)
        }
        return max(1, raw ?? 60_000)
    }()

    private func register(_ listener: NWListener, label: String) {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let shimConnection = ShimConnection(connection: connection)
            connection.start(queue: self.queue)
            self.readLoop(shimConnection, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                fputs("shim listener \(label) failed: \(error)\n", stderr)
            }
            if case .ready = state, let port = listener.port?.rawValue {
                self?.portLock.lock()
                self?.boundPortStorage = port
                self?.portLock.unlock()
            }
        }
        listener.start(queue: queue)
        listeners.append(listener)
    }

    func awaitForever() async {
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func readLoop(_ connection: ShimConnection, buffer: Data) {
        if connection.isHijacking {
            continueRawRead(connection)
            return
        }
        // Drain any pipelined requests buffered from earlier receives before
        // waiting for more bytes.
        var pending = buffer
        parse: while true {
            switch ShimRequestParser.parseOutcome(pending) {
            case .incomplete:
                break parse
            case .invalid(let status, let reason):
                let response = HTTPRequestFraming.errorResponse(status: status, reason: reason)
                connection.schedule {
                    _ = await connection.write(response)
                    connection.close()
                }
                return
            case .request(let request, let remainder):
                pending = remainder
                connection.resetContinueFlag()
                connection.schedule { [weak self] in
                    guard let self else { return }
                    await self.handle(request, connection: connection, remainder: Data())
                }
            }
        }
        if !connection.hasSentContinue, !pending.isEmpty {
            let snapshot = pending
            Task { await connection.sendContinueIfNeeded(snapshot) }
        }
        if pending.count > 512 * 1024 * 1024 {
            let oversized = Data("HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n".utf8)
            Task { _ = await connection.write(oversized) }
            connection.close()
            return
        }
        let buffered = pending
        connection.networkConnection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete && (data == nil || data!.isEmpty) {
                connection.finishInbound()
                // A receive armed while the connection was still in HTTP mode
                // can land *after* a handler hijacked it — the docker CLI
                // half-closes its write side immediately after the 101, and
                // this callback is what observes that EOF. Closing here kills
                // the outbound half the hijack exists to use. The hijack's own
                // writer owns the close.
                if !connection.isHijacking {
                    connection.close()
                }
                return
            }
            if connection.isHijacking {
                if let data, !data.isEmpty {
                    connection.forwardInbound(data)
                }
                self.continueRawRead(connection)
                return
            }
            var accumulated = buffered
            if let data, !data.isEmpty {
                accumulated.append(data)
            }
            self.readLoop(connection, buffer: accumulated)
        }
    }

    private func continueRawRead(_ connection: ShimConnection) {
        connection.networkConnection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                connection.forwardInbound(data)
            }
            if error != nil {
                connection.finishInbound()
                connection.close()
                return
            }
            if isComplete && data == nil {
                // Inbound EOF on a hijacked stream means the client is done
                // *sending* — it has no stdin to forward — not that the
                // exchange is over. The server still owns the outbound half,
                // which is what carries the container's output. Closing here
                // tears that down before a single byte is written: the docker
                // CLI half-closes immediately after the 101, so the output
                // lands on a dead socket and resurfaces on the client's pooled
                // connection as "Unsolicited response received on idle HTTP
                // channel". The writer closes the connection when the attached
                // process exits.
                connection.finishInbound()
                return
            }
            self.continueRawRead(connection)
        }
    }

    private func handle(_ request: ShimRequest, connection: ShimConnection, remainder: Data) async {
        if let port = connection.admissionPort,
            case .reject(let code, let reason) = LocalRequestGuard.evaluateShim(
                headers: request.headers, port: port)
        {
            fputs("[shim] \(request.method) /\(request.path) -> \(code) (\(reason))\n", stderr)
            let body = (try? JSONEncoder().encode(["message": reason])) ?? Data()
            _ = await connection.write(
                Self.head(
                    code: code, headers: [("Content-Type", "application/json"), ("Connection", "close")],
                    body: body) + body)
            connection.close()
            return
        }
        let response = await handler(request, connection)
        let status: Int
        switch response {
        case .status(let code): status = code
        case .json(let code, _): status = code
        case .raw(let code, _, _): status = code
        case .stream(let code, _, _): status = code
        case .hijacked: status = 101
        }
        fputs("[shim] \(request.method) /\(request.path) -> \(status)\n", stderr)
        switch response {
        case .status(let code):
            _ = await connection.write(Self.head(code: code, headers: [], body: Data()))
            finishFramed(request, connection: connection, remainder: remainder)
        case .json(let code, let data):
            let body = request.method == "HEAD" ? Data() : data
            _ = await connection.write(
                Self.head(code: code, headers: [("Content-Type", "application/json")], body: data)
                    + body)
            finishFramed(request, connection: connection, remainder: remainder)
        case .raw(let code, let headers, let data):
            // HEAD responses carry headers (incl. Content-Length) but no body;
            // sending one desynchronizes keep-alive clients.
            let body = request.method == "HEAD" ? Data() : data
            _ = await connection.write(Self.head(code: code, headers: headers, body: data) + body)
            finishFramed(request, connection: connection, remainder: remainder)
        case .stream(let code, let headers, let chunks):
            var allHeaders = headers
            allHeaders.append(("Cache-Control", "no-cache"))
            _ = await connection.write(Self.head(code: code, headers: allHeaders, body: nil))
            // A long poll (a `/wait`, a log follow) stops when its client
            // goes: cancelling the iteration terminates the stream, whose
            // `onTermination` stops the producer.
            let pump = Task {
                for await chunk in chunks {
                    if await connection.write(chunk) == .failed { break }
                }
            }
            connection.onClose { pump.cancel() }
            await pump.value
            connection.close()
        case .hijacked(let contentType):
            _ = await connection.write(
                Data(
                    "HTTP/1.1 101 UPGRADED\r\nContent-Type: \(contentType)\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
                        .utf8))
            // Inbound bytes flow via the stream the handler got from
            // beginHijack(); re-arm raw reads to feed it.
            continueRawRead(connection)
        }
    }

    /// Keep-alive: after a fully-framed response the connection stays open
    /// (and any pipelined bytes get processed) unless the client asked to
    /// close. Raw-fd transports keep reading on their serve thread.
    private func finishFramed(
        _ request: ShimRequest, connection: ShimConnection, remainder: Data
    ) {
        let wantsClose = request.header("connection").lowercased() == "close"
        if wantsClose {
            connection.close()
        } else if !connection.isFileDescriptor {
            readLoop(connection, buffer: remainder)
        }
    }

    static func head(code: Int, headers: [(String, String)], body: Data?) -> Data {
        let reason: String
        switch code {
        case 101: reason = "UPGRADED"
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 500: reason = "Internal Server Error"
        case 501: reason = "Not Implemented"
        default: reason = "OK"
        }
        var head = "HTTP/1.1 \(code) \(reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        if let body {
            // Framed response: keep-alive is the HTTP/1.1 default.
            head += "Content-Length: \(body.count)\r\n"
        } else {
            // Unframed live stream delimited by connection close (NDJSON logs,
            // events). Advertising chunked without framing breaks clients.
            head += "Connection: close\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }
}

/// Binary-safe incremental HTTP request parser: framing (head decoded as
/// text, body kept as raw bytes, Content-Length / chunked, limits) is
/// ``HTTPRequestFraming``; this maps the head onto Docker's routing shape.
enum ShimRequestParser {
    enum Outcome {
        case incomplete
        case request(ShimRequest, remainder: Data)
        /// Malformed or oversized: answer `status` and close.
        case invalid(status: Int, reason: String)
    }

    /// The request at the front of `buffer`, or nil while it is incomplete
    /// (or invalid — callers that must answer malformed input use
    /// ``parseOutcome(_:limits:)``).
    static func parse(_ buffer: Data) -> (request: ShimRequest, remainder: Data)? {
        if case .request(let request, let remainder) = parseOutcome(buffer) {
            return (request, remainder)
        }
        return nil
    }

    static func parseOutcome(
        _ buffer: Data, limits: HTTPRequestFraming.Limits = .dockerShim
    ) -> Outcome {
        switch HTTPRequestFraming.parse(buffer, limits: limits) {
        case .incomplete:
            return .incomplete
        case .invalid(let status, let reason):
            return .invalid(status: status, reason: reason)
        case .complete(let head, let body, let consumed):
            let remainder =
                consumed < buffer.count
                ? Data(buffer[buffer.index(buffer.startIndex, offsetBy: consumed)...]) : Data()
            return .request(request(from: head, body: body), remainder: remainder)
        }
    }

    static func request(from head: HTTPRequestFraming.Head, body: Data) -> ShimRequest {
        let target = head.target
        var path = target
        var query = [String: String]()
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qIndex])
            for pair in target[target.index(after: qIndex)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let first = kv.first, let key = String(first).removingPercentEncoding else { continue }
                let rawValue = kv.count > 1 ? String(kv[1]) : ""
                query[key] =
                    rawValue.replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? rawValue
            }
        }
        path = path.removingPercentEncoding ?? path

        // Docker clients pin an API version prefix (/v1.24/...); drop it.
        let rawSegments = path.split(separator: "/", omittingEmptySubsequences: true)
        if let v = rawSegments.first, v.count > 1, v.first == "v",
            v.dropFirst().allSatisfy({ $0 == "." || $0.isNumber })
        {
            path = String(path.dropFirst(v.count + 1))
        }
        return ShimRequest(
            method: head.method, path: path, query: query, headers: head.headers, body: body)
    }
}
