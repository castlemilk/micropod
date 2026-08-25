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
    public let createdAt: Date

    public init(id: ViewID, source: URL, root: URL, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.root = root
        self.createdAt = createdAt
    }

    /// Build a new view: recursively clone every regular file from `source`
    /// into `root` (preserving relative paths). Hardlinks/clones share
    /// blocks on APFS; we use `clonefile(2)` so writes inside the view
    /// don't touch the source.
    public static func build(source: URL, root: URL) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [],
                errorHandler: { _, _ in true })
        else {
            throw SharedFSError.sourceUnreadable(source)
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey,
            ])
            let relative = relativePath(from: source, to: url)
            let target = root.appendingPathComponent(relative)
            if values.isDirectory == true {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try cloneOrCopy(from: url, to: target)
            }
        }
    }

    /// Reverse `build` — copy every changed/new file in the view back into
    /// the source. Returns the list of files that were written (caller can
    /// decide on conflict policy).
    public static func syncToSource(view root: URL, source: URL) throws -> [URL] {
        var changed: [URL] = []
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [],
                errorHandler: { _, _ in true })
        else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = relativePath(from: root, to: url)
            let target = source.appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: target.path) {
                try cloneOrCopy(from: url, to: target)
                changed.append(target)
                continue
            }
            let srcData = try Data(contentsOf: target)
            let viewData = try Data(contentsOf: url)
            if srcData != viewData {
                try viewData.write(to: target, options: .atomic)
                changed.append(target)
            }
        }
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

private func relativePath(from root: URL, to file: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    let fileComponents = file.standardizedFileURL.pathComponents
    if fileComponents.count >= rootComponents.count,
        Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    {
        return fileComponents[rootComponents.count...].joined(separator: "/")
    }
    return file.lastPathComponent
}

private func cloneOrCopy(from src: URL, to dst: URL) throws {
    try FileManager.default.createDirectory(
        at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Prefer clonefile (APFS CoW) when available — free for the file on
    // the same APFS volume.
    src.withUnsafeFileSystemRepresentation { srcPath in
        dst.withUnsafeFileSystemRepresentation { dstPath in
            guard let srcPath, let dstPath else { return }
            let result = clonefile(srcPath, dstPath, 0)
            if result == 0 { return }
        }
    }
    // Fallback: copy contents.
    let data = try Data(contentsOf: src)
    try data.write(to: dst, options: .atomic)
}

/// `clonefile(2)` is a libc syscall on macOS. The Swift import is missing,
/// so we dlopen/dlsym it from `libc`. Marked `nonisolated(unsafe)` since the
/// underlying libc function is reentrant and thread-safe by contract. The
/// fallback returns `-1` so callers can always invoke it and fall back to
/// copying the file contents on error.
private nonisolated(unsafe) let clonefile:
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32) -> Int32 = {
        typealias CloneFn =
            @convention(c) (
                UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32
            ) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
            let sym = dlsym(handle, "clonefile")
        else {
            let fallback: CloneFn = { _, _, _ in -1 }
            return fallback
        }
        return unsafeBitCast(sym, to: CloneFn.self)
    }()

public enum SharedFSError: Error, Sendable {
    case sourceUnreadable(URL)
    case clonefileUnavailable
    case daemonUnavailable
    case invalidResponse(String)
}
