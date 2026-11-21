import Darwin
import Foundation

/// Publishes an immutable disk once per cache key. Independent CLI processes
/// and API tasks share the lock. Each sandbox still clones its own writable disk.
struct SandboxDiskCache {
    let root: URL

    func materialize(at disk: URL, populate: (URL) async throws -> Void) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: disk.path) { return }

        // Keep lock inodes outside images/, which sandbox prune removes.
        // Unlinking a lock while another process has it open creates two owners.
        let locks = root.appendingPathComponent("disk-locks")
        try fm.createDirectory(at: locks, withIntermediateDirectories: true)
        let lock = locks.appendingPathComponent(disk.lastPathComponent + ".lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.fileError(errno, at: lock) }
        defer { _ = close(fd) }

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else { throw Self.fileError(code, at: lock) }
            try Task.checkCancellation()
            if fm.fileExists(atPath: disk.path) { return }
            // Never block a Swift cooperative thread behind an async unpack.
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: disk.path) { return }

        let directory = disk.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(disk.lastPathComponent).partial")
        // The previous owner may have died mid-unpack. Only the lock owner
        // can write this path, and readers only use the renamed disk.
        if unlink(temporary.path) != 0 && errno != ENOENT { throw Self.fileError(errno, at: temporary) }
        defer { _ = unlink(temporary.path) }
        try await populate(temporary)
        try Task.checkCancellation()
        guard rename(temporary.path, disk.path) == 0 else { throw Self.fileError(errno, at: disk) }
    }

    private static func fileError(_ code: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
