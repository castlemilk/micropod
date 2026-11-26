import Foundation
import MicropodCore

/// Minimal Docker Engine API client: HTTP/1.1 over a unix or TCP socket,
/// one connection per request. Attached exec upgrades its connection to
/// the Docker multiplexed byte stream.
public struct DockerClient: Sendable {
    public enum Endpoint: Sendable, Equatable, CustomStringConvertible {
        case unix(String)
        case tcp(host: String, port: UInt16)

        /// `unix:///path`, `/path`, or `tcp://host:port`.
        public static func parse(_ raw: String) throws -> Endpoint {
            if raw.hasPrefix("unix://") { return .unix(String(raw.dropFirst(7))) }
            if raw.hasPrefix("/") { return .unix(raw) }
            if raw.hasPrefix("tcp://") {
                guard let url = URLComponents(string: raw), url.user == nil, url.password == nil,
                    let authorityHost = url.host, !authorityHost.isEmpty,
                    let number = url.port, let port = UInt16(exactly: number)
                else {
                    throw MicropodError.message("invalidArgument: docker endpoint '\(raw)' — want tcp://host:port")
                }
                let host = authorityHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                guard !host.utf8.contains(0), host == authorityHost || host.contains(":") else {
                    throw MicropodError.message("invalidArgument: docker: invalid TCP hostname")
                }
                return .tcp(host: host, port: port)
            }
            throw MicropodError.message(
                "invalidArgument: docker endpoint '\(raw)' — want unix:///path/docker.sock or tcp://host:port")
        }

        public var description: String {
            switch self {
            case .unix(let path): return "unix://\(path)"
            case .tcp(let host, let port):
                let encoded = host.replacingOccurrences(of: "%", with: "%25")
                let authority = encoded.contains(":") && !encoded.hasPrefix("[") ? "[\(encoded)]" : encoded
                return "tcp://\(authority):\(port)"
            }
        }
    }

    public struct Response: Sendable {
        public let status: Int
        public let body: Data

        func json() throws -> Any {
            try JSONSerialization.jsonObject(with: body.isEmpty ? Data("null".utf8) : body, options: .fragmentsAllowed)
        }

        /// Docker's `{"message": "..."}` error body.
        var message: String {
            ((try? json()) as? [String: Any])?["message"] as? String
                ?? String(decoding: body, as: UTF8.self)
        }
    }

    public let endpoint: Endpoint
    /// Path prefix naming the Engine API version. Docker Engine accepts
    /// older versions; micropod's guest engine only serves 1.44 and later.
    public let apiVersion: String
    public static let defaultAPIVersion = "v1.43"
    private let negotiation: DockerAPINegotiation?

    public init(endpoint: Endpoint, apiVersion: String = DockerClient.defaultAPIVersion) {
        self.endpoint = endpoint
        self.apiVersion = apiVersion
        negotiation = nil
    }

    /// The external Docker adapter negotiates once per endpoint. The native
    /// machine uses the explicitly versioned initializer above.
    init(endpoint: Endpoint, environment: [String: String]) throws {
        self.endpoint = endpoint
        if let version = environment["DOCKER_API_VERSION"], !version.isEmpty {
            guard DockerAPINegotiation.minor(version) != nil else {
                throw MicropodError.message("invalidArgument: invalid DOCKER_API_VERSION '\(version)'")
            }
            apiVersion = "v" + version
            negotiation = nil
        } else {
            apiVersion = Self.defaultAPIVersion
            negotiation = DockerAPINegotiation()
        }
    }

    /// `DOCKER_HOST`, else the stock socket.
    public static func defaultEndpoint(environment: [String: String]) -> String {
        environment["DOCKER_HOST"] ?? "unix:///var/run/docker.sock"
    }

    public var reachable: Bool {
        switch endpoint {
        case .unix(let path): return FileManager.default.fileExists(atPath: path)
        case .tcp: return true
        }
    }

    // MARK: Requests

    public func request(
        _ method: String, _ path: String, query: [String: String] = [:], json body: Any? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> Response {
        try await request(method, path, query: query, json: body, timeout: timeout, detachedExec: false)
    }

    func startDetachedExec(_ path: String, tty: Bool) async throws {
        try check(
            try await request("POST", path, query: [:], json: ["Detach": true, "Tty": tty], detachedExec: true))
    }

    private func request(
        _ method: String, _ path: String, query: [String: String], json body: Any?,
        timeout: Duration = .seconds(120), detachedExec: Bool
    ) async throws -> Response {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await withRequestSocket(method, path, query: query, length: payload?.count, timeout: timeout) {
            socket, head in
            try socket.write(head + (payload ?? Data()))
            var reader = HTTPReader(socket: socket)
            let (status, headers) = try reader.readHead()
            let successful = (200..<300).contains(status)
            if detachedExec {
                // An attached response may be a 101 upgrade or a 200 stream.
                // Detect it at the headers, before waiting for EOF.
                let mediaType = headers["content-type"]?.lowercased().split(separator: ";", maxSplits: 1)
                    .first?.trimmingCharacters(in: .whitespaces)
                let attached =
                    mediaType == "application/vnd.docker.raw-stream"
                    || mediaType == "application/vnd.docker.multiplexed-stream"
                if status == 101 || (successful && attached) {
                    throw MicropodError.unsupported(
                        "docker engine returned an attached stream for detached exec")
                }
            }
            let noBody = method.uppercased() == "HEAD" || status == 204 || status == 304
            let body = noBody || (detachedExec && successful) ? Data() : try reader.readBody(headers: headers)
            if status == 400 { negotiation?.invalidate() }
            return Response(status: status, body: body)
        }
    }

    func withRequestSocket<T: Sendable>(
        _ method: String, _ path: String, query: [String: String] = [:], length: Int?, timeout: Duration?,
        upgrade: Bool = false, perform: @escaping @Sendable (Socket, Data) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let box = SocketBox()
        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                DispatchQueue.global().async {
                    let result = Result {
                        try box.checkCancellation()
                        let head = try requestHead(
                            method, path, query: query, length: length, upgrade: upgrade, cancellation: box)
                        try box.checkCancellation()
                        let socket = try Socket.connect(endpoint, timeout: timeout, cancellation: box)
                        box.set(socket)
                        defer { box.close() }
                        try box.checkCancellation()
                        return try perform(socket, Data(head.utf8))
                    }
                    if box.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(with: result)
                    }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            box.cancel()
        }
    }

    /// Streaming body (logs follow, pull progress): yields raw body chunks as
    /// they arrive. Non-2xx statuses throw with Docker's message.
    public func stream(_ method: String, _ path: String, query: [String: String] = [:])
        -> AsyncThrowingStream<Data, Error>
    {
        let endpoint = self.endpoint
        return AsyncThrowingStream { continuation in
            let box = SocketBox()
            DispatchQueue.global().async {
                do {
                    let head = try requestHead(method, path, query: query, length: nil, cancellation: box)
                    let socket = try Socket.connect(endpoint, timeout: nil, cancellation: box)
                    box.set(socket)
                    defer { box.close() }
                    try socket.write(Data(head.utf8))
                    var reader = HTTPReader(socket: socket)
                    let (status, headers) = try reader.readHead()
                    guard (200..<300).contains(status) else {
                        if status == 400 { negotiation?.invalidate() }
                        let body = try reader.readBody(headers: headers)
                        throw DockerClient.error(status: status, Response(status: status, body: body).message)
                    }
                    if method.uppercased() != "HEAD" && status != 204 {
                        try reader.readBody(headers: headers) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: box.cancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in box.cancel() }
        }
    }

    /// Called on the blocking I/O queue because a new external endpoint may need a handshake.
    func requestHead(
        _ method: String, _ path: String, query: [String: String] = [:], length: Int?, upgrade: Bool = false,
        cancellation: SocketBox? = nil
    ) throws -> String {
        let version = try negotiation?.version(endpoint, cancellation: cancellation) ?? apiVersion
        return Self.head(method, path, query: query, bodyLength: length, apiVersion: version, upgrade: upgrade)
    }

    static func head(
        _ method: String, _ path: String, query: [String: String], bodyLength: Int?,
        apiVersion: String = defaultAPIVersion, upgrade: Bool = false
    ) -> String {
        var target = apiVersion.isEmpty ? path : "/\(apiVersion)\(path)"
        if !query.isEmpty {
            var comps = URLComponents()
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            target += "?" + (comps.percentEncodedQuery ?? "")
        }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: docker\r\nUser-Agent: micropod\r\n"
        head += upgrade ? "Connection: Upgrade\r\nUpgrade: tcp\r\n" : "Connection: close\r\n"
        if let bodyLength {
            head += "Content-Type: application/json\r\nContent-Length: \(bodyLength)\r\n"
        }
        return head + "\r\n"
    }

    /// Docker status → the `code: message` convention ConnectCodeMapping reads.
    static func error(status: Int, _ message: String) -> MicropodError {
        let code: String
        switch status {
        case 400: code = "invalidArgument"
        case 404: code = "notFound"
        case 409: code = "alreadyExists"
        case 304: code = "failedPrecondition"
        default: code = "internal"
        }
        return .message("\(code): docker: \(message)")
    }

    /// Throws unless `status` is 2xx (or in `also`).
    @discardableResult
    func check(_ response: Response, also: Set<Int> = []) throws -> Response {
        guard (200..<300).contains(response.status) || also.contains(response.status) else {
            throw Self.error(status: response.status, response.message)
        }
        return response
    }

    /// Splits Docker's multiplexed stdio stream (8-byte frame headers:
    /// stream id, 3 pad bytes, big-endian length) into (stdout, stderr).
    /// A TTY stream has no framing and is returned as stdout.
    public static func demux(_ data: Data) -> (stdout: Data, stderr: Data) {
        var out = Data(), err = Data()
        let bytes = [UInt8](data)
        var offset = 0
        guard let first = bytes.first, first <= 2, bytes.count >= 8, bytes[1...3] == [0, 0, 0] else {
            return (data, Data())
        }
        while offset + 8 <= bytes.count {
            let kind = bytes[offset]
            let length =
                Int(bytes[offset + 4]) << 24 | Int(bytes[offset + 5]) << 16 | Int(bytes[offset + 6]) << 8
                | Int(bytes[offset + 7])
            let start = offset + 8
            let end = min(start + length, bytes.count)
            let payload = Data(bytes[start..<end])
            if kind == 2 { err.append(payload) } else { out.append(payload) }
            offset = end
        }
        return (out, err)
    }
}

// MARK: - Socket plumbing

final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: Socket?
    private var didCancel = false

    var cancelled: Bool { lock.withLock { didCancel } }

    func checkCancellation() throws {
        if cancelled { throw CancellationError() }
    }

    func set(_ socket: Socket) {
        lock.lock()
        defer { lock.unlock() }
        self.socket = socket
        if didCancel { socket.shutdown() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        didCancel = true
        socket?.shutdown()
    }

    func close() {
        lock.withLock {
            socket?.close()
            socket = nil
        }
    }
}

final class Socket: @unchecked Sendable {
    let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func connect(_ endpoint: DockerClient.Endpoint, timeout: Duration?, cancellation: SocketBox? = nil) throws
        -> Socket
    {
        let fd: Int32
        switch endpoint {
        case .unix(let path):
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Self.posix("socket") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            guard path.utf8.count < capacity else {
                Darwin.close(fd)
                throw MicropodError.message("invalidArgument: socket path too long: \(path)")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: path.utf8)
                raw[path.utf8.count] = 0
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else {
                let err = Self.posix("connect \(path)")
                Darwin.close(fd)
                throw err
            }
        case .tcp(let host, let port):
            fd = try DockerTCPConnection.connect(
                host: host, port: port, timeout: timeout ?? .seconds(120), cancellation: cancellation)
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var tv = timeval(tv_sec: Int(timeout.components.seconds), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        return Socket(fd: fd)
    }

    static func posix(_ what: String) -> MicropodError {
        .message("unavailable: docker: \(what): \(String(cString: strerror(errno)))")
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.posix("write") }
                sent += count
            }
        }
    }

    /// Up to `max` bytes; empty at EOF.
    func read(max: Int = 65536) throws -> Data {
        guard let buffer = malloc(max) else { throw POSIXError(.ENOMEM) }
        while true {
            let n = Darwin.read(fd, buffer, max)
            if n < 0, errno == EINTR { continue }
            if n > 0 { return Data(bytesNoCopy: buffer, count: n, deallocator: .free) }
            let error = n < 0 ? Self.posix("read") : nil
            free(buffer)
            if let error { throw error }
            return Data()
        }
    }

    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }
    func close() { Darwin.close(fd) }
}

/// Buffered HTTP/1.1 response reader: status line + headers, then a
/// Content-Length, chunked, or read-to-EOF body.
struct HTTPReader {
    let socket: Socket
    private static let headerLimit = 1_048_576
    private var buffer = Data()
    private var eof = false

    init(socket: Socket) { self.socket = socket }

    private mutating func fill() throws -> Bool {
        guard !eof else { return false }
        let chunk = try socket.read()
        if chunk.isEmpty {
            eof = true
            return false
        }
        buffer.append(chunk)
        return true
    }

    private mutating func line() throws -> String? {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                guard range.lowerBound - buffer.startIndex <= Self.headerLimit else {
                    throw MicropodError.message("internal: docker: oversized HTTP line")
                }
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            guard buffer.count <= Self.headerLimit else {
                throw MicropodError.message("internal: docker: oversized HTTP line")
            }
            guard try fill() else { return nil }
        }
    }

    private mutating func consume(_ count: Int, emit: (Data) throws -> Void) throws {
        var remaining = count
        while remaining > 0 {
            if buffer.isEmpty, try !fill() {
                throw MicropodError.message("unavailable: docker: truncated response body")
            }
            let length = min(remaining, buffer.count)
            try emit(buffer.prefix(length))
            buffer.removeFirst(length)
            remaining -= length
        }
    }

    mutating func readHead() throws -> (Int, [String: String]) {
        guard let status = try line() else { throw MicropodError.message("unavailable: docker: empty response") }
        let parts = status.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw MicropodError.message("internal: docker: bad status line '\(status)'")
        }
        return (code, try readFields())
    }

    private mutating func readFields() throws -> [String: String] {
        var headers: [String: String] = [:]
        var headerBytes = 0
        while true {
            guard let line = try line() else {
                throw MicropodError.message("unavailable: docker: truncated HTTP headers")
            }
            if line.isEmpty { break }
            headerBytes += line.utf8.count + 2
            guard headerBytes <= Self.headerLimit else {
                throw MicropodError.message("internal: docker: oversized HTTP headers")
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    mutating func readBody(headers: [String: String], limit: Int = .max) throws -> Data {
        var out = Data()
        try readBody(headers: headers) { chunk in
            guard chunk.count <= limit - out.count else {
                throw MicropodError.message("internal: docker: oversized response body")
            }
            out.append(chunk)
        }
        return out
    }

    mutating func readBody(headers: [String: String], chunk emit: (Data) throws -> Void) throws {
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                guard let sizeLine = try line(), let size = Int(sizeLine.prefix { $0 != ";" }, radix: 16), size >= 0
                else {
                    throw MicropodError.message("unavailable: docker: invalid HTTP chunk length")
                }
                if size == 0 {
                    _ = try readFields()
                    return
                }
                try consume(size, emit: emit)
                guard try line() == "" else {
                    throw MicropodError.message("unavailable: docker: incomplete HTTP chunk")
                }
            }
        } else if let lengthHeader = headers["content-length"] {
            guard let length = Int(lengthHeader), length >= 0 else {
                throw MicropodError.message("unavailable: docker: invalid Content-Length")
            }
            try consume(length, emit: emit)
        } else {
            if !buffer.isEmpty {
                try emit(buffer)
                buffer.removeAll()
            }
            while !eof {
                let chunk = try socket.read()
                if chunk.isEmpty { eof = true } else { try emit(chunk) }
            }
        }
    }
}
