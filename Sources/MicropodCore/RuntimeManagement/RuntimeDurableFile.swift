import Darwin
import Foundation

/// Atomic replacement plus file and directory fsync. This is used for action
/// intent, not just preferences: failure must stop the action before it begins.
public enum RuntimeDurableFile {
    public static func read(_ url: URL, maximumBytes: Int, ownerUID: uid_t = getuid()) throws -> Data {
        // O_NONBLOCK: opening a FIFO planted in place of a file must not
        // wedge the caller; anything but a regular file is refused at fstat.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == ownerUID, info.st_size >= 0, info.st_size <= maximumBytes,
            fcntl(fd, F_SETFL, 0) == 0
        else { throw failure() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes + 1, 8192))
        while result.count <= maximumBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes + 1 - result.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw MicropodError.message("Runtime maintenance state exceeds its size limit")
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".intent-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let bytes = try JSONEncoder().encode(value)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw failure() }
        try syncDirectory(directory)
    }

    public static func remove(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT { throw failure() }
        try syncDirectory(url.deletingLastPathComponent())
    }

    public static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw failure() }
    }

    private static func failure() -> Error {
        MicropodError.message("Could not persist runtime maintenance state (\(errno))")
    }
}

/// Bounded reads of files another account may control. Never blocks on a
/// FIFO, never follows a link, refuses anything but a regular file. The bytes
/// are trusted only after a signature or a sealed root-owned copy verifies.
public enum RuntimeNonblockingFile {
    public static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw MicropodError.message("\(url.lastPathComponent) is unavailable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
            fcntl(fd, F_SETFL, 0) == 0
        else {
            throw MicropodError.message("\(url.lastPathComponent) is not a bounded regular file")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MicropodError.message("\(url.lastPathComponent) is oversized") }
        return data
    }
}
