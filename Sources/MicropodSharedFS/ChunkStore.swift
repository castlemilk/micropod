import Compression
import Foundation

/// Content-addressed chunk store backed by the host filesystem.
///
/// Each chunk is a single file at `root/<sha256>` — the hash IS the
/// filename, so dedup is implicit and free. APFS gives us free CoW across
/// hardlinks to the same chunk file (and `clonefile` for cheap per-view
/// copies).
///
/// Transcoding (Cloudflare Cache-Transcoding pattern): when enabled, eligible
/// blocks are stored LZ4-compressed behind a self-describing frame
/// ("MCZ1" magic + original size). Filenames stay `sha256(identity bytes)`,
/// so addressing and dedup are untouched by the representation — and files
/// without the magic (legacy, or incompressible blocks stored as-is) always
/// read back transparently. The frame is the storage encoding marker: tiers
/// and restarts never double-encode and never need a sidecar.
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
        lock.lock(); defer { lock.unlock() }
        return _indexedSize
    }

    /// Bytes transcoding saved (identity total minus stored total). Zero
    /// when disabled or on incompressible data.
    public var transcodedBytesSaved: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let content = contentSizes.values.reduce(0, +)
        let stored = sizes.values.reduce(0, +)
        return content >= stored ? content - stored : 0
    }

    /// Chunks currently stored as LZ4 frames.
    public var transcodedChunks: Int {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        for (key, content) in contentSizes {
            if content > (sizes[key] ?? content) { count += 1 }
        }
        return count
    }

    /// Alias for daemon integration (`sharedCacheSize` via store index).
    public var sharedCacheSize: UInt64 { indexedSize }

    public init(root: URL, blockSize: Int = 256 * 1024, transcodeEnabled: Bool? = nil) throws {
        self.root = root
        self.blockSize = blockSize
        if let transcodeEnabled {
            self.transcodeEnabled = transcodeEnabled
        } else {
            self.transcodeEnabled = ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_TRANSCODE"] == "1"
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rebuildIndex()
    }

    private func rebuildIndex() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        var total: UInt64 = 0
        var newSizes: [String: UInt64] = [:]
        var newContent: [String: UInt64] = [:]
        var newAtimes: [String: Date] = [:]
        for name in names {
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            // Only 64-char hex chunk names are part of index; ignore others.
            guard name.count == 64 else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? UInt64) ?? UInt64((attrs?[.size] as? Int) ?? 0)
            // Prefer stored atime if we have it, else use file modification date or now.
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
            newSizes[name] = size
            // Recover logical size for framed chunks from the frame header;
            // legacy/plain chunks are their own size.
            newContent[name] = Self.framedContentSize(at: url) ?? size
            newAtimes[name] = mtime
            total += size
        }
        lock.lock()
        self.sizes = newSizes
        self.contentSizes = newContent
        self.atimes = newAtimes
        self._indexedSize = total
        // refCounts start at 0; daemon increments for pinned views.
        lock.unlock()
    }

    // MARK: - Transcoding (LZ4 frames)

    public enum TranscodeError: Error, Sendable {
        case corruptFrame(String)
    }

    /// Frame magic + version. Header layout: magic[4] + BE u32 identity size.
    static let frameMagic = Data("MCZ1".utf8)
    static let frameHeaderSize = 8

    /// Identity size recorded in a framed file, or nil when not framed.
    /// Reads 8 bytes; used by rebuild (no full reads) and guarded by open
    /// failure (missing file → nil, caller decides).
    static func framedContentSize(at url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: frameHeaderSize),
            header.count == frameHeaderSize,
            header.prefix(4) == frameMagic
        else { return nil }
        var size: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &size) { header.copyBytes(to: $0, from: 4..<8) }
        return UInt64(UInt32(bigEndian: size))
    }

    /// Frame eligible identity bytes, or return nil to store as-is
    /// (too small, incompressible, or transcoding disabled).
    func transcodeEncode(_ block: Data) -> Data? {
        guard transcodeEnabled, block.count >= Self.transcodeMinBytes else { return nil }
        let bound = block.count + block.count / 255 + 16
        var output = Data(count: bound)
        let encoded: Int = output.withUnsafeMutableBytes { dst in
            block.withUnsafeBytes { src in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                return compression_encode_buffer(
                    d.assumingMemoryBound(to: UInt8.self), bound,
                    s.assumingMemoryBound(to: UInt8.self), block.count,
                    nil, COMPRESSION_LZ4)
            }
        }
        guard encoded > 0 else { return nil }
        var framed = Data()
        framed.append(Self.frameMagic)
        var be = UInt32(block.count).bigEndian
        withUnsafeBytes(of: &be) { framed.append(contentsOf: $0) }
        framed.append(output.prefix(encoded))
        guard Double(framed.count) < Double(block.count) * Self.transcodeMaxRatio else { return nil }
        return framed
    }

    /// Restore identity bytes: framed payloads decode, anything else passes
    /// through (legacy files, incompressible blocks). Throws on corrupt
    /// frames rather than serving bad bytes.
    static func transcodeDecode(_ stored: Data) throws -> Data {
        guard stored.count >= frameHeaderSize, stored.prefix(4) == frameMagic else {
            return stored
        }
        let size = stored[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
        let contentSize = Int(UInt32(bigEndian: size))
        guard contentSize > 0, contentSize <= 1 << 31 else {
            throw TranscodeError.corruptFrame("bad content size \(contentSize)")
        }
        var output = Data(count: contentSize)
        let decoded: Int = output.withUnsafeMutableBytes { dst in
            stored.withUnsafeBytes { src in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                return compression_decode_buffer(
                    d.assumingMemoryBound(to: UInt8.self), contentSize,
                    s.assumingMemoryBound(to: UInt8.self).advanced(by: frameHeaderSize),
                    stored.count - frameHeaderSize,
                    nil, COMPRESSION_LZ4)
            }
        }
        guard decoded == contentSize else {
            throw TranscodeError.corruptFrame("decoded \(decoded) of \(contentSize)")
        }
        return output
    }

    /// Read one chunk back as identity bytes (decode if framed).
    func readBlock(_ hash: ChunkHash) throws -> Data {
        let data = try Data(contentsOf: chunkPath(hash), options: .mappedIfSafe)
        return try Self.transcodeDecode(data)
    }

    /// Ingest a file's bytes, returning the ordered list of chunk hashes that
    /// now represent it. Idempotent: re-ingesting the same bytes is cheap (each
    /// block hashes to an existing chunk).
    public func ingest(_ data: Data) throws -> [ChunkHash] {
        guard !data.isEmpty else { return [] }
        var hashes: [ChunkHash] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + blockSize, data.count)
            let block = data.subdata(in: offset..<end)
            let hash = try ChunkHash.compute(block)
            let path = chunkPath(hash)
            let exists = FileManager.default.fileExists(atPath: path.path)
            if !exists {
                // Transcode when eligible: the filename stays the identity
                // hash; only the stored representation changes.
                let payload = transcodeEncode(block) ?? block
                try payload.write(to: path, options: .atomic)
                let stored = UInt64(payload.count)
                lock.lock()
                sizes[hash.value] = stored
                contentSizes[hash.value] = UInt64(block.count)
                atimes[hash.value] = Date()
                _indexedSize += stored
                lock.unlock()
                // Persist atime via mtime for rebuild after restart.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            } else {
                // Bump atime for LRU on dedup hit.
                lock.lock()
                atimes[hash.value] = Date()
                // Ensure size is tracked if rebuild missed it.
                if sizes[hash.value] == nil {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
                    let size = (attrs?[.size] as? UInt64) ?? UInt64(block.count)
                    sizes[hash.value] = size
                    _indexedSize += size
                }
                lock.unlock()
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            }
            hashes.append(hash)
            offset = end
        }
        return hashes
    }

    /// Materialise a sequence of chunks back into a file. Returns true on
    /// success (chunk-file existence is the only invariant — we don't have
    /// a separate "original digest" to verify against without changing the
    /// ingest API).
    @discardableResult
    public func materialise(_ hashes: [ChunkHash], into target: URL) throws -> Bool {
        if hashes.isEmpty {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            return true
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        for hash in hashes {
            let bytes = try readBlock(hash)
            handle.write(bytes)
        }
        return true
    }

    /// Ingest a file from disk directly (no full read into memory). Streams
    /// in `blockSize` chunks, each hashed + stored. Returns the ordered hash
    /// list and the file's own digest.
    public func ingestFile(_ source: URL) throws -> (hashes: [ChunkHash], digest: ChunkHash) {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hashes: [ChunkHash] = []
        while autoreleasepool(invoking: {
            let block = handle.readData(ofLength: blockSize)
            if block.isEmpty { return false }
            do {
                let hash = try ChunkHash.compute(block)
                let path = self.chunkPath(hash)
                let exists = FileManager.default.fileExists(atPath: path.path)
                if !exists {
                    let payload = self.transcodeEncode(block) ?? block
                    try payload.write(to: path, options: .atomic)
                    let stored = UInt64(payload.count)
                    self.lock.lock()
                    self.sizes[hash.value] = stored
                    self.contentSizes[hash.value] = UInt64(block.count)
                    self.atimes[hash.value] = Date()
                    self._indexedSize += stored
                    self.lock.unlock()
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
                } else {
                    self.lock.lock()
                    self.atimes[hash.value] = Date()
                    if self.sizes[hash.value] == nil {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
                        let size = (attrs?[.size] as? UInt64) ?? UInt64(block.count)
                        self.sizes[hash.value] = size
                        self._indexedSize += size
                    }
                    self.lock.unlock()
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
                }
                hashes.append(hash)
            } catch {
                return false
            }
            return true
        }) {}
        let digest = try ChunkHash.computeFile(source)
        return (hashes, digest)
    }

    public func chunkPath(_ hash: ChunkHash) -> URL {
        root.appendingPathComponent(hash.value)
    }

    public func exists(_ hash: ChunkHash) -> Bool {
        FileManager.default.fileExists(atPath: chunkPath(hash).path)
    }

    /// Global Has — content-addressed existence check. Updates atime for LRU.
    @discardableResult
    public func has(_ hash: ChunkHash) -> Bool {
        let exists = FileManager.default.fileExists(atPath: chunkPath(hash).path)
        if exists {
            lock.lock()
            atimes[hash.value] = Date()
            // Ensure size tracked if missing (e.g., after external file creation)
            if sizes[hash.value] == nil {
                let path = chunkPath(hash)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                    let size = attrs[.size] as? UInt64 ?? (attrs[.size] as? Int).map({ UInt64($0) }) {
                    sizes[hash.value] = size
                    _indexedSize += size
                }
            }
            lock.unlock()
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: chunkPath(hash).path)
        }
        return exists
    }

    /// Has alias for case-insensitive callers (spec calls it `Has`).
    public func Has(_ hash: ChunkHash) -> Bool { has(hash) }

    public func atime(for hash: ChunkHash) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return atimes[hash.value]
    }

    public func setAtime(_ hash: ChunkHash, _ date: Date) {
        lock.lock()
        atimes[hash.value] = date
        lock.unlock()
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: chunkPath(hash).path)
    }

    public func touch(_ hash: ChunkHash) {
        lock.lock()
        atimes[hash.value] = Date()
        lock.unlock()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: chunkPath(hash).path)
    }

    public func chunkSize(_ hash: ChunkHash) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return sizes[hash.value]
    }

    public func allChunkHashes() -> [ChunkHash] {
        lock.lock()
        let keys = Array(sizes.keys)
        lock.unlock()
        return keys.map { ChunkHash(unchecked: $0) }
    }

    public func refCount(for hash: ChunkHash) -> Int {
        lock.lock(); defer { lock.unlock() }
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
        let path = chunkPath(hash)
        let existed = FileManager.default.fileExists(atPath: path.path)
        var removedSize: UInt64 = 0
        lock.lock()
        if let s = sizes[hash.value] { removedSize = s }
        lock.unlock()
        if existed {
            try FileManager.default.removeItem(at: path)
        }
        if existed || removedSize > 0 {
            lock.lock()
            if let s = sizes.removeValue(forKey: hash.value) {
                _indexedSize = _indexedSize >= s ? _indexedSize - s : 0
            } else if removedSize > 0 {
                _indexedSize = _indexedSize >= removedSize ? _indexedSize - removedSize : 0
            }
            atimes.removeValue(forKey: hash.value)
            contentSizes.removeValue(forKey: hash.value)
            // Do not clear refCount here; caller manages pinning.
            lock.unlock()
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
