import Darwin
import Foundation

/// Local IPC must not depend on Network.framework's network-path state.
/// One socket and one absolute deadline; request bytes are never replayed.
enum AppControlSocket {
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    static func exchange(path: String, body: Data, timeout: TimeInterval, cancellation: Cancellation) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 600, body.count <= 64 * 1024 else {
            throw AppControlError.unavailable("invalid control socket request limits")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let fd = try RuntimeUnixSocket.open()
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw failure() }
        var address = try RuntimeUnixSocket.address(path)
        try check(deadline, cancellation)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw failure() }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw AppControlError.unavailable("no listener on control socket")
            }
        }
        try body.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try check(deadline, cancellation)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
                    continue
                }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try check(deadline, cancellation)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try wait(fd, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
                continue
            }
            guard count > 0 else { throw AppControlError.unavailable("truncated control socket response") }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 64 * 1024 else { throw AppControlError.malformedResponse }
            if let newline = response.firstIndex(of: 10) { return response.prefix(upTo: newline) }
        }
    }

    private static func check(_ deadline: UInt64, _ cancellation: Cancellation) throws {
        try cancellation.check()
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw AppControlError.unavailable("control socket timed out")
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: UInt64, cancellation: Cancellation) throws {
        while true {
            try check(deadline, cancellation)
            let remaining = deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(100, remaining / 1_000_000 + 1))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0, descriptor.revents & Int16(POLLNVAL) == 0 else { throw failure() }
            if ready > 0 { return }
        }
    }

    private static func failure() -> AppControlError {
        .unavailable("control socket connection failed: \(String(cString: strerror(errno)))")
    }
}
