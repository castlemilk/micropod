import Darwin
import Foundation
import MicropodCore
import SwiftProtobuf

/// A stand-in for the Micropod API daemon on a Unix socket or a loopback
/// TCP port, speaking HTTP/1.1 with keep-alive and Connect like the daemon
/// does: it records every request (its connection, route, content type and
/// body) and answers from `respond`. By default a unary call gets an empty
/// binary reply (every field at its default). `stall` reads a request and
/// never answers, as a daemon busy pruning would; `respondAfter` answers
/// late, as a long pull does.
final class FakeLocalAPI: @unchecked Sendable {
    enum Behavior: Sendable {
        case respond
        case stall
        case respondAfter(seconds: Double)
    }

    struct Request: Sendable {
        var connection: Int
        var method: String
        var path: String
        var contentType: String
        var body: Data

        /// The RPC's method name (`…/micropod.v1.X/Method` → `Method`).
        var rpc: String { String(path.split(separator: "/").last ?? "") }

        /// The request message (a stream request's single envelope unwrapped).
        func message<M: Message>(_ type: M.Type) throws -> M {
            var payload = body
            if contentType.hasPrefix("application/connect+"), body.count >= 5 { payload = Data(body.dropFirst(5)) }
            return try M(serializedBytes: payload)
        }
    }

    enum Reply: Sendable {
        case unary(Data)
        case error(status: Int, code: String, message: String)
        /// Envelopes, then an end-of-stream frame (`{}`, or the error).
        case stream([Data], errorCode: String?, errorMessage: String?)
        /// Read the request, then close the connection without a byte.
        case drop
        /// Answer, then close the connection (as a server stopping would).
        case thenClose(Data)
    }

    static func unary(_ message: some Message) -> Reply { .unary((try? message.serializedData()) ?? Data()) }
    static func stream(_ messages: [any Message]) -> Reply {
        .stream(messages.map { (try? $0.serializedData()) ?? Data() }, errorCode: nil, errorMessage: nil)
    }

    let behavior: Behavior
    /// The TCP port, 0 on a Unix socket.
    private(set) var port = 0
    private let fd: Int32
    private let socketPath: String?
    private let lock = NSLock()
    private var seen: [Request] = []
    private var stopped = false
    private var accepted = 0
    private var responder: @Sendable (Request) -> Reply = { _ in .unary(Data()) }

    /// Answers each request with `responder` from now on.
    func respond(_ responder: @escaping @Sendable (Request) -> Reply) {
        lock.withLock { self.responder = responder }
    }

    init(unixSocket path: String, behavior: Behavior = .respond) throws {
        self.behavior = behavior
        socketPath = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MicropodError.message("socket: \(String(cString: strerror(errno)))") }
        var address = try RuntimeUnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try listenOrThrow(bound, "bind \(path)")
    }

    /// Listens on 127.0.0.1 at a port the kernel picks.
    init(tcpLoopback behavior: Behavior = .respond) throws {
        self.behavior = behavior
        socketPath = nil
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MicropodError.message("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try listenOrThrow(bound, "bind 127.0.0.1:0")
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    private func listenOrThrow(_ bound: Int32, _ what: String) throws {
        guard bound == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MicropodError.message("\(what): \(message)")
        }
        Thread.detachNewThread { [self] in serve() }
    }

    var requests: [Request] { lock.withLock { seen } }
    /// Connections accepted so far.
    var connections: Int { lock.withLock { accepted } }

    func stop() {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func serve() {
        defer {
            Darwin.close(fd)
            if let socketPath { unlink(socketPath) }
        }
        while !isStopped {
            var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 20) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            let id = lock.withLock {
                accepted += 1
                return accepted
            }
            Thread.detachNewThread { [self] in
                serveConnection(client, id: id)
                Darwin.close(client)
            }
        }
    }

    /// One connection: requests until the client closes it, or a reply
    /// closes it.
    private func serveConnection(_ client: Int32, id: Int) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func fill() -> Bool {
            while !isStopped {
                var poll = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                if Darwin.poll(&poll, 1, 50) == 0 { continue }
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { return false }
                data.append(contentsOf: buffer[0..<count])
                return true
            }
            return false
        }
        let separator = Data("\r\n\r\n".utf8)
        while true {
            while data.range(of: separator) == nil { guard fill() else { return } }
            guard let end = data.range(of: separator) else { return }
            let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ")
            guard requestLine.count >= 2 else { return }
            func header(_ name: String) -> String? {
                lines.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }
                    .map { String($0.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces) }
            }
            let length = header("content-length").flatMap { Int($0) } ?? 0
            while data.count - end.upperBound < length { guard fill() else { return } }
            let bodyStart = end.upperBound
            let request = Request(
                connection: id, method: String(requestLine[0]), path: String(requestLine[1]),
                contentType: header("content-type") ?? "", body: Data(data[bodyStart..<(bodyStart + length)]))
            data = Data(data[(bodyStart + length)...])
            let closing = (header("connection") ?? "").lowercased().contains("close")
            lock.withLock { seen.append(request) }
            switch behavior {
            case .stall:
                let deadline = Date().addingTimeInterval(10)
                while !isStopped, Date() < deadline {
                    var poll = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                    if Darwin.poll(&poll, 1, 50) > 0 { break }
                }
                return
            case .respondAfter(let seconds):
                Thread.sleep(forTimeInterval: seconds)
            case .respond:
                break
            }
            let reply = lock.withLock { responder }(request)
            func send(_ bytes: Data) { _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) } }
            func replyHead(_ status: Int, _ type: String, _ count: Int, close: Bool) -> Data {
                Data(
                    ("HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(count)\r\n"
                        + (close ? "Connection: close\r\n" : "") + "\r\n").utf8)
            }
            switch reply {
            case .unary(let body):
                send(replyHead(200, "application/proto", body.count, close: closing) + body)
                if closing { return }
            case .thenClose(let body):
                send(replyHead(200, "application/proto", body.count, close: false) + body)
                return
            case .error(let status, let code, let message):
                let body = Data(#"{"code":"\#(code)","message":"\#(message)"}"#.utf8)
                send(replyHead(status, "application/json", body.count, close: closing) + body)
                if closing { return }
            case .drop:
                return
            case .stream(let messages, let code, let message):
                var frames = Data()
                for message in messages { frames += Self.envelope(message, flags: 0) }
                let trailer = code.map { #"{"error":{"code":"\#($0)","message":"\#(message ?? "")"}}"# } ?? "{}"
                frames += Self.envelope(Data(trailer.utf8), flags: 2)
                // Chunked and kept when the client asks, as the daemon does.
                if !closing, (header("x-micropod-stream-framing") ?? "").lowercased() == "chunked" {
                    var body = Data(
                        ("HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n"
                            + "X-Micropod-Stream-Framing: chunked\r\n\r\n").utf8)
                    body += Data((String(frames.count, radix: 16) + "\r\n").utf8) + frames + Data("\r\n0\r\n\r\n".utf8)
                    send(body)
                    continue
                }
                send(
                    Data("HTTP/1.1 200 X\r\nContent-Type: application/connect+proto\r\nConnection: close\r\n\r\n".utf8)
                        + frames)
                return
            }
        }
    }

    static func envelope(_ payload: Data, flags: UInt8) -> Data {
        var frame = Data([flags])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        return frame + payload
    }
}
