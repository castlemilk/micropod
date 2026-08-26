import Foundation

/// Content-addressed chunk store backed by the host filesystem.
///
/// Each chunk is a single file at `root/<sha256>` — the hash IS the
/// filename, so dedup is implicit and free. APFS gives us free CoW across
/// hardlinks to the same chunk file (and `clonefile` for cheap per-view
/// copies).
public final class ChunkStore: @unchecked Sendable {
    public let root: URL
    public let blockSize: Int

    // MARK: - Indexed metadata (no `du`)
    private let lock = NSLock()
    private var _indexedSize: UInt64 = 0
    private var sizes: [String: UInt64] = [:]
    private var atimes: [String: Date] = [:]
    private var refCounts: [String: Int] = [:]

    /// Synchronous indexed size — sum of chunk file sizes via metadata, no filesystem `du`.
    public var indexedSize: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _indexedSize
    }

    /// Alias for daemon integration (`sharedCacheSize` via store index).
    public var sharedCacheSize: UInt64 { indexedSize }

    public init(root: URL, blockSize: Int = 256 * 1024) throws {
        self.root = root
        self.blockSize = blockSize
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rebuildIndex()
    }

    private func rebuildIndex() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        var total: UInt64 = 0
        var newSizes: [String: UInt64] = [:]
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
            newAtimes[name] = mtime
            total += size
        }
        lock.lock()
        self.sizes = newSizes
        self.atimes = newAtimes
        self._indexedSize = total
        // refCounts start at 0; daemon increments for pinned views.
        lock.unlock()
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
                try block.write(to: path, options: .atomic)
                let size = UInt64(block.count)
                lock.lock()
                sizes[hash.value] = size
                atimes[hash.value] = Date()
                _indexedSize += size
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
            let chunkURL = chunkPath(hash)
            let bytes = try Data(contentsOf: chunkURL, options: .mappedIfSafe)
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
                    try block.write(to: path, options: .atomic)
                    let size = UInt64(block.count)
                    self.lock.lock()
                    self.sizes[hash.value] = size
                    self.atimes[hash.value] = Date()
                    self._indexedSize += size
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
