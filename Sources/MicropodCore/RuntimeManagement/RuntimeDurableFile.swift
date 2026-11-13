import Darwin
import Foundation

/// Atomic replacement plus file and directory fsync. This is used for action
/// intent, not just preferences: failure must stop the action before it begins.
public enum RuntimeDurableFile {
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == getuid(), info.st_size >= 0, info.st_size <= maximumBytes
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
