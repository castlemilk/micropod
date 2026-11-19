import Compression
import Foundation
import XCTest

@testable import MicropodSharedFS

final class ChunkIntegrityTests: XCTestCase {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testWriteFailureAtEachChunkBoundaryAbortsAndReleasesPins() throws {
        let blocks = ["aaaa", "bbbb", "cccc", "dddd"].map { Data($0.utf8) }
        let payload = blocks.reduce(Data(), +)
        for (index, block) in blocks.enumerated() {
            let dir = try fixture()
            let failing = try ChunkHash.compute(block)
            let store = try ChunkStore(
                root: dir.appendingPathComponent("chunks"), blockSize: 4, transcodeEnabled: false
            ) {
                data, path in
                if path.lastPathComponent == failing.value { throw POSIXError(.ENOSPC) }
                try data.write(to: path, options: .atomic)
            }
            let input = dir.appendingPathComponent("source")
            try payload.write(to: input)
            XCTAssertThrowsError(try store.ingestFile(input)) { XCTAssertEqual(($0 as? POSIXError)?.code, .ENOSPC) }
            XCTAssertEqual(try Data(contentsOf: input), payload)
            XCTAssertEqual(store.allChunkHashes().count, index)
            for hash in store.allChunkHashes() {
                XCTAssertEqual(store.refCount(for: hash), 0)
                try store.remove(hash)
            }
            XCTAssertEqual(store.indexedSize, 0)
        }
    }

    func testInPlaceMutationFailsAndRetryCapturesTheNewContents() throws {
        let dir = try fixture()
        let input = dir.appendingPathComponent("source")
        let original = Data("aaaabbbbcccc".utf8)
        let updated = Data("111122223333".utf8)
        try original.write(to: input)
        let first = try ChunkHash.compute(original.prefix(4))
        let store = try ChunkStore(root: dir.appendingPathComponent("chunks"), blockSize: 4, transcodeEnabled: false) {
            bytes, path in
            try bytes.write(to: path, options: .atomic)
            if path.lastPathComponent == first.value {
                let handle = try FileHandle(forWritingTo: input)
                try handle.write(contentsOf: updated)
                try handle.close()
            }
        }
        XCTAssertThrowsError(try store.ingestFileManifest(input)) { XCTAssertEqual(($0 as? POSIXError)?.code, .ESTALE) }
        let file = try store.ingestFileManifest(input)
        XCTAssertEqual(file.digest, try ChunkHash.compute(updated))
        XCTAssertEqual(file.byteCount, UInt64(updated.count))
        let out = dir.appendingPathComponent("restored")
        try store.materialise(.file(file), into: out)
        XCTAssertEqual(try Data(contentsOf: out), updated)
    }

    func testEmptyFileDeletionAndLegacyEmptyListAreDistinct() throws {
        let dir = try fixture()
        let store = try ChunkStore(root: dir.appendingPathComponent("chunks"))
        let input = dir.appendingPathComponent("empty")
        let target = dir.appendingPathComponent("target")
        try Data().write(to: input)
        let manifest = try store.ingestFileManifest(input)
        let decoded = try JSONDecoder().decode(ChunkEntry.self, from: JSONEncoder().encode(ChunkEntry.file(manifest)))
        try Data("old".utf8).write(to: target)
        try store.materialise(decoded, into: target)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        try store.materialise(.deletion, into: target)
        try store.materialise(.deletion, into: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try store.materialise(decoded, into: target)
        try store.materialise([], into: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertThrowsError(try store.materialise(.deletion, into: store.root))
    }

    func testCorruptOrMissingChunkAndInvalidManifestPreserveExistingDestination() throws {
        let dir = try fixture()
        let input = dir.appendingPathComponent("input")
        let target = dir.appendingPathComponent("target")
        let store = try ChunkStore(root: dir.appendingPathComponent("chunks"), blockSize: 4)
        let payload = Data("aaaabbbbcccc".utf8)
        let previous = Data("previous complete generation".utf8)
        try payload.write(to: input)
        try previous.write(to: target)
        let file = try store.ingestFileManifest(input)
        for invalid in [
            ChunkFileManifest(chunks: file.chunks.reversed(), byteCount: file.byteCount, digest: file.digest),
            ChunkFileManifest(chunks: file.chunks, byteCount: file.byteCount - 1, digest: file.digest),
            ChunkFileManifest(chunks: file.chunks, byteCount: file.byteCount + 1, digest: file.digest),
        ] {
            XCTAssertThrowsError(try store.materialise(.file(invalid), into: target))
            XCTAssertEqual(try Data(contentsOf: target), previous)
        }
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        future["version"] = 9
        let unsupported = try JSONDecoder().decode(
            ChunkFileManifest.self, from: JSONSerialization.data(withJSONObject: future))
        XCTAssertThrowsError(try store.materialise(.file(unsupported), into: target))
        let last = store.chunkPath(try XCTUnwrap(file.chunks.last))
        try Data("xxxx".utf8).write(to: last)
        XCTAssertThrowsError(try store.ingest(payload), "dedup must verify the existing object")
        XCTAssertThrowsError(try store.materialise(file.chunks, into: target))
        XCTAssertEqual(try Data(contentsOf: target), previous)
        try FileManager.default.removeItem(at: last)
        XCTAssertThrowsError(try store.materialise(.file(file), into: target))
        XCTAssertEqual(try Data(contentsOf: target), previous)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".sharedfs-") })
    }

    func testLegacyCompressedAndRawMagicBlocksSurviveRestart() throws {
        let dir = try fixture()
        let cache = dir.appendingPathComponent("chunks")
        let store = try ChunkStore(root: cache, transcodeEnabled: false)
        // Fixture from the original MCZ1 writer (4096 'A' bytes).
        let legacy = try XCTUnwrap(
            Data(
                base64Encoded:
                    "TUNaMQAAEABidjQxABAAAJEAAAAfQQEA////////////////////gPBsQUFBQUFBQUFBQUFBQUFB"
                    + "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB"
                    + "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBYnY0JA=="))
        let identity = Data(repeating: 65, count: 4096)
        let compressedHash = try ChunkHash.compute(identity)
        try legacy.write(to: store.chunkPath(compressedHash))
        // The *same valid frame bytes* also existed legally as raw data.
        let rawFixtures = [Data("MCZ1".utf8), Data("MCZ1abc".utf8), Data("MCZ1abcd".utf8), legacy]
        for raw in rawFixtures { try raw.write(to: store.chunkPath(try ChunkHash.compute(raw))) }
        let reopened = try ChunkStore(root: cache)
        XCTAssertEqual(try reopened.readBlock(compressedHash), identity)
        XCTAssertEqual(reopened.transcodedChunks, 1)
        for raw in rawFixtures {
            let hash = try ChunkHash.compute(raw)
            XCTAssertEqual(try reopened.readBlock(hash), raw)
            try reopened.remove(hash)
            XCTAssertEqual(try reopened.ingest(raw), [hash])
            let wire = try Data(contentsOf: reopened.chunkPath(hash))
            XCTAssertEqual(wire.prefix(4), Data("MCZ1".utf8))
            // This is the previous release's decoding API and header layout.
            var restored = Data(count: raw.count)
            let count = restored.withUnsafeMutableBytes { dst in
                wire.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                        src.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 8), src.count - 8,
                        nil, COMPRESSION_LZ4)
                }
            }
            XCTAssertEqual(count, raw.count)
            XCTAssertEqual(restored, raw)
        }
        let migrated = try ChunkStore(root: cache)
        for raw in rawFixtures { XCTAssertEqual(try migrated.readBlock(ChunkHash.compute(raw)), raw) }
    }

    func testOversizedStoredFileRejectedAndRestoreRetainsPermissions() throws {
        let dir = try fixture()
        let store = try ChunkStore(root: dir.appendingPathComponent("chunks"))
        let payload = Data("payload".utf8)
        let hashes = try store.ingest(payload)
        let out = dir.appendingPathComponent("out")
        try Data("old".utf8).write(to: out)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: out.path)
        try store.materialise(hashes, into: out)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int, 0o700)
        let object = store.chunkPath(try XCTUnwrap(hashes.first))
        let handle = try FileHandle(forWritingTo: object)
        try handle.truncate(atOffset: UInt64(ChunkRepresentation.maxStoredSize + 1))
        try handle.close()
        XCTAssertThrowsError(try store.materialise(hashes, into: out))
        XCTAssertEqual(try Data(contentsOf: out), payload)
        XCTAssertThrowsError(try ChunkStore(root: dir, blockSize: 0))
        XCTAssertThrowsError(try ChunkStore(root: dir, blockSize: ChunkRepresentation.maxBlockSize + 1))
    }

    func testMalformedFramesNeverReplaceTarget() throws {
        let dir = try fixture()
        let store = try ChunkStore(root: dir.appendingPathComponent("chunks"), transcodeEnabled: true)
        let block = Data(repeating: 65, count: 32 * 1024)
        let hash = try XCTUnwrap(store.ingest(block).first)
        let other = try XCTUnwrap(store.ingest(Data(repeating: 66, count: block.count)).first)
        let path = store.chunkPath(hash)
        let good = try Data(contentsOf: path)
        let out = dir.appendingPathComponent("out")
        let sentinel = Data("intact".utf8)
        try sentinel.write(to: out)
        var damaged = good
        damaged[damaged.count / 2] ^= 0xff
        var oversized = good
        oversized.replaceSubrange(4..<8, with: [0xff, 0xff, 0xff, 0xff])
        for invalid in [
            damaged, oversized, Data(good.dropLast()), good + Data([0]), Data(good.prefix(7)),
            try Data(contentsOf: store.chunkPath(other)),
        ] {
            try invalid.write(to: path)
            XCTAssertThrowsError(try store.materialise([hash], into: out))
            XCTAssertEqual(try Data(contentsOf: out), sentinel)
        }
    }

    func testConcurrentDedupCountsOnceAndRestartAgrees() async throws {
        let dir = try fixture()
        let store = try ChunkStore(root: dir)
        let payload = Data(repeating: 99, count: 65536)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { _ = try store.ingest(payload) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(store.allChunkHashes().count, 1)
        XCTAssertEqual(store.indexedSize, UInt64(payload.count))
        XCTAssertEqual(try ChunkStore(root: dir).indexedSize, store.indexedSize)
        XCTAssertEqual(store.refCount(for: try ChunkHash.compute(payload)), 0)
    }
}
