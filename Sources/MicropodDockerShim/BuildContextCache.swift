import Foundation
import MicropodSharedFS

/// Content-addressed build-context cache (the "cache re-use" half of fast
/// rebuilds).
///
/// Every `POST /build` through the shim otherwise pays the same fixed tax:
/// tar upload → write `context.tar` → `/usr/bin/tar` extract into a fresh
/// UUID dir → `rm -rf`. On a 100 MB / 2000-file context that tax measured
/// ~2.3 s while the warm builder itself needs ~0.1 s for a no-change
/// rebuild. This cache keys extracted contexts by a **content tree-hash**
/// (paths + file bytes + symlink targets; mtimes and tar metadata ignored)
/// so identical rebuilds — `compose up --build` with no changes, CI
/// retries — skip staging entirely:
///
///  1. Stream-parse the tar headers from the in-memory body, hashing file
///     contents on the fly (no disk I/O) → tree-hash.
///  2. Hit: APFS-`clonefile` the retained extracted dir to a fresh build dir
///     (O(1), CoW) and hand it to the builder. The builder only ever reads
///     the context, and the clone isolates the build from the cache entry.
///  3. Miss: stage as usual, then clone the extracted tree into the cache
///     for next time (LRU-capped, in-use builds pin their entry).
///
/// Only identity (uncompressed) tarballs are gated: hashing a gzip body
/// would require inflating it first, and clients that compress are rare
/// (the Docker CLI sends identity). Gzip bodies still get the streaming
/// extract (no `.tar` disk write) — they just always stage.
///
/// Filenames stay human-readable (`<tree-hash>/context`); eviction is
/// oldest-first by entry atime with in-use pinning, mirroring the chunk
/// store's GC policy.
enum BuildContextHashError: Error {
    case emptyBody
    case truncated
    case corrupt(String)
    case tooManyEntries
}

enum BuildContextHasher {
    private static let blockSize = 512
    private static let maxEntries = 500_000

    /// Canonical content tree-hash of an identity tarball: hex sha256 over
    /// `v1\n` + sorted `kind path\0digest\n` lines. Deterministic across
    /// mtime changes, entry order, and tar-variant metadata.
    static func treeHash(tarData data: Data) throws -> String {
        try treeManifest(tarData: data).treeHash
    }

    /// Tree-hash plus the per-file manifest (path → content digest + size).
    /// File digests are chunk-store content hashes, so manifests quantify
    /// cross-context sharing (see `BuildCacheStore.sharedBytes`).
    static func treeManifest(tarData data: Data) throws -> (
        treeHash: String, files: [BuildFileEntry]
    ) {
        let entries = try collectEntries(tarData: data)
        var canonical = Data("v1\n".utf8)
        for entry in entries.sorted() {
            canonical.append(contentsOf: "\(entry.kind) \(entry.path)\0\(entry.digest)\n".utf8)
        }
        let treeHash = try ChunkHash.compute(canonical).value
        let files = entries.compactMap { entry -> BuildFileEntry? in
            guard entry.kind == "f" else { return nil }
            return BuildFileEntry(path: entry.path, sha256: entry.digest, size: entry.size)
        }
        return (treeHash, files)
    }

    private struct CollectedEntry: Comparable {
        let kind: Character
        let path: String
        let digest: String
        /// File content bytes (0 for non-files).
        let size: UInt64

        static func < (lhs: CollectedEntry, rhs: CollectedEntry) -> Bool {
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.digest < rhs.digest
        }
    }

    private static func collectEntries(tarData data: Data) throws -> [CollectedEntry] {
        guard !data.isEmpty else { throw BuildContextHashError.emptyBody }
        var entries: [CollectedEntry] = []
        var offset = 0
        var pendingLongName: String?
        var pendingLongLink: String?

        while true {
            guard offset + blockSize <= data.count else {
                // Trailing partial block: some clients omit the end marker.
                if offset == data.count { break }
                throw BuildContextHashError.truncated
            }
            let header = data[offset..<(offset + blockSize)]
            if header.allSatisfy({ $0 == 0 }) { break }
            guard entries.count < maxEntries else { throw BuildContextHashError.tooManyEntries }

            let name = readString(header, 0, 100)
            let size = try readOctal(header, 124, 12, context: "size")
            let typeflag = header[header.startIndex + 156]
            let typeChar: Character =
                typeflag == 0 ? "0" : Character(UnicodeScalar(typeflag))
            var linkName = readString(header, 157, 100)
            // USTAR prefix (directories split across name/prefix).
            let prefix = readString(header, 345, 155)
            var fullName = prefix.isEmpty ? name : prefix + "/" + name
            if let long = pendingLongName {
                fullName = long
                pendingLongName = nil
            }
            if let longLink = pendingLongLink {
                linkName = longLink
                pendingLongLink = nil
            }

            let dataStart = offset + blockSize
            let padded = (size + blockSize - 1) / blockSize * blockSize
            guard size >= 0, dataStart + padded <= data.count else {
                throw BuildContextHashError.truncated
            }

            switch typeChar {
            case "0", "\0":
                let content = data[dataStart..<(dataStart + size)]
                let digest = try ChunkHash.compute(Data(content)).value
                entries.append(
                    CollectedEntry(kind: "f", path: fullName, digest: digest, size: UInt64(size)))
            case "5":
                entries.append(CollectedEntry(kind: "d", path: fullName, digest: "", size: 0))
            case "1", "2":
                entries.append(
                    CollectedEntry(
                        kind: typeChar == "2" ? "l" : "h", path: fullName,
                        digest: linkName, size: 0))
            case "L":
                pendingLongName = readLongEntry(data, at: dataStart, size: size)
            case "K":
                pendingLongLink = readLongEntry(data, at: dataStart, size: size)
            case "x", "g":
                break  // PAX extended headers: metadata only, skip.
            default:
                // Char/block devices, fifos, vendor extensions: identity is
                // kind + path (no stable content to hash).
                entries.append(
                    CollectedEntry(kind: "s", path: fullName, digest: String(typeChar), size: 0))
            }
            offset = dataStart + padded
        }

        return entries
    }

    private static func readString(_ header: Data.SubSequence, _ offset: Int, _ length: Int) -> String {
        let base = header.startIndex
        let slice = header[(base + offset)..<(base + offset + length)]
        let bytes = slice.prefix(while: { $0 != 0 })
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private static func readOctal(
        _ header: Data.SubSequence, _ offset: Int, _ length: Int, context: String
    ) throws -> Int {
        let base = header.startIndex
        let slice = header[(base + offset)..<(base + offset + length)]
        // Base-256 (bit 7 set) only appears for >8 GB members — never in a
        // build context; reject rather than misparse.
        if let first = slice.first, first & 0x80 != 0 {
            throw BuildContextHashError.corrupt("base-256 \(context)")
        }
        let text =
            String(bytes: slice, encoding: .utf8)?
            .trimmingCharacters(in: .init(charactersIn: "\0 "))
            ?? ""
        guard !text.isEmpty, let value = Int(text, radix: 8) else {
            if text.isEmpty {
                return 0
            }
            throw BuildContextHashError.corrupt("bad octal \(context): \(text)")
        }
        return value
    }

    private static func readLongEntry(_ data: Data, at start: Int, size: Int) -> String {
        guard size > 0, start + size <= data.count else { return "" }
        let bytes = data[start..<(start + size)].prefix(while: { $0 != 0 })
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

/// LRU-capped on-disk store of extracted build contexts keyed by tree-hash.
///
/// Layout: `<root>/<tree-hash>/context/` + `<root>/<tree-hash>/manifest.json`
/// (per-file content digests in chunk-store addressing — see
/// `BuildManifest`). Size accounting uses measured extracted bytes; eviction
/// is oldest-first by entry atime and never touches entries checked out by a
/// live build (in-use pinning).
actor BuildContextCache {
    /// Standard location, honoring `MICROPOD_BUILD_CACHE_*` (see
    /// `BuildCacheStore`).
    static func standard() -> BuildContextCache {
        BuildContextCache(
            root: BuildCacheStore.standardRoot(), maxBytes: BuildCacheStore.capBytes(),
            disabled: BuildCacheStore.disabled())
    }

    let root: URL
    private let maxBytes: UInt64
    private let disabled: Bool
    private var inUse: [String: Int] = [:]
    private var indexedBytes: UInt64 = 0

    init(root: URL, maxBytes: UInt64 = 5 << 30, disabled: Bool = false) {
        self.root = root
        self.maxBytes = maxBytes
        self.disabled = disabled
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.indexedBytes = Self.diskUsage(root: root)
    }

    var isDisabled: Bool { disabled }

    /// Clone the cached entry to `dest` (which must not contain live data —
    /// an empty dir is removed first) and pin it. Returns false on any miss
    /// or clone failure; the caller then takes the stage-from-scratch path.
    /// Every `true` return must be paired with `release(_:)`.
    func checkout(treeHash: String, dest: URL) -> Bool {
        guard !disabled, isHexDigest(treeHash) else { return false }
        let entry = root.appendingPathComponent(treeHash, isDirectory: true)
        let context = entry.appendingPathComponent("context", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: context.path, isDirectory: &isDir),
            isDir.boolValue
        else { return false }
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard cloneDirectory(from: context, to: dest) else { return false }
        inUse[treeHash, default: 0] += 1
        touch(entry: entry)
        return true
    }

    func release(_ treeHash: String) {
        guard let count = inUse[treeHash] else { return }
        if count <= 1 {
            inUse.removeValue(forKey: treeHash)
        } else {
            inUse[treeHash] = count - 1
        }
    }

    /// Backfill a missing manifest (entries retained before manifests
    /// existed). Never overwrites: first writer wins, keeping the method
    /// idempotent under concurrent identical builds.
    func ensureManifest(treeHash: String, files: [BuildFileEntry], tarBytes: Int) {
        guard !disabled, isHexDigest(treeHash) else { return }
        let manifestURL = root.appendingPathComponent(treeHash, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let manifest = BuildManifest(treeHash: treeHash, files: files, tarBytes: tarBytes)
        let data = (try? JSONEncoder().encode(manifest)) ?? Data()
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Retain an extracted `contextDir` under `treeHash` (replacing any
    /// previous entry), then evict oldest-first back under the byte cap.
    /// `files` is the tar manifest (chunk-store content digests) persisted
    /// as `manifest.json` for cross-context sharing analysis.
    func store(treeHash: String, contextDir: URL, tarBytes: Int, files: [BuildFileEntry] = []) {
        guard !disabled, isHexDigest(treeHash) else { return }
        let entry = root.appendingPathComponent(treeHash, isDirectory: true)
        let context = entry.appendingPathComponent("context", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: entry.path) {
                // Re-store (e.g. clone-fallback path): drop the old bytes
                // first so accounting never double-counts the entry.
                let old = entryBytes(entry: entry)
                indexedBytes = indexedBytes >= old ? indexedBytes - old : 0
                try? FileManager.default.removeItem(at: entry)
            }
            try FileManager.default.createDirectory(
                at: entry, withIntermediateDirectories: true)
            // CoW clone keeps the retain itself O(1); fall back to a copy so
            // a non-APFS builds volume still caches correctly.
            if !cloneDirectory(from: contextDir, to: context) {
                try FileManager.default.copyItem(at: contextDir, to: context)
            }
            let bytes = directoryBytes(context)
            let manifest = BuildManifest(
                treeHash: treeHash, files: files, tarBytes: tarBytes)
            let manifestData = (try? JSONEncoder().encode(manifest)) ?? Data()
            try? manifestData.write(
                to: entry.appendingPathComponent("manifest.json"), options: .atomic)
            indexedBytes += bytes
            touch(entry: entry)
            evictIfNeeded()
            fputs(
                "[shim] build context cached \(treeHash.prefix(12)) (\(bytes) bytes extracted from \(tarBytes) tar bytes, \(files.count) files)\n",
                stderr)
        } catch {
            fputs("[shim] build context store failed for \(treeHash.prefix(12)): \(error)\n", stderr)
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func entryCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0
    }

    func stats() -> (entries: Int, bytes: UInt64, pinned: Int) {
        (entryCount(), indexedBytes, inUse.count)
    }

    // MARK: - Private

    private func evictIfNeeded() {
        guard indexedBytes > maxBytes else { return }
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles)) ?? []
        let entries =
            contents
            .compactMap { url -> (URL, Date)? in
                guard url.hasDirectoryPath || isHexDigest(url.lastPathComponent) else { return nil }
                let date =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap { $0.contentModificationDate } ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 < $1.1 }
        for (url, _) in entries {
            if indexedBytes <= maxBytes { break }
            let hash = url.lastPathComponent
            if (inUse[hash] ?? 0) > 0 { continue }
            let bytes = entryBytes(entry: url)
            try? FileManager.default.removeItem(at: url)
            indexedBytes = indexedBytes >= bytes ? indexedBytes - bytes : 0
            fputs("[shim] build context evicted \(hash.prefix(12)) (\(bytes) bytes)\n", stderr)
        }
        if indexedBytes > maxBytes {
            fputs(
                "[shim] build context cache over cap (\(indexedBytes) > \(maxBytes)): all remaining entries pinned\n",
                stderr)
        }
    }

    private func entryBytes(entry: URL) -> UInt64 {
        // Prefer the manifest's unique content bytes; fall back to measuring
        // the retained tree for entries that predate manifests. Both exclude
        // the sidecar files, matching what store() adds — otherwise eviction
        // over-subtracts and the cap silently stops being enforced.
        if let manifest = BuildCacheStore.readManifest(entry: entry),
            !manifest.files.isEmpty
        {
            return manifest.contentBytes
        }
        return directoryBytes(entry.appendingPathComponent("context", isDirectory: true))
    }

    private func touch(entry: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: entry.path)
    }

    private static func diskUsage(root: URL) -> UInt64 {
        directoryBytes(root)
    }
}

private func directoryBytes(_ root: URL) -> UInt64 {
    guard
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: UInt64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true
        else { continue }
        total += UInt64(values.fileSize ?? 0)
    }
    return total
}

private func isHexDigest(_ text: String) -> Bool {
    text.count == 64 && text.allSatisfy { $0.isHexDigit }
}

/// APFS directory `clonefile(2)` via libc (the Swift import is missing, same
/// as `SharedView`). One syscall, CoW whole tree. Returns false on any
/// failure (different volume, non-APFS) so callers fall back to copy/extract.
private func cloneDirectory(from src: URL, to dst: URL) -> Bool {
    var success = false
    src.withUnsafeFileSystemRepresentation { srcPtr in
        dst.withUnsafeFileSystemRepresentation { dstPtr in
            guard let s = srcPtr, let d = dstPtr else { return }
            success = clonefile(s, d, 0) == 0
        }
    }
    return success
}

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
