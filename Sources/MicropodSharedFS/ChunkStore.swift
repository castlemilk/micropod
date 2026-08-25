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

    public init(root: URL, blockSize: Int = 256 * 1024) throws {
        self.root = root
        self.blockSize = blockSize
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
            if !FileManager.default.fileExists(atPath: path.path) {
                try block.write(to: path, options: .atomic)
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
                if !FileManager.default.fileExists(atPath: path.path) {
                    try block.write(to: path, options: .atomic)
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

    /// Remove a chunk if it exists (used by GC). No-op if already gone.
    public func remove(_ hash: ChunkHash) throws {
        let path = chunkPath(hash)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
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
