import CryptoKit
import Foundation

/// A SHA256 content hash. Stored as a hex string so the chunk file path
/// doubles as its identity — dedup is implicit.
public struct ChunkHash: Hashable, Codable, Sendable {
    public let value: String

    public init(_ hex: String) {
        precondition(hex.count == 64 || hex.isEmpty, "ChunkHash must be 64 hex chars")
        self.value = hex.lowercased()
    }

    /// Init from a pre-validated 64-char hex; skips the precondition check.
    public init(unchecked hex: String) {
        self.value = hex.lowercased()
    }

    public var rawBytes: Data {
        var data = Data()
        data.reserveCapacity(32)
        var i = value.startIndex
        while i < value.endIndex {
            let next = value.index(i, offsetBy: 2)
            if let byte = UInt8(value[i..<next], radix: 16) {
                data.append(byte)
            }
            i = next
        }
        return data
    }

    public static func compute(_ data: Data) throws -> ChunkHash {
        let digest = SHA256.hash(data: data)
        return ChunkHash(digest.map { String(format: "%02x", $0) }.joined())
    }

    public static func computeFile(_ url: URL) throws -> ChunkHash {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let block = handle.readData(ofLength: 256 * 1024)
            if block.isEmpty { return false }
            hasher.update(data: block)
            return true
        }) {}
        let digest = hasher.finalize()
        return ChunkHash(digest.map { String(format: "%02x", $0) }.joined())
    }
}
