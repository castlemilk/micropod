import Compression
import Foundation

/// The on-disk MCZ1 format remains readable by older Micropod releases.
/// Its payload is an Apple LZ4 stream, which supports both compressed and
/// literal blocks. Collision-prone raw content uses the literal encoding.
enum ChunkRepresentation {
    static let maxBlockSize = 16 << 20
    private static let headerSize = 8
    static let maxStoredSize = maxBlockSize + headerSize + 12  // literal block header and end marker
    private static let magic = Data("MCZ1".utf8)

    static func hasMagic(_ bytes: Data) -> Bool { bytes.starts(with: magic) }

    static func encode(_ bytes: Data, compress: Bool) -> Data {
        if compress, bytes.count >= ChunkStore.transcodeMinBytes {
            // A stream that doesn't fit the savings budget would be stored raw.
            let capacity = Int(Double(bytes.count) * ChunkStore.transcodeMaxRatio) - headerSize
            var output = Data(count: capacity)
            let count = output.withUnsafeMutableBytes { dst in
                bytes.withUnsafeBytes { src in
                    compression_encode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_LZ4)
                }
            }
            if count > 0 { return header(for: bytes.count) + output.prefix(count) }
        }
        guard hasMagic(bytes) else { return bytes }
        // compression.h defines bv4- + little-endian length + literal bytes
        // and bv4$ (end). Even a reader predating digest checks decodes this.
        var result = header(for: bytes.count)
        result.append(contentsOf: "bv4-".utf8)
        withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { result.append(contentsOf: $0) }
        result.append(bytes)
        result.append(contentsOf: "bv4$".utf8)
        return result
    }

    private static func header(for length: Int) -> Data {
        var header = magic
        withUnsafeBytes(of: UInt32(length).bigEndian) { header.append(contentsOf: $0) }
        return header
    }

    static func decode(_ stored: Data, expected: ChunkHash) throws -> Data {
        // A legacy raw block can itself be an entire valid MCZ1 frame.
        // Only its content address distinguishes those two interpretations.
        if stored.count <= maxBlockSize, try ChunkHash.compute(stored) == expected { return stored }
        guard hasMagic(stored), stored.count >= headerSize else {
            throw ChunkStore.TranscodeError.corruptFrame("invalid chunk header or digest")
        }
        let length = stored[4..<headerSize].reduce(0) { ($0 << 8) | Int($1) }
        guard (1...maxBlockSize).contains(length) else {
            throw ChunkStore.TranscodeError.corruptFrame("invalid chunk length")
        }
        let bytes = try decompress(stored, header: headerSize, length: length)
        guard try ChunkHash.compute(bytes) == expected else {
            throw ChunkStore.TranscodeError.corruptFrame("chunk digest mismatch")
        }
        return bytes
    }

    private static func decompress(_ stored: Data, header: Int, length: Int) throws -> Data {
        // Leave one spare output byte so a truncated prefix cannot pass by
        // filling the destination. Require consumption of the entire stream.
        var output = Data(count: length + 1)
        try output.withUnsafeMutableBytes { dst in
            try stored.withUnsafeBytes { src in
                var stream = compression_stream(
                    dst_ptr: dst.bindMemory(to: UInt8.self).baseAddress!, dst_size: 0,
                    src_ptr: src.bindMemory(to: UInt8.self).baseAddress!, src_size: 0, state: nil)
                guard
                    compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4)
                        == COMPRESSION_STATUS_OK
                else { throw ChunkStore.TranscodeError.corruptFrame("decoder unavailable") }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!.advanced(by: header)
                stream.src_size = stored.count - header
                stream.dst_ptr = dst.bindMemory(to: UInt8.self).baseAddress!
                stream.dst_size = length + 1
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_END, stream.src_size == 0, stream.dst_size == 1 else {
                    throw ChunkStore.TranscodeError.corruptFrame("incomplete or oversized LZ4 stream")
                }
            }
        }
        output.removeLast()
        return output
    }
}
