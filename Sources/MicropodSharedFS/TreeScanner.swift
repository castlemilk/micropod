import Foundation

/// Walks a source tree into a `FileManifest`.
///
/// Hashing every file every run costs ~70ms per 5k files, which is affordable
/// but pure waste when nothing moved. So a previous manifest is consulted
/// first: an entry whose kind/size/mtime/mode all match is carried over with
/// its recorded digest and never re-read. Only genuinely-suspect files are
/// hashed, which makes a no-op sync a stat walk (~13ms per 5k files).
public struct TreeScanner: Sendable {
    /// Directory names never worth shipping into a build container. `.git` in
    /// particular is large, churns constantly, and would dominate every diff.
    public static let defaultExcludes: Set<String> = [
        ".git", ".hg", ".svn", ".DS_Store", ".build", "node_modules/.cache",
    ]

    public let excludes: Set<String>
    /// When true, every file is hashed regardless of stat — slower, but immune
    /// to a filesystem that reports coarse or wrong mtimes.
    public let alwaysHash: Bool

    public init(excludes: Set<String> = TreeScanner.defaultExcludes, alwaysHash: Bool = false) {
        self.excludes = excludes
        self.alwaysHash = alwaysHash
    }

    public func scan(_ source: URL, reusing previous: FileManifest = FileManifest()) throws
        -> FileManifest
    {
        // Standardized so the enumerator's URLs and the root share a spelling
        // (macOS reports /private/var for /var). Only the *file* side must
        // stay unresolved — see relativePath.
        let root = source.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw SharedFSError.sourceUnreadable(root)
        }

        var manifest = FileManifest()
        let reusable = previous.version == FileManifest.currentVersion ? previous.entries : [:]

        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in true })
        else {
            throw SharedFSError.sourceUnreadable(root)
        }

        for case let url as URL in enumerator {
            let relative = Self.relativePath(from: root, to: url)
            if relative.isEmpty { continue }
            if shouldExclude(relative) {
                // Prune the whole subtree, not just the directory entry —
                // descending into .git to discard each file is most of the walk.
                enumerator.skipDescendants()
                continue
            }
            guard let entry = try scanEntry(url: url, relative: relative, reusable: reusable) else {
                continue
            }
            manifest.entries[relative] = entry
        }
        return manifest
    }

    private func scanEntry(
        url: URL, relative: String, reusable: [String: ManifestEntry]
    ) throws -> ManifestEntry? {
        // lstat, not stat: a symlink is shipped as a symlink, and following it
        // would both duplicate content and risk escaping the tree.
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }

        let mode = UInt16(info.st_mode & 0o7777)
        let mtimeNanos =
            Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)

        if (info.st_mode & S_IFMT) == S_IFDIR {
            return ManifestEntry(
                kind: .directory, size: 0, mtimeNanos: mtimeNanos, digest: "", mode: mode)
        }

        if (info.st_mode & S_IFMT) == S_IFLNK {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            let digest = (try? ChunkHash.compute(Data(target.utf8)))?.value ?? ""
            return ManifestEntry(
                kind: .symlink, size: UInt64(info.st_size), mtimeNanos: mtimeNanos,
                digest: digest, mode: mode)
        }

        guard (info.st_mode & S_IFMT) == S_IFREG else {
            // Sockets, fifos, devices: nothing a build container needs, and
            // tar would either fail or create something surprising.
            return nil
        }

        let candidate = ManifestEntry(
            kind: .file, size: UInt64(info.st_size), mtimeNanos: mtimeNanos, digest: "",
            mode: mode)

        if !alwaysHash, let before = reusable[relative], before.kind == .file,
            candidate.looksUnchanged(comparedTo: before)
        {
            return ManifestEntry(
                kind: .file, size: candidate.size, mtimeNanos: candidate.mtimeNanos,
                digest: before.digest, mode: mode)
        }

        let digest = (try? ChunkHash.computeFile(url))?.value ?? ""
        return ManifestEntry(
            kind: .file, size: candidate.size, mtimeNanos: mtimeNanos, digest: digest, mode: mode)
    }

    func shouldExclude(_ relative: String) -> Bool {
        if excludes.contains(relative) { return true }
        let components = relative.split(separator: "/").map(String.init)
        // A bare name in the exclude set matches at any depth (".git"), while
        // one containing a slash only matches that exact relative path.
        for exclude in excludes where !exclude.contains("/") {
            if components.contains(exclude) { return true }
        }
        for exclude in excludes where exclude.contains("/") {
            if relative == exclude || relative.hasPrefix(exclude + "/") { return true }
        }
        return false
    }

    /// The path of `file` relative to `root`.
    ///
    /// Uses the URL's **raw** components. `standardizedFileURL` resolves
    /// symlinks for file URLs, which would rewrite `link.txt` to its target's
    /// path — the link would then be recorded under the target's name and the
    /// target recorded twice. The root is matched in both its literal and
    /// symlink-resolved spellings because macOS hands out `/var/...` for what
    /// is really `/private/var/...` and the enumerator may report either.
    /// The path of `file` relative to `root`.
    ///
    /// `standardizedFileURL` — never `resolvingSymlinksInPath()`. Both bring
    /// the enumerator's `/private/var/...` and the root's `/var/...` into one
    /// spelling, but resolution also rewrites a symlink to its target, so
    /// `link.txt` would be recorded as `real.txt`: the link vanishes from the
    /// manifest and the target is written twice.
    static func relativePath(from root: URL, to file: URL) -> String {
        let fileComponents = file.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
            Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return ""
        }
        return fileComponents[rootComponents.count...].joined(separator: "/")
    }
}
