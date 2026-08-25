import XCTest

@testable import MicropodSharedFS

final class ChunkStoreTests: XCTestCase {
    func testIngestAndMaterialiseRoundTrip() throws {
        let store = try ChunkStore(root: tempDir("chunkstore"))
        let data = Data((0..<10_000).map { UInt8($0 & 0xff) })
        let hashes = try store.ingest(data)
        XCTAssertFalse(hashes.isEmpty)
        XCTAssertTrue(hashes.allSatisfy { store.exists($0) })
        let target = tempDir("chunkstore").appendingPathComponent("roundtrip.bin")
        XCTAssertTrue(try store.materialise(hashes, into: target))
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    func testDedupAcrossIngestions() throws {
        let store = try ChunkStore(root: tempDir("dedup"))
        let block = Data(repeating: 0xab, count: 1024)
        let h1 = try store.ingest(block)
        let h2 = try store.ingest(block)
        XCTAssertEqual(h1, h2)
        XCTAssertFalse(h1.isEmpty)
        for hash in h1 { XCTAssertTrue(store.exists(hash)) }
    }

    func testEmptyIngestProducesNoChunks() throws {
        let store = try ChunkStore(root: tempDir("empty"))
        XCTAssertEqual(try store.ingest(Data()), [])
    }

    func testMultiBlockIngestProducesMultipleChunks() throws {
        _ = try ChunkStore(root: tempDir("multi"))
        // Use a smaller blockSize to force multi-block for the test.
        let smallStore = try ChunkStore(root: tempDir("multi2"), blockSize: 100)
        let data = Data(repeating: 0x42, count: 350)
        let hashes = try smallStore.ingest(data)
        XCTAssertEqual(hashes.count, 4)  // 100+100+100+50
    }

    func testMaterialiseEmptyHashesRemovesFile() throws {
        let store = try ChunkStore(root: tempDir("empty-mat"))
        let target = tempDir("empty-mat").appendingPathComponent("empty.bin")
        try Data().write(to: target)
        XCTAssertTrue(try store.materialise([], into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testHashStability() throws {
        let h1 = try ChunkHash.compute(Data("hello".utf8))
        let h2 = try ChunkHash.compute(Data("hello".utf8))
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.value.count, 64)
        let h3 = try ChunkHash.compute(Data("world".utf8))
        XCTAssertNotEqual(h1, h3)
    }

    // MARK: - helpers

    private func tempDir(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedfs-test-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
