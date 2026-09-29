import Foundation
import MicropodCore

/// Minimal Docker Engine API client: HTTP/1.1 over a unix or TCP socket,
/// one connection per request (`Connection: close`). Enough for the
/// container lifecycle — no TLS, no hijacked attach.
public struct DockerClient: Sendable {
    public enum Endpoint: Sendable, Equatable, CustomStringConvertible {
        case unix(String)
        case tcp(host: String, port: UInt16)

        /// `unix:///path`, `/path`, or `tcp://host:port`.
        public static func parse(_ raw: String) throws -> Endpoint {
            if raw.hasPrefix("unix://") { return .unix(String(raw.dropFirst(7))) }
            if raw.hasPrefix("/") { return .unix(raw) }
            if raw.hasPrefix("tcp://") {
                let rest = raw.dropFirst(6).split(separator: "/").first.map(String.init) ?? ""
                let parts = rest.split(separator: ":")
                guard parts.count == 2, let port = UInt16(parts[1]), !parts[0].isEmpty else {
                    throw MicropodError.message("invalidArgument: docker endpoint '\(raw)' — want tcp://host:port")
                }
                return .tcp(host: String(parts[0]), port: port)
            }
            throw MicropodError.message(
                "invalidArgument: docker endpoint '\(raw)' — want unix:///path/docker.sock or tcp://host:port")
        }

        public var description: String {
            switch self {
            case .unix(let path): return "unix://\(path)"
            case .tcp(let host, let port): return "tcp://\(host):\(port)"
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
    static let apiVersion = "v1.43"

    public init(endpoint: Endpoint) { self.endpoint = endpoint }

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
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let endpoint = self.endpoint
        let head = Self.head(method, path, query: query, bodyLength: payload?.count)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let socket = try Socket.connect(endpoint, timeout: timeout)
                    defer { socket.close() }
                    try socket.write(Data(head.utf8) + (payload ?? Data()))
                    var reader = HTTPReader(socket: socket)
                    let (status, headers) = try reader.readHead()
                    let body = try reader.readBody(headers: headers)
                    continuation.resume(returning: Response(status: status, body: body))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Streaming body (logs follow, pull progress): yields raw body chunks as
    /// they arrive. Non-2xx statuses throw with Docker's message.
    public func stream(_ method: String, _ path: String, query: [String: String] = [:])
        -> AsyncThrowingStream<Data, Error>
    {
        let endpoint = self.endpoint
        let head = Self.head(method, path, query: query, bodyLength: nil)
        return AsyncThrowingStream { continuation in
            let box = SocketBox()
            DispatchQueue.global().async {
                do {
                    let socket = try Socket.connect(endpoint, timeout: nil)
                    box.set(socket)
                    defer { socket.close() }
                    try socket.write(Data(head.utf8))
                    var reader = HTTPReader(socket: socket)
                    let (status, headers) = try reader.readHead()
                    guard (200..<300).contains(status) else {
                        let body = try reader.readBody(headers: headers)
                        throw DockerClient.error(status: status, Response(status: status, body: body).message)
                    }
                    try reader.readBody(headers: headers) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: box.cancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in box.cancel() }
        }
    }

    static func head(_ method: String, _ path: String, query: [String: String], bodyLength: Int?) -> String {
        var target = "/\(apiVersion)\(path)"
        if !query.isEmpty {
            var comps = URLComponents()
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            target += "?" + (comps.percentEncodedQuery ?? "")
        }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: docker\r\nUser-Agent: micropod\r\nConnection: close\r\n"
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
    private(set) var cancelled = false

    func set(_ socket: Socket) {
        lock.lock()
        defer { lock.unlock() }
        self.socket = socket
        if cancelled { socket.shutdown() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        socket?.shutdown()
    }
}

final class Socket: @unchecked Sendable {
    let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func connect(_ endpoint: DockerClient.Endpoint, timeout: Duration?) throws -> Socket {
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
            var hints = addrinfo(
                ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
                throw MicropodError.message("unavailable: docker: cannot resolve \(host)")
            }
            defer { freeaddrinfo(result) }
            fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { throw Self.posix("socket") }
            guard Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
                let err = Self.posix("connect \(host):\(port)")
                Darwin.close(fd)
                throw err
            }
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
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { throw Self.posix("write") }
                sent += n
            }
        }
    }

    /// Up to `max` bytes; empty at EOF.
    func read(max: Int = 65536) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        let n = Darwin.read(fd, &buffer, max)
        guard n >= 0 else { throw Self.posix("read") }
        return Data(buffer[0..<n])
    }

    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }
    func close() { Darwin.close(fd) }
}

/// Buffered HTTP/1.1 response reader: status line + headers, then a
/// Content-Length, chunked, or read-to-EOF body.
struct HTTPReader {
    let socket: Socket
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
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            guard try fill() else { return nil }
        }
    }

    private mutating func take(_ count: Int) throws -> Data {
        while buffer.count < count {
            guard try fill() else { break }
        }
        let n = min(count, buffer.count)
        let out = Data(buffer.prefix(n))
        buffer.removeFirst(n)
        return out
    }

    mutating func readHead() throws -> (Int, [String: String]) {
        guard let status = try line() else { throw MicropodError.message("unavailable: docker: empty response") }
        let parts = status.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw MicropodError.message("internal: docker: bad status line '\(status)'")
        }
        var headers: [String: String] = [:]
        while let line = try line(), !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return (code, headers)
    }

    mutating func readBody(headers: [String: String]) throws -> Data {
        var out = Data()
        try readBody(headers: headers) { out.append($0) }
        return out
    }

    mutating func readBody(headers: [String: String], chunk emit: (Data) -> Void) throws {
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while let sizeLine = try line() {
                let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16) ?? 0
                if size == 0 { return }
                emit(try take(size))
                _ = try line()
            }
        } else if let length = headers["content-length"].flatMap(Int.init) {
            if length > 0 { emit(try take(length)) }
        } else {
            if !buffer.isEmpty {
                emit(buffer)
                buffer.removeAll()
            }
            while try fill() {
                emit(buffer)
                buffer.removeAll()
            }
        }
    }
}
