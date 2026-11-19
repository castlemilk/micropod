import CryptoKit
import Darwin
import Foundation

/// Content-addressed file blocks. Names are always the SHA-256 of decoded
/// bytes. A store owns its index, in-flight references and cache mutations.
public final class ChunkStore: @unchecked Sendable {
    public let root: URL
    public let blockSize: Int
    /// Store LZ4 frames for eligible blocks. Env `MICROPOD_SHAREDFS_TRANSCODE=1`.
    public let transcodeEnabled: Bool

    /// Minimum block size worth transcoding (Cloudflare's 4 KiB rule: below
    /// this the per-object overhead exceeds the saving).
    public static let transcodeMinBytes = 4096
    /// Store the frame only when it saves at least this fraction (0.9 =
    /// 10%+). Incompressible blocks (media, archives) stay identity.
    public static let transcodeMaxRatio = 0.9

    // MARK: - Indexed metadata (no `du`)
    private let lock = NSLock()
    private let writeBlock: @Sendable (Data, URL) throws -> Void
    private var _indexedSize: UInt64 = 0
    /// Stored (on-disk) bytes per chunk — what the cap accounts.
    private var sizes: [String: UInt64] = [:]
    /// Identity (logical) bytes per chunk — what serves would read.
    /// Equals stored size for identity/plain chunks.
    private var contentSizes: [String: UInt64] = [:]
    private var atimes: [String: Date] = [:]
    private var refCounts: [String: Int] = [:]

    /// Synchronous indexed size — sum of chunk file sizes via metadata, no filesystem `du`.
    public var indexedSize: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _indexedSize
    }

    /// Bytes transcoding saved (identity total minus stored total). Zero
    /// when disabled or on incompressible data.
    public var transcodedBytesSaved: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        resolveContentSizes()
        let content = contentSizes.values.reduce(0, +)
        let stored = sizes.values.reduce(0, +)
        return content >= stored ? content - stored : 0
    }

    /// Chunks currently stored as LZ4 frames.
    public var transcodedChunks: Int {
        lock.lock()
        defer { lock.unlock() }
        resolveContentSizes()
        var count = 0
        for (key, content) in contentSizes {
            if content > (sizes[key] ?? content) { count += 1 }
        }
        return count
    }

    /// Alias for daemon integration (`sharedCacheSize` via store index).
    public var sharedCacheSize: UInt64 { indexedSize }

    public convenience init(root: URL, blockSize: Int = 256 * 1024, transcodeEnabled: Bool? = nil) throws {
        try self.init(
            root: root, blockSize: blockSize,
            transcodeEnabled: transcodeEnabled
                ?? (ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_TRANSCODE"] == "1"),
            writeBlock: { try $0.write(to: $1, options: .atomic) })
    }

    init(root: URL, blockSize: Int, transcodeEnabled: Bool, writeBlock: @escaping @Sendable (Data, URL) throws -> Void)
        throws
    {
        guard (1...ChunkRepresentation.maxBlockSize).contains(blockSize) else { throw POSIXError(.EINVAL) }
        self.root = root
        self.blockSize = blockSize
        self.transcodeEnabled = transcodeEnabled
        self.writeBlock = writeBlock
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try rebuildIndex()
    }

    private func rebuildIndex() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            let hash = ChunkHash(unchecked: name)
            guard hash.isValidAddress, name == hash.value else { continue }
            let url = chunkPath(hash)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? UInt64
            else { continue }
            sizes[name] = size
            _indexedSize += size
            atimes[name] = attrs[.modificationDate] as? Date ?? .distantPast
        }
    }

    /// Restart only indexes file metadata. Defer inspecting representations
    /// until a caller asks for compression statistics. Ordinary raw blocks
    /// need just a prefix read, and each indexed object is measured once.
    private func resolveContentSizes() {
        for (name, size) in sizes where contentSizes[name] == nil {
            let hash = ChunkHash(unchecked: name)
            var logicalSize = size
            if let handle = try? Self.openRegularFile(chunkPath(hash)) {
                defer { try? handle.close() }
                if let prefix = try? handle.read(upToCount: 4), ChunkRepresentation.hasMagic(prefix),
                    let bytes = try? readBlock(hash)
                {
                    logicalSize = UInt64(bytes.count)
                }
            }
            contentSizes[name] = logicalSize
        }
    }

    public enum TranscodeError: Error, Sendable {
        case corruptFrame(String)
    }

    private static func openRegularFile(_ url: URL, followLinks: Bool = false) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followLinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard try fileStatus(handle).st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        return handle
    }

    private static func fileStatus(_ handle: FileHandle) throws -> stat {
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private func storedBlock(_ hash: ChunkHash) throws -> Data {
        guard hash.isValidAddress else { throw TranscodeError.corruptFrame("invalid chunk address") }
        let handle = try Self.openRegularFile(chunkPath(hash))
        defer { try? handle.close() }
        let size = try Self.fileStatus(handle).st_size
        guard size > 0, size <= ChunkRepresentation.maxStoredSize else {
            throw TranscodeError.corruptFrame("invalid stored size")
        }
        guard let bytes = try handle.read(upToCount: Int(size) + 1), bytes.count == size else {
            throw TranscodeError.corruptFrame("stored size changed")
        }
        return bytes
    }

    func readBlock(_ hash: ChunkHash) throws -> Data {
        try ChunkRepresentation.decode(storedBlock(hash), expected: hash)
    }

    /// Verify dedup hits as well as reads. Publication, accounting and the
    /// operation pin share one lock with GC. Concurrent writers charge once.
    private func storeAndPin(_ block: Data) throws -> ChunkHash {
        let hash = try ChunkHash.compute(block)
        let path = chunkPath(hash)
        try lock.withLock {
            let storedSize: UInt64
            do {
                let stored = try storedBlock(hash)
                _ = try ChunkRepresentation.decode(stored, expected: hash)
                storedSize = UInt64(stored.count)
            } catch let error as POSIXError where error.code == .ENOENT {
                let payload = ChunkRepresentation.encode(block, compress: transcodeEnabled)
                try writeBlock(payload, path)
                storedSize = UInt64(payload.count)
            }
            _indexedSize -= sizes[hash.value] ?? 0
            sizes[hash.value] = storedSize
            _indexedSize += storedSize
            contentSizes[hash.value] = UInt64(block.count)
            let now = Date()
            atimes[hash.value] = now
            refCounts[hash.value, default: 0] += 1
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
        }
        return hash
    }

    public func ingest(_ data: Data) throws -> [ChunkHash] {
        var hashes: [ChunkHash] = []
        defer { for hash in hashes { decrementRefCount(hash) } }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = offset + min(blockSize, data.endIndex - offset)
            try autoreleasepool { hashes.append(try storeAndPin(Data(data[offset..<end]))) }
            offset = end
        }
        return hashes
    }

    /// The chunk list, length and digest all describe the same read of the
    /// same descriptor. A path replaced by rename can finish on the old inode.
    /// An in-place change fails the operation, including a growing source.
    public func ingestFileManifest(_ source: URL) throws -> ChunkFileManifest {
        let handle = try Self.openRegularFile(source, followLinks: true)
        defer { try? handle.close() }
        let before = try Self.fileStatus(handle)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw POSIXError(.EINVAL) }
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        var hashes: [ChunkHash] = []
        defer { for hash in hashes { decrementRefCount(hash) } }
        let length = UInt64(before.st_size)
        while byteCount < length {
            try autoreleasepool {
                let count = Int(min(UInt64(blockSize), length - byteCount))
                guard let block = try handle.read(upToCount: count), block.count == count else {
                    throw POSIXError(.ESTALE)
                }
                hashes.append(try storeAndPin(block))
                hasher.update(data: block)
                byteCount += UInt64(block.count)
            }
        }
        let after = try Self.fileStatus(handle)
        guard before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw POSIXError(.ESTALE) }
        return ChunkFileManifest(chunks: hashes, byteCount: byteCount, digest: ChunkHash(digest: hasher.finalize()))
    }

    public func ingestFile(_ source: URL) throws -> (hashes: [ChunkHash], digest: ChunkHash) {
        let manifest = try ingestFileManifest(source)
        return (manifest.chunks, manifest.digest)
    }

    /// Compatibility with the original API, where an empty list meant delete.
    @discardableResult
    public func materialise(_ hashes: [ChunkHash], into target: URL) throws -> Bool {
        if hashes.isEmpty { return try materialise(.deletion, into: target) }
        try writeFile(hashes, manifest: nil, into: target)
        return true
    }

    @discardableResult
    public func materialise(_ entry: ChunkEntry, into target: URL) throws -> Bool {
        switch entry {
        case .deletion:
            if unlink(target.path) != 0, errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        case .file(let manifest):
            guard manifest.version == 1, manifest.digest.isValidAddress else {
                throw TranscodeError.corruptFrame("invalid file manifest")
            }
            try writeFile(manifest.chunks, manifest: manifest, into: target)
        }
        return true
    }

    private func writeFile(_ hashes: [ChunkHash], manifest: ChunkFileManifest?, into target: URL) throws {
        guard hashes.allSatisfy(\.isValidAddress) else { throw TranscodeError.corruptFrame("invalid chunk address") }
        lock.withLock { for hash in hashes { refCounts[hash.value, default: 0] += 1 } }
        defer { for hash in hashes { decrementRefCount(hash) } }
        try withSharedFSStaging(beside: target) { staging in
            let fd = open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o666)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            // Keep the access controls of a regular file being replaced.
            // Access the final link itself so restoration can replace a dangling link.
            var previous = stat()
            if lstat(target.path, &previous) == 0, previous.st_mode & S_IFMT == S_IFREG {
                guard fchmod(fd, previous.st_mode & 0o777) == 0,
                    copyfile(target.path, staging.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_NOFOLLOW)) == 0
                else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            var hasher = SHA256()
            var count: UInt64 = 0
            for hash in hashes {
                try autoreleasepool {
                    let bytes = try readBlock(hash)
                    if let manifest {
                        guard UInt64(bytes.count) <= manifest.byteCount - count else {
                            throw TranscodeError.corruptFrame("file length mismatch")
                        }
                        hasher.update(data: bytes)
                        count += UInt64(bytes.count)
                    }
                    try handle.write(contentsOf: bytes)
                }
            }
            if let manifest {
                guard count == manifest.byteCount, ChunkHash(digest: hasher.finalize()) == manifest.digest else {
                    throw TranscodeError.corruptFrame("file manifest mismatch")
                }
            }
            try handle.synchronize()
            try handle.close()
            guard rename(staging.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    public func chunkPath(_ hash: ChunkHash) -> URL {
        root.appendingPathComponent(hash.value)
    }

    public func exists(_ hash: ChunkHash) -> Bool {
        hash.isValidAddress && FileManager.default.fileExists(atPath: chunkPath(hash).path)
    }

    /// Global Has — content-addressed existence check. Updates atime for LRU.
    @discardableResult
    public func has(_ hash: ChunkHash) -> Bool {
        guard hash.isValidAddress else { return false }
        return lock.withLock {
            let path = chunkPath(hash)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                attrs[.type] as? FileAttributeType == .typeRegular
            else { return false }
            if sizes[hash.value] == nil, let size = attrs[.size] as? UInt64 {
                sizes[hash.value] = size
                _indexedSize += size
            }
            let now = Date()
            atimes[hash.value] = now
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
            return true
        }
    }

    /// Has alias for case-insensitive callers (spec calls it `Has`).
    public func Has(_ hash: ChunkHash) -> Bool { has(hash) }

    public func atime(for hash: ChunkHash) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return atimes[hash.value]
    }

    public func setAtime(_ hash: ChunkHash, _ date: Date) {
        guard hash.isValidAddress else { return }
        lock.lock()
        atimes[hash.value] = date
        lock.unlock()
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: chunkPath(hash).path)
    }

    public func touch(_ hash: ChunkHash) {
        guard hash.isValidAddress else { return }
        lock.lock()
        atimes[hash.value] = Date()
        lock.unlock()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: chunkPath(hash).path)
    }

    public func chunkSize(_ hash: ChunkHash) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return sizes[hash.value]
    }

    public func allChunkHashes() -> [ChunkHash] {
        lock.lock()
        let keys = Array(sizes.keys)
        lock.unlock()
        return keys.map { ChunkHash(unchecked: $0) }
    }

    public func refCount(for hash: ChunkHash) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return refCounts[hash.value] ?? 0
    }

    public func incrementRefCount(_ hash: ChunkHash) {
        lock.lock()
        refCounts[hash.value, default: 0] += 1
        lock.unlock()
    }

    public func decrementRefCount(_ hash: ChunkHash) {
        lock.lock()
        let c = (refCounts[hash.value] ?? 0) - 1
        if c <= 0 {
            refCounts.removeValue(forKey: hash.value)
        } else {
            refCounts[hash.value] = c
        }
        lock.unlock()
    }

    /// Remove a chunk if it exists (used by GC). No-op if already gone.
    public func remove(_ hash: ChunkHash) throws {
        guard hash.isValidAddress else { throw POSIXError(.EINVAL) }
        try lock.withLock {
            guard (refCounts[hash.value] ?? 0) == 0 else { throw POSIXError(.EBUSY) }
            if unlink(chunkPath(hash).path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _indexedSize -= sizes.removeValue(forKey: hash.value) ?? 0
            atimes.removeValue(forKey: hash.value)
            contentSizes.removeValue(forKey: hash.value)
        }
    }

    /// Best-effort free-space report in bytes (sparse, not exact).
    public func diskBytes() -> UInt64 {
        var total: UInt64 = 0
        let resourceValues = try? FileManager.default.attributesOfItem(atPath: root.path)
        if let attrs = resourceValues, let size = attrs[.systemSize] as? UInt64 {
            return size
        }
        return total
    }
}

extension Array where Element == ChunkHash {
    /// SHA256 of the concatenated hashes (a Merkle root) so we can detect
    /// corruption or version drift across the chunk list.
    public var combined: ChunkHash {
        var concat = Data()
        for hash in self { concat.append(hash.rawBytes) }
        return (try? ChunkHash.compute(concat)) ?? ChunkHash(unchecked: "")
    }
}
