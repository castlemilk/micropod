import Darwin
import Foundation
import MicropodCore

/// A stand-in for the Micropod API daemon, on a Unix socket or a loopback
/// TCP port: it records every request and, like the daemon's prune route,
/// counts an eviction for each prune that is not a dry run. `stall` reads a
/// request and then never answers, as a daemon busy pruning would.
final class FakeLocalAPI: @unchecked Sendable {
    enum Behavior: Sendable {
        case respond
        case stall
    }

    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        }
    }

    let behavior: Behavior
    /// The TCP port, 0 on a Unix socket.
    private(set) var port = 0
    private let fd: Int32
    private let socketPath: String?
    private let lock = NSLock()
    private var seen: [Request] = []
    private var evicted = 0
    private var stopped = false

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
    var evictions: Int { lock.withLock { evicted } }

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
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func fill() -> Bool {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return false }
            data.append(contentsOf: buffer[0..<count])
            return true
        }
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil { guard fill() else { return } }
        guard let end = data.range(of: separator) else { return }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return }
        let length =
            lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        while data.count - end.upperBound < length { guard fill() else { break } }
        let request = Request(
            method: String(requestLine[0]), path: String(requestLine[1]), body: Data(data[end.upperBound...]))
        let dryRun = request.json["dryRun"] as? Bool ?? true
        lock.withLock {
            seen.append(request)
            if request.path == "/v1/caches/prune", !dryRun { evicted += 1 }
        }
        switch behavior {
        case .stall:
            // Hold the request unanswered until the client gives up.
            let deadline = Date().addingTimeInterval(10)
            while !isStopped, Date() < deadline {
                var poll = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                if Darwin.poll(&poll, 1, 50) > 0 { break }
            }
        case .respond:
            let reply: Data
            if request.path == "/v1/caches/prune" {
                reply = Data(#"{"dryRun":\#(dryRun),"freedBytes":0,"actions":[]}"#.utf8)
            } else {
                reply = request.body.isEmpty ? Data("{}".utf8) : request.body
            }
            let response =
                Data(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(reply.count)\r\nConnection: close\r\n\r\n"
                        .utf8) + reply
            _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        }
    }
}
