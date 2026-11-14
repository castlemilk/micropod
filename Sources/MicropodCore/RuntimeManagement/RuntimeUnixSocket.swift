import Darwin
import Foundation

/// Small BSD socket boundary shared by the managed API and its clients. The
/// kernel peer incarnation is checked before any capability or request is sent.
public enum RuntimeUnixSocket {
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else {
            throw MicropodError.message("The managed API socket path is invalid")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    public static func open() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure() }
        var value: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            close(fd)
            throw failure()
        }
        return fd
    }
    public static func connect(_ path: String, expectedUID: UInt32) throws -> Int32 {
        let fd = try open()
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, try peer(fd).uid == expectedUID else { throw failure() }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
    /// Darwin accept inherits the listener's O_NONBLOCK. The bounded worker
    /// must wait for bytes rather than treating EAGAIN as the peer's EOF.
    public static func configureAccepted(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0,
            fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
        else { throw failure() }
    }
    public static func peer(_ fd: Int32) throws -> RuntimeProcessBirth {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0,
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
            let birth = try RuntimeProcessBirth.read(pid), birth.uid == uid
        else { throw failure() }
        return birth
    }
    public static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
    }
    public static func timeout(_ fd: Int32, seconds: Int) throws {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0,
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0
        else { throw failure() }
    }
    private static func failure() -> Error { MicropodError.message("The managed API connection is unavailable") }
}
