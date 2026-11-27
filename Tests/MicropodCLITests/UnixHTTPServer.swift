import Darwin
import Foundation
import MicropodCore

/// Answers every HTTP request on a unix socket with one fixed reply (200 OK
/// and "OK" by default), one request per connection, and counts them.
final class UnixHTTPServer: @unchecked Sendable {
    private let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private var served = 0
    private let reply: Data

    init(path: String, contentType: String = "text/plain", body: Data = Data("OK".utf8)) throws {
        self.path = path
        reply =
            Data("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            + body
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, bound == 0, listen(fd, 16) == 0 else {
            throw MicropodError.message("bind \(path): \(String(cString: strerror(errno)))")
        }
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() { lock.withLock { stopped = true } }
    var requests: Int { lock.withLock { served } }

    private func serve() {
        defer {
            close(fd)
            unlink(path)
        }
        while !lock.withLock({ stopped }) {
            var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 20) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 65536)
            _ = read(client, &buffer, buffer.count)
            lock.withLock { served += 1 }
            reply.withUnsafeBytes { raw in _ = write(client, raw.baseAddress, raw.count) }
            close(client)
        }
    }
}
