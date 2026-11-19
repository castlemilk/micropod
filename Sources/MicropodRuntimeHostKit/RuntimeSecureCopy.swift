import Darwin
import Foundation
import MicropodCore

/// Copies an untrusted bundle into a directory only root can write and leaves
/// nothing an unprivileged process could use to change it afterwards: no ACL,
/// no file flags, no extended attributes, no setuid, setgid or sticky bit, no
/// group or world write, and every entry owned by `owner`. Then it proves all
/// of that by walking the copy. Only a proven copy is verified and run.
///
/// `ditto` keeps ACLs, extended attributes and file flags by default, and a
/// copy that kept an ACL granting write to the copying user could be changed
/// after verification. That is why both the copy flags and the walk exist.
public enum RuntimeSecureCopy {
    public struct Limits: Sendable {
        public var entries: Int
        public var bytes: Int64
        public init(entries: Int = 512, bytes: Int64 = 1 << 30) {
            self.entries = entries
            self.bytes = bytes
        }
    }

    /// Set by the system on files written by a process; not something an
    /// unprivileged process can use to change the file.
    static let toleratedAttributes: Set<String> = ["com.apple.provenance"]

    public static func copy(
        _ source: URL, to destination: URL, owner: uid_t = 0, group: gid_t = 0, limits: Limits = .init()
    ) throws {
        // Bounded before a byte is copied: only directories and regular files.
        _ = try walk(source, limits: limits) { _, _ in }
        try? remove(destination)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try NativeRuntimeComponentEnvironment.run(
                "/usr/bin/ditto", ["--noacl", "--noextattr", "--norsrc", "--noqtn", source.path, destination.path],
                timeout: 300)
            try normalize(destination, owner: owner, group: group, limits: limits)
            try assertSealed(destination, owner: owner, group: group, limits: limits)
        } catch {
            try? remove(destination)
            throw error
        }
    }

    /// Strips ACLs, flags, extended attributes and special mode bits and sets
    /// ownership and modes: directories 0755, executables 0755, others 0644.
    public static func normalize(_ root: URL, owner: uid_t, group: gid_t, limits: Limits = .init()) throws {
        _ = try walk(root, limits: limits) { path, info in
            guard lchflags(path, 0) == 0 else { throw failure("clear the flags of", path) }
            if let acl = acl_init(0) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                guard acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0 else {
                    throw failure("clear the ACL of", path)
                }
            }
            for name in try attributes(path) where !toleratedAttributes.contains(name) {
                guard removexattr(path, name, XATTR_NOFOLLOW) == 0 else { throw failure("strip an attribute of", path) }
            }
            guard lchown(path, owner, group) == 0 else { throw failure("own", path) }
            let directory = info.st_mode & S_IFMT == S_IFDIR
            let mode: mode_t = directory || info.st_mode & 0o111 != 0 ? 0o755 : 0o644
            guard chmod(path, mode) == 0 else { throw failure("set the mode of", path) }
        }
    }

    /// Proves `normalize` held: throws on the first entry that another account
    /// or process could change, or that is anything but a directory or a
    /// singly-linked regular file.
    public static func assertSealed(_ root: URL, owner: uid_t, group: gid_t, limits: Limits = .init()) throws {
        _ = try walk(root, limits: limits) { path, info in
            guard info.st_uid == owner, info.st_gid == group else { throw refused(path, "is owned by another account") }
            guard info.st_mode & 0o7022 == 0 else { throw refused(path, "is writable by others or setuid") }
            guard info.st_flags == 0 else { throw refused(path, "carries file flags") }
            if info.st_mode & S_IFMT == S_IFREG, info.st_nlink != 1 { throw refused(path, "is hard-linked") }
            if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 { throw refused(path, "carries an ACL") }
            }
            if try !Set(attributes(path)).isSubset(of: toleratedAttributes) {
                throw refused(path, "carries extended attributes")
            }
        }
    }

    /// Removes a tree without ever following a link: every directory is
    /// opened with O_NOFOLLOW | O_DIRECTORY relative to its parent's
    /// descriptor and checked against the lstat it was found with (dev and
    /// inode), entries are unlinked relative to that descriptor, and flags are
    /// cleared through descriptors, so a concurrent rename or symlink swap
    /// cannot redirect it outside the tree.
    public static func remove(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure("open the parent of", url.path) }
        defer { close(parent) }
        try removeEntry(url.lastPathComponent, in: parent, expected: info, path: url.path)
    }

    private static func removeEntry(_ name: String, in parent: Int32, expected: stat, path: String) throws {
        if expected.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("open", path) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino else {
                close(fd)
                throw refused(path, "changed while it was removed")
            }
            _ = fchflags(fd, 0)
            guard let directory = fdopendir(dup(fd)) else {
                close(fd)
                throw failure("list", path)
            }
            var names: [String] = []
            while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name != "." && name != ".." { names.append(name) }
            }
            closedir(directory)
            defer { close(fd) }
            for child in names {
                var info = stat()
                guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                try removeEntry(child, in: fd, expected: info, path: path + "/" + child)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw failure("remove", path) }
            return
        }
        if expected.st_mode & S_IFMT == S_IFREG {
            // Flags are cleared through a descriptor of this very file.
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 {
                var opened = stat()
                if fstat(fd, &opened) == 0, opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino {
                    _ = fchflags(fd, 0)
                }
                close(fd)
            }
        }
        // A link, FIFO or anything else is unlinked as itself, never followed.
        guard unlinkat(parent, name, 0) == 0 else { throw failure("remove", path) }
    }

    /// lstat-only walk (never follows or opens an entry). Refuses symbolic
    /// links, FIFOs, sockets and devices, and anything over `limits`.
    @discardableResult
    static func walk(_ root: URL, limits: Limits, visit: (String, stat) throws -> Void) throws -> [String] {
        var pending = [root.path]
        var visited: [String] = []
        var bytes: Int64 = 0
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw refused(path, "is unavailable") }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { throw refused(path, "is not a directory or regular file") }
            visited.append(path)
            bytes += Int64(info.st_size)
            guard visited.count <= limits.entries, bytes <= limits.bytes else {
                throw MicropodError.message("\(root.lastPathComponent) exceeds the size a setup app may have")
            }
            try visit(path, info)
            if kind == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                    pending.append(path + "/" + name)
                }
            }
        }
        return visited
    }

    static func attributes(_ path: String) throws -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw failure("list the attributes of", path) }
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) == size else {
            throw failure("list the attributes of", path)
        }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    static func failure(_ action: String, _ path: String) -> Error {
        MicropodError.message("Could not \(action) \(path) (\(errno))")
    }

    static func refused(_ path: String, _ reason: String) -> Error {
        MicropodError.message("The copied setup app is not sealed: \(path) \(reason)")
    }
}
