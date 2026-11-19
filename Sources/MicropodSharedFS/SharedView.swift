import Darwin
import Foundation

/// A single per-container clone of a shared source tree, built on APFS
/// `clonefile` for cheap CoW copies of regular files. The container
/// sees a normal directory that the runtime binds into it; writes from
/// inside the container land in the view and can be synced back to the
/// source on demand.
public final class SharedView: @unchecked Sendable {
    public let id: ViewID
    public let source: URL
    public let root: URL
    public let readonly: Bool
    public let createdAt: Date

    public init(id: ViewID, source: URL, root: URL, createdAt: Date = Date(), readonly: Bool = false) {
        self.id = id
        self.source = source
        self.root = root
        self.readonly = readonly
        self.createdAt = createdAt
    }

    /// Publish a complete view at a new path. An existing destination belongs
    /// to its creator. Only the daemon can request replacement of a known view.
    public static func build(source: URL, root: URL) throws {
        try build(source: source, root: root, files: .native)
    }

    static func build(source: URL, root: URL, files: SharedFileOperations, replacing: Bool = false) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = root.resolvingSymlinksInPath().standardizedFileURL
        guard !source.pathComponents.starts(with: destination.pathComponents),
            !destination.pathComponents.starts(with: source.pathComponents)
        else { throw POSIXError(.EINVAL) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw SharedFSError.sourceUnreadable(source)
        }
        var target = stat()
        if lstat(root.path, &target) == 0 {
            guard replacing else { throw POSIXError(.EEXIST) }
            guard target.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        } else if replacing || errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let ignores = try loadIgnorePatterns(from: source)
        try withSharedFSStaging(beside: root) { staging in
            if !ignores.isEmpty || !files.clone(source, staging) {
                try populate(from: source, to: staging, ignores: ignores, files: files)
            }
            if replacing {
                try refreshDirectory(root, from: staging)
            } else if renamex_np(staging.path, root.path, UInt32(RENAME_EXCL)) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// A running guest can hold an open directory descriptor for the mount.
    /// Keep that inode and install completed top-level entries into it. Save
    /// displaced entries in staging until the whole refresh has committed.
    private static func refreshDirectory(_ root: URL, from snapshot: URL) throws {
        let previous = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let next = Set(try FileManager.default.contentsOfDirectory(atPath: snapshot.path))
        var applied: [(from: URL, to: URL, flags: UInt32, inode: ino_t)] = []
        do {
            for name in previous.union(next).sorted() {
                let live = root.appendingPathComponent(name)
                let staged = snapshot.appendingPathComponent(name)
                let from = next.contains(name) ? staged : live
                let to = next.contains(name) ? live : staged
                let flags = UInt32(previous.contains(name) && next.contains(name) ? RENAME_SWAP : RENAME_EXCL)
                var identity = stat()
                guard lstat(from.path, &identity) == 0, renamex_np(from.path, to.path, flags) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                applied.append((from, to, flags, identity.st_ino))
            }
        } catch {
            var restored = true
            for move in applied.reversed() {
                var current = stat()
                // A concurrent writer may have replaced a newly installed
                // entry. Keep its contents and the backup for recovery.
                if lstat(move.to.path, &current) != 0 || current.st_ino != move.inode
                    || renamex_np(move.to.path, move.from.path, move.flags) != 0
                {
                    restored = false
                }
            }
            if !restored { throw SharedFSStagingRecovery(directory: snapshot.deletingLastPathComponent()) }
            throw error
        }
    }

    private static func populate(from source: URL, to staging: URL, ignores: [String], files: SharedFileOperations)
        throws
    {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var failure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: Array(keys),
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw SharedFSError.sourceUnreadable(source) }
        var directories = [(source, staging)]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            let relative = relativePath(from: source, to: url)
            if isIgnored(relative, patterns: ignores) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let target = staging.appendingPathComponent(relative)
            if values.isSymbolicLink == true || values.isRegularFile == true {
                try files.cloneOrCopy(from: url, to: target)
            } else if values.isDirectory == true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                directories.append((url, target))
            } else {
                // Sockets and devices cannot be represented by this file-copy path.
                throw POSIXError(.ENOTSUP)
            }
        }
        if let failure { throw failure }
        // Apply directory modes, xattrs and times after creating children.
        for (src, dst) in directories.reversed() {
            try SharedFileOperations.copyMetadata(from: src, to: dst)
        }
    }

    static func loadIgnorePatterns(from root: URL) throws -> [String] {
        for name in [".dockerignore", ".syncignore"] {
            do {
                return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
        }
        return []
    }

    static func isIgnored(_ relative: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            // Simple glob via fnmatch(3) — handles *, ?, [abc], ** via FNM_PATHNAME.
            if fnmatch(pattern, relative, FNM_PATHNAME) == 0 { return true }
            // Also match basename for patterns without slash (like .git).
            if !pattern.contains("/"),
                fnmatch(pattern, (relative as NSString).lastPathComponent, 0) == 0
            {
                return true
            }
        }
        return false
    }

    /// Reverse `build` — copy every changed/new file in the view back into
    /// the source. Returns the list of files that were written (caller can
    /// decide on conflict policy).
    public static func syncToSource(view root: URL, source: URL) throws -> [URL] {
        var changed: [URL] = []
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        var failure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw SharedFSError.sourceUnreadable(root) }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let target = source.appendingPathComponent(relativePath(from: root, to: url))
            guard target.resolvingSymlinksInPath().standardizedFileURL.path == target.path else { continue }
            if FileManager.default.fileExists(atPath: target.path),
                try ChunkHash.computeFile(url) == ChunkHash.computeFile(target)
            {
                continue
            }
            try withSharedFSStaging(beside: target) { staging in
                try SharedFileOperations.native.cloneOrCopy(from: url, to: staging)
                guard rename(staging.path, target.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            changed.append(target)
        }
        if let failure { throw failure }
        return changed
    }

    /// Recursively delete the view (cheap — no per-chunk unlinking).
    public func destroy() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Total bytes of all regular files in the view (no symlink following).
    public func size() -> UInt64 {
        var total: UInt64 = 0
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: .skipsHiddenFiles)
        else { return 0 }
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size ?? 0)
            }
        }
        return total
    }
}

/// Stable identifier for a view (used as the JSON `id`).
public struct ViewID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ raw: String) { self.value = raw }

    public static func generate() -> ViewID {
        ViewID(String(UUID().uuidString.prefix(12)))
    }

    public var description: String { value }
}

func relativePath(from root: URL, to file: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    let fileComponents = file.standardizedFileURL.pathComponents
    if fileComponents.count >= rootComponents.count,
        Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    {
        return fileComponents[rootComponents.count...].joined(separator: "/")
    }
    return file.lastPathComponent
}

/// Darwin's clone and copyfile both preserve file metadata. copyfile streams
/// data when cloning is unavailable, including across filesystems.
struct SharedFileOperations: Sendable {
    let clone: @Sendable (URL, URL) -> Bool
    let copy: @Sendable (URL, URL) throws -> Void

    static let native = Self(
        clone: { clonefile($0.path, $1.path, UInt32(CLONE_NOFOLLOW)) == 0 },
        copy: { src, dst in
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
            guard copyfile(src.path, dst.path, nil, flags) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        })

    func cloneOrCopy(from src: URL, to dst: URL) throws {
        if !clone(src, dst) { try copy(src, dst) }
    }

    static func copyMetadata(from src: URL, to dst: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
        guard copyfile(src.path, dst.path, nil, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public enum SharedFSError: Error, Sendable {
    case sourceUnreadable(URL)
    case clonefileUnavailable
    case daemonUnavailable
    case invalidResponse(String)
}
