import Darwin
import Foundation

enum DevVolumeMigration {
    static var fm: FileManager { .default }

    static func kind(_ path: String) throws -> mode_t? {
        var st = stat()
        if lstat(path, &st) == 0 { return st.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw DevVolumeError("Cannot inspect \(path): \(String(cString: strerror(errno)))")
    }

    static func physical(_ path: String) -> String {
        let absolute = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        if let buffer = realpath(absolute, nil) {
            defer { free(buffer) }
            return String(cString: buffer)
        }
        if absolute == "/" { return "/" }
        let url = URL(fileURLWithPath: absolute)
        return (physical(url.deletingLastPathComponent().path) as NSString).appendingPathComponent(
            url.lastPathComponent)
    }

    static func contains(_ root: String, _ child: String) -> Bool {
        child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func validateSource(_ path: String, state: String) throws {
        var info = stat()
        let home = physical(NSHomeDirectory())
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
            path == physical(path), !contains(path, home), !contains(path, state), !contains(state, path)
        else { throw DevVolumeError("Select an existing, user-owned directory outside the volume state: \(path)") }
        var parent = stat()
        let url = URL(fileURLWithPath: path)
        guard stat(url.deletingLastPathComponent().path, &parent) == 0, parent.st_dev == info.st_dev else {
            throw DevVolumeError("Select a directory within a filesystem, rather than a mount point: \(path)")
        }
    }

    static func quiescent(_ paths: [String]) throws {
        let cwd = physical(fm.currentDirectoryPath)
        for path in paths {
            guard !contains(physical(path), cwd) else {
                throw DevVolumeError("Run from outside \(path) before moving it")
            }
            let result = try DevTool.capture(DevTool.sudo, ["/usr/sbin/lsof", "-nP", "-Fpc", "+D", path])
            if !result.output.isEmpty {
                throw DevVolumeError("Close users of \(path) and retry.\n" + String(result.output.prefix(1500)))
            }
            guard result.code == 1 && result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DevVolumeError("Could not check open files in \(path). \(result.error)")
            }
        }
    }

    static func xattrs(_ path: String) throws -> [String: Data] {
        let flags = XATTR_NOFOLLOW
        let size = listxattr(path, nil, 0, flags)
        guard size >= 0 else { throw DevVolumeError("Cannot inspect extended attributes of \(path)") }
        if size == 0 { return [:] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, flags) == size else {
            throw DevVolumeError("Attributes changed on \(path)")
        }
        var result: [String: Data] = [:]
        for part in names.split(separator: 0) {
            let name = String(decoding: part.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let bytes = getxattr(path, name, nil, 0, 0, flags)
            guard bytes >= 0 else { throw DevVolumeError("Cannot inspect \(name) on \(path)") }
            var value = Data(count: bytes)
            let read = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, bytes, 0, flags) }
            guard read == bytes else { throw DevVolumeError("Attribute \(name) changed on \(path)") }
            result[name] = value
        }
        return result
    }

    static func accessList(_ path: String) throws -> String {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return "" }
            throw DevVolumeError("Cannot read ACL on \(path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { throw DevVolumeError("Cannot compare ACL on \(path)") }
        defer { acl_free(text) }
        return String(cString: text)
    }

    static func verify(_ source: String, _ target: String) throws {
        // -n makes --delete report extra destination entries without modifying them.
        let rsync = try DevTool.capture(
            "/usr/bin/rsync", ["-aHnic", "--delete", "--out-format=%i", source + "/", target + "/"])
        guard rsync.code == 0 && rsync.output.isEmpty else {
            throw DevVolumeError("Copy verification failed for \(source). \(rsync.error) \(rsync.output.prefix(300))")
        }
        var root = stat()
        guard lstat(source, &root) == 0 else { throw DevVolumeError("Missing source \(source)") }
        var pending = [""]
        while let relative = pending.popLast() {
            let left = source + relative, right = target + relative
            var original = stat(), copy = stat()
            guard lstat(left, &original) == 0, lstat(right, &copy) == 0, original.st_dev == root.st_dev else {
                throw DevVolumeError("Source changed or contains another mounted filesystem at \(left)")
            }
            guard original.st_flags == copy.st_flags, try xattrs(left) == xattrs(right),
                try accessList(left) == accessList(right)
            else { throw DevVolumeError("Metadata differs at \(left)") }
            if original.st_mode & S_IFMT == S_IFDIR {
                let names = try fm.contentsOfDirectory(atPath: left)
                pending.append(contentsOf: names.map { relative + "/" + $0 })
            }
        }
    }

    // ditto preserves links within one tree. pnpm can also link an inode in an
    // external store to several paths in the workspace. Rebuild those links in
    // the unpublished copy, using a previously migrated tree as the anchor.
    struct HardLinks {
        struct Key: Hashable {
            let device: dev_t
            let inode: ino_t
        }
        var anchors: [Key: String] = [:]
        let enabled: Bool

        mutating func track(from source: String, published: String, staging: String? = nil) throws {
            guard enabled else { return }
            var root = stat()
            guard lstat(source, &root) == 0 else { throw DevVolumeError("Cannot read \(source)") }
            var pending = [""], next: [Key: String] = [:]
            while let suffix = pending.popLast() {
                let path = source + suffix
                var original = stat()
                guard lstat(path, &original) == 0, original.st_dev == root.st_dev else {
                    throw DevVolumeError("Tree changed while checking hard links at \(path)")
                }
                switch original.st_mode & S_IFMT {
                case S_IFDIR:
                    let names = try fm.contentsOfDirectory(atPath: path)
                    pending.append(contentsOf: names.map { suffix + "/" + $0 })
                case S_IFREG where original.st_nlink > 1:
                    let key = Key(device: original.st_dev, inode: original.st_ino)
                    if let anchor = anchors[key], let staging {
                        try Self.relink(anchor, staged: staging + suffix)
                    } else if anchors[key] == nil && next[key] == nil {
                        next[key] = published + suffix
                    }
                default: break
                }
            }
            anchors.merge(next) { old, _ in old }
        }

        static func relink(_ anchor: String, staged: String) throws {
            // A previous invocation may already have published the anchor. An
            // edited or removed anchor must never replace the freshly copied file.
            var a = stat(), b = stat()
            guard lstat(staged, &b) == 0 else { throw DevVolumeError("Missing staged file \(staged)") }
            guard lstat(anchor, &a) == 0, a.st_dev == b.st_dev, a.st_ino != b.st_ino,
                a.st_mode == b.st_mode, a.st_uid == b.st_uid, a.st_gid == b.st_gid,
                a.st_flags == b.st_flags, a.st_size == b.st_size,
                a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec, a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec,
                try xattrs(anchor) == xattrs(staged), try accessList(anchor) == accessList(staged),
                fm.contentsEqual(atPath: anchor, andPath: staged)
            else { return }
            let parent = (staged as NSString).deletingLastPathComponent
            let tmp = parent + "/.micropod-link-" + UUID().uuidString
            var directory = stat()
            guard lstat(parent, &directory) == 0, Darwin.link(anchor, tmp) == 0 else {
                throw DevVolumeError("Cannot preserve hard link for \(staged): \(String(cString: strerror(errno)))")
            }
            defer { _ = unlink(tmp) }
            guard rename(tmp, staged) == 0,
                utimensat(AT_FDCWD, parent, [directory.st_atimespec, directory.st_mtimespec], AT_SYMLINK_NOFOLLOW) == 0
            else { throw DevVolumeError("Cannot publish hard link for \(staged)") }
        }
    }

    static func copy(_ source: String, to target: String) throws {
        guard try kind(target) == nil else { throw DevVolumeError("Copy destination already exists: \(target)") }
        try DevTool.interact("/usr/bin/ditto", ["-X", "--rsrc", "--extattr", "--acl", source, target])
        try verify(source, target)
    }

    static func exchange(_ first: String, _ second: String) throws {
        guard renameatx_np(AT_FDCWD, first, AT_FDCWD, second, UInt32(RENAME_SWAP)) == 0 else {
            throw DevVolumeError("Atomic path exchange failed: \(String(cString: strerror(errno)))")
        }
    }

    static func link(_ path: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: path) }

    static func sameDevice(_ path: String, _ root: String) throws {
        var one = stat(), two = stat()
        guard lstat(path, &one) == 0, lstat(root, &two) == 0, one.st_dev == two.st_dev, one.st_mode & S_IFMT == S_IFDIR
        else { throw DevVolumeError("Expected a real directory on the recorded filesystem: \(path)") }
    }

    static func migrate(_ tree: DevVolume.Tree, volume: DevVolume, state: String, links: inout HardLinks) throws {
        let target = volume.destination(tree)
        try sameDevice(volume.payload, volume.mount)
        if link(tree.source) == target {
            try sameDevice(target, volume.payload)
            guard try kind(tree.backup) == S_IFDIR else { throw DevVolumeError("Missing original at \(tree.backup)") }
            try links.track(from: tree.backup, published: target)
            return
        }
        try validateSource(tree.source, state: state)
        try quiescent([tree.source])
        if try kind(target) == nil {
            let staging = volume.payload + "/.copy-" + UUID().uuidString
            defer { if (try? kind(staging)) == S_IFDIR { try? fm.removeItem(atPath: staging) } }
            try copy(tree.source, to: staging)
            try links.track(from: tree.source, published: target, staging: staging)
            guard renameatx_np(AT_FDCWD, staging, AT_FDCWD, target, UInt32(RENAME_EXCL)) == 0
            else { throw DevVolumeError("Could not publish \(staging)") }
        }
        try sameDevice(target, volume.payload)
        try quiescent([tree.source, target])
        try verify(tree.source, target)
        try quiescent([tree.source, target])
        if try kind(tree.backup) == nil { try fm.createSymbolicLink(atPath: tree.backup, withDestinationPath: target) }
        guard link(tree.backup) == target else {
            throw DevVolumeError("Original backup name is occupied: \(tree.backup)")
        }
        try exchange(tree.source, tree.backup)
    }

    static func restore(_ tree: DevVolume.Tree, volume: DevVolume, links: inout HardLinks) throws {
        let target = volume.destination(tree)
        if try kind(tree.source) == S_IFDIR {
            if try kind(tree.backup) == S_IFDIR && kind(target) == S_IFDIR {
                try links.track(from: target, published: tree.source)
            }
            return
        }
        guard link(tree.source) == target, try kind(tree.backup) == S_IFDIR else {
            throw DevVolumeError("Source or backup no longer matches the recorded migration: \(tree.source)")
        }
        try sameDevice(target, volume.payload)
        try quiescent([target])
        let staging = tree.source + ".micropod-restore-" + UUID().uuidString
        // After a successful swap staging is the old symlink. Only an
        // unpublished directory allocated by this invocation is cleaned here.
        defer { if (try? kind(staging)) == S_IFDIR { try? fm.removeItem(atPath: staging) } }
        try copy(target, to: staging)
        try links.track(from: target, published: tree.source, staging: staging)
        try quiescent([target])
        try verify(target, staging)
        try quiescent([target])
        guard link(tree.source) == target else { throw DevVolumeError("Original link changed during restore") }
        try exchange(tree.source, staging)
        if link(staging) == target { _ = unlink(staging) }
    }
}
