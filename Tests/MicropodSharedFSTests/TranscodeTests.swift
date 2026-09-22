import XCTest

@testable import MicropodSharedFS

/// Transcoding (LZ4 frames): eligible blocks shrink on disk, filenames stay
/// identity hashes, reads decode transparently, incompressible blocks stay
/// plain, and legacy (unframed) chunks keep working.
final class TranscodeTests: XCTestCase {
    /// Compressible text-ish corpus (~300 KB, spans multiple 64 KiB blocks).
    private func textCorpus(blockSize: Int) -> Data {
        var out = Data()
        for i in 0..<300 {
            out.append(contentsOf: "package module\(i % 25)\n".utf8)
            out.append(contentsOf: "// ".utf8 + Data(repeating: UInt8(97 + (i % 26)), count: 800) + "\n".utf8)
        }
        assert(out.count > blockSize * 3)
        return out
    }

    /// Deterministic incompressible bytes (xorshift PRNG).
    private func randomBytes(_ count: Int, seed: UInt64 = 0x12345678) -> Data {
        var state = seed
        var out = Data()
        out.reserveCapacity(count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            out.append(UInt8(truncatingIfNeeded: state))
        }
        return out
    }

    private func tempDir(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedfs-transcode-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRoundtripShrinksText() throws {
        let dir = tempDir("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: true)
        let corpus = textCorpus(blockSize: 64 * 1024)
        let hashes = try store.ingest(corpus)
        XCTAssertFalse(hashes.isEmpty)
        XCTAssertGreaterThan(store.transcodedChunks, 0, "text blocks must frame")
        XCTAssertGreaterThan(store.transcodedBytesSaved, 0)
        let target = dir.appendingPathComponent("out.bin")
        XCTAssertTrue(try store.materialise(hashes, into: target))
        XCTAssertEqual(try Data(contentsOf: target), corpus)
        // Framed files live under plain identity-hash names.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.allSatisfy { $0.count == 64 || $0 == "out.bin" })
    }

    func testIncompressibleStaysPlain() throws {
        let dir = tempDir("plain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: true)
        let blob = randomBytes(200 * 1024)
        let hashes = try store.ingest(blob)
        XCTAssertEqual(store.transcodedChunks, 0, "random bytes must not frame")
        XCTAssertEqual(store.transcodedBytesSaved, 0)
        let target = dir.appendingPathComponent("out.bin")
        XCTAssertTrue(try store.materialise(hashes, into: target))
        XCTAssertEqual(try Data(contentsOf: target), blob)
    }

    func testSmallBlocksNeverFrame() throws {
        let dir = tempDir("small")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1 KiB blocks stay below the 4 KiB transcode floor.
        let store = try ChunkStore(root: dir, blockSize: 1024, transcodeEnabled: true)
        let corpus = textCorpus(blockSize: 64 * 1024).prefix(100 * 1024)
        _ = try store.ingest(Data(corpus))
        XCTAssertEqual(store.transcodedChunks, 0)
    }

    func testDisabledMatchesLegacyBehavior() throws {
        let dir = tempDir("disabled")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: false)
        XCTAssertFalse(store.transcodeEnabled)
        let corpus = textCorpus(blockSize: 64 * 1024)
        let hashes = try store.ingest(corpus)
        XCTAssertEqual(store.transcodedChunks, 0)
        XCTAssertEqual(store.indexedSize, UInt64(corpus.count))
        let target = dir.appendingPathComponent("out.bin")
        XCTAssertTrue(try store.materialise(hashes, into: target))
        XCTAssertEqual(try Data(contentsOf: target), corpus)
    }

    func testLegacyFilesReadThroughAfterRestart() throws {
        let dir = tempDir("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Write with transcoding off (legacy layout), reopen with it on:
        // old files must read back byte-identical, stats stay consistent.
        let v1 = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: false)
        let corpus = textCorpus(blockSize: 64 * 1024)
        let hashes = try v1.ingest(corpus)
        let v2 = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: true)
        XCTAssertEqual(v2.indexedSize, v1.indexedSize)
        XCTAssertEqual(v2.transcodedChunks, 0)
        let target = dir.appendingPathComponent("out.bin")
        XCTAssertTrue(try v2.materialise(hashes, into: target))
        XCTAssertEqual(try Data(contentsOf: target), corpus)
    }

    func testFramedFilesSurviveRestart() throws {
        let dir = tempDir("restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: true)
        let corpus = textCorpus(blockSize: 64 * 1024)
        let hashes = try v1.ingest(corpus)
        let saved = v1.transcodedBytesSaved
        XCTAssertGreaterThan(saved, 0)
        // Rebuild recovers stored sizes AND logical sizes from frame headers.
        let v2 = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: true)
        XCTAssertEqual(v2.indexedSize, v1.indexedSize)
        XCTAssertEqual(v2.transcodedBytesSaved, saved)
        XCTAssertEqual(v2.transcodedChunks, v1.transcodedChunks)
        let target = dir.appendingPathComponent("out.bin")
        XCTAssertTrue(try v2.materialise(hashes, into: target))
        XCTAssertEqual(try Data(contentsOf: target), corpus)
    }

    func testCorruptFrameThrowsRatherThanServingBadBytes() throws {
        let dir = tempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ChunkStore(root: dir, blockSize: 64 * 1024, transcodeEnabled: true)
        let corpus = textCorpus(blockSize: 64 * 1024)
        let hashes = try store.ingest(corpus)
        XCTAssertFalse(hashes.isEmpty)
        // Flip bytes inside the first framed payload.
        let first = store.chunkPath(hashes[0])
        var raw = try Data(contentsOf: first)
        if raw.count > 20 {
            raw[20] ^= 0xFF
            try raw.write(to: first)
            let target = dir.appendingPathComponent("out.bin")
            XCTAssertThrowsError(try store.materialise(hashes, into: target))
        }
    }
}
