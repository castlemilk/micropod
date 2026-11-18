import CPtyShim
import Darwin
import Foundation

public struct RuntimeProcessBirth: Codable, Sendable, Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let seconds: Int64
    public let microseconds: Int64
    public let bootSession: String

    public static func read(_ pid: Int32) throws -> Self? {
        var uid: uid_t = 0
        var seconds: Int64 = 0
        var microseconds: Int64 = 0
        let result = micropod_process_birth(pid, &uid, &seconds, &microseconds)
        if result == 1 { return nil }
        guard result == 0 else { throw MicropodError.message("Runtime worker process identity is unconfirmed") }
        return Self(
            pid: pid, uid: uid, seconds: seconds, microseconds: microseconds, bootSession: try currentBootSession())
    }

    /// This boot's `kern.bootsessionuuid`: a birth recorded under another
    /// value belongs to an earlier boot, so that process is gone.
    public static func currentBootSession() throws -> String {
        var value = [CChar](repeating: 0, count: 128)
        var size = value.count
        guard sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0, size > 1, size <= value.count else {
            throw MicropodError.message("The macOS boot identity is unavailable")
        }
        return String(decoding: value.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// When this boot began (`kern.boottime`), or nil when unreadable.
    public static func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }

    public func hasExited() throws -> Bool {
        guard let current = try Self.read(pid) else { return true }
        return current != self
    }
}
