import Foundation

/// One regular file, including a zero-length file. The digest covers the
/// concatenated identity bytes in the supplied order, independent of chunking.
public struct ChunkFileManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let chunks: [ChunkHash]
    public let byteCount: UInt64
    public let digest: ChunkHash

    public init(chunks: [ChunkHash], byteCount: UInt64, digest: ChunkHash) {
        self.version = 1
        self.chunks = chunks
        self.byteCount = byteCount
        self.digest = digest
    }
}

public enum ChunkEntry: Codable, Equatable, Sendable {
    case file(ChunkFileManifest)
    case deletion
}
