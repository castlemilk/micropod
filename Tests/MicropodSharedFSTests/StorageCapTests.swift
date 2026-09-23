import XCTest

@testable import MicropodSharedFS

final class StorageCapTests: XCTestCase {

    // MARK: - ChunkStore: Has, atime, indexedSize

    func testChunkStoreHasMethod() throws {
        let store = try ChunkStore(root: tempDir("has"))
        let data = Data("hello-cache".utf8)
        let hashes = try store.ingest(data)
        XCTAssertFalse(hashes.isEmpty)
        for hash in hashes {
            XCTAssertTrue(store.has(hash), "has should return true for ingested chunk")
            XCTAssertTrue(store.exists(hash))
        }
        let missing = try ChunkHash.compute(Data("missing".utf8))
        XCTAssertFalse(store.has(missing))
    }

    func testChunkStoreAtimeTracking() throws {
        let store = try ChunkStore(root: tempDir("atime"))
        let data = Data("atime-data".utf8)
        let hashes = try store.ingest(data)
        let hash = hashes[0]
        let firstAtime = store.atime(for: hash)
        XCTAssertNotNil(firstAtime, "atime should be set after ingest")
        // Touch should update atime
        let old = Date(timeIntervalSinceNow: -1000)
        store.setAtime(hash, old)
        XCTAssertEqual(store.atime(for: hash)!.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1.0)
        // has should bump atime
        _ = store.has(hash)
        let bumped = store.atime(for: hash)!
        XCTAssertTrue(bumped.timeIntervalSince(old) > 500, "has should update atime")
    }

    func testChunkStoreIndexedSize() throws {
        let store = try ChunkStore(root: tempDir("indexedSize"))
        XCTAssertEqual(store.indexedSize, 0)
        XCTAssertEqual(store.sharedCacheSize, 0)
        let data1 = Data(repeating: 0x11, count: 1024)
        let data2 = Data(repeating: 0x22, count: 2048)
        let h1 = try store.ingest(data1)
        let h2 = try store.ingest(data2)
        // indexedSize should be sum of chunk file sizes
        let size1 = store.chunkSize(h1[0]) ?? 0
        let size2 = store.chunkSize(h2[0]) ?? 0
        XCTAssertEqual(store.indexedSize, size1 + size2)
        XCTAssertEqual(store.sharedCacheSize, store.indexedSize)
        // removing a chunk updates indexedSize
        try store.remove(h1[0])
        XCTAssertEqual(store.indexedSize, size2)
    }

    // MARK: - SharedFSDaemon: sharedCacheSize via store index

    func testSharedCacheSizeViaStoreIndex() async throws {
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("size-via-index"))
        let data = Data(repeating: 0x33, count: 4096)
        let store = await daemon.store
        _ = try store.ingest(data)
        let storeSize = store.indexedSize
        let daemonSize = await daemon.sharedCacheSize
        XCTAssertEqual(daemonSize, storeSize)
        XCTAssertGreaterThan(daemonSize, 0)
    }

    // MARK: - Storage cap gate enforced before next mount

    func testIndexedSizeGateEnforcedBeforeMount() async throws {
        // Use tiny cap to force eviction quickly
        let cap: UInt64 = 3000
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("gate"), cacheMaxBytes: cap)
        let store = await daemon.store
        // Fill store over cap with 3 chunks (~1024 each) with old atime
        let d1 = Data(repeating: 0x01, count: 1024)
        let d2 = Data(repeating: 0x02, count: 1024)
        let d3 = Data(repeating: 0x03, count: 1024)
        let d4 = Data(repeating: 0x04, count: 1024)
        let h1 = try store.ingest(d1)[0]
        let h2 = try store.ingest(d2)[0]
        let h3 = try store.ingest(d3)[0]
        // Make them old enough to be grace-eligible
        let old = Date(timeIntervalSinceNow: -600)  // 10m ago
        store.setAtime(h1, old)
        store.setAtime(h2, old.addingTimeInterval(10))
        store.setAtime(h3, old.addingTimeInterval(20))
        // Now store is ~3072 > cap 3000, slightly over. Add one more to push well over
        let h4 = try store.ingest(d4)[0]
        store.setAtime(h4, old.addingTimeInterval(30))
        // Verify over cap
        let before = await daemon.sharedCacheSize
        XCTAssertGreaterThan(before, cap)
        // Next mount should trigger eviction before mounting
        let src = try writeSourceTree()
        _ = try await daemon.mount(src: src, readonly: false)
        let after = await daemon.sharedCacheSize
        XCTAssertLessThanOrEqual(after, cap, "mount should have enforced cap and evicted oldest chunks")
        // Oldest (h1) should be gone
        XCTAssertFalse(store.has(h1))
    }

    // MARK: - LRU eviction respects pinning

    func testEvictionRespectsPinning() async throws {
        let cap: UInt64 = 2500
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("pinning"), cacheMaxBytes: cap)
        let store = await daemon.store
        let d1 = Data(repeating: 0x11, count: 1024)
        let d2 = Data(repeating: 0x22, count: 1024)
        let d3 = Data(repeating: 0x33, count: 1024)
        let h1 = try store.ingest(d1)[0]
        let h2 = try store.ingest(d2)[0]
        let h3 = try store.ingest(d3)[0]
        let old = Date(timeIntervalSinceNow: -600)
        store.setAtime(h1, old)
        store.setAtime(h2, old.addingTimeInterval(5))
        store.setAtime(h3, old.addingTimeInterval(10))
        // Pin h1 (simulate active sharedView backing)
        store.incrementRefCount(h1)
        // Now over cap 3072 > 2500. Eviction should skip pinned h1 and evict h2 then h3 if needed
        let src = try writeSourceTree()
        _ = try await daemon.mount(src: src, readonly: false)
        XCTAssertTrue(store.has(h1), "pinned chunk must not be evicted")
        // At least one unpinned should be evicted to get under cap
        let remaining = [h2, h3].filter { store.has($0) }
        XCTAssertLessThan(remaining.count, 2, "at least one unpinned chunk should be evicted")
        let cappedSize = await daemon.sharedCacheSize
        XCTAssertLessThanOrEqual(cappedSize, cap)
    }

    // MARK: - Grace period: recent chunks not evicted unless bypass

    func testEvictionRespectsGrace() async throws {
        let cap: UInt64 = 2500
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("grace"), cacheMaxBytes: cap)
        let store = await daemon.store
        let old = Date(timeIntervalSinceNow: -600)  // eligible
        let recent = Date()  // not eligible
        let dOld1 = Data(repeating: 0xAA, count: 1024)
        let dOld2 = Data(repeating: 0xBB, count: 1024)
        let dRecent = Data(repeating: 0xCC, count: 1024)
        let hOld1 = try store.ingest(dOld1)[0]
        let hOld2 = try store.ingest(dOld2)[0]
        let hRecent = try store.ingest(dRecent)[0]
        store.setAtime(hOld1, old)
        store.setAtime(hOld2, old.addingTimeInterval(5))
        store.setAtime(hRecent, recent)
        // Over cap: need to evict one. Grace-respecting should evict old before recent
        let src = try writeSourceTree()
        _ = try await daemon.mount(src: src, readonly: false)
        XCTAssertFalse(store.has(hOld1), "oldest grace-eligible should be evicted first")
        XCTAssertTrue(store.has(hRecent), "recent chunk should be preserved when grace-eligible candidates exist")
    }

    func testGraceBypassWhenStillOverCap() async throws {
        let cap: UInt64 = 1500
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("bypass"), cacheMaxBytes: cap)
        let store = await daemon.store
        // Fill with only recent chunks (<5m) – normally not evictable, but must bypass when still over cap
        let recent = Date()
        let d1 = Data(repeating: 0x41, count: 1024)
        let d2 = Data(repeating: 0x42, count: 1024)
        let d3 = Data(repeating: 0x43, count: 1024)
        let h1 = try store.ingest(d1)[0]
        let h2 = try store.ingest(d2)[0]
        let h3 = try store.ingest(d3)[0]
        store.setAtime(h1, recent)
        store.setAtime(h2, recent.addingTimeInterval(1))
        store.setAtime(h3, recent.addingTimeInterval(2))
        let beforeSize = await daemon.sharedCacheSize
        XCTAssertGreaterThan(beforeSize, cap)
        let src = try writeSourceTree()
        _ = try await daemon.mount(src: src, readonly: false)
        // Should have bypassed grace and evicted oldest recent
        XCTAssertFalse(store.has(h1), "bypass should evict oldest recent when still over cap")
        let afterSize = await daemon.sharedCacheSize
        XCTAssertLessThanOrEqual(afterSize, cap)
    }

    func testPinnedOverCapGauge() async throws {
        let cap: UInt64 = 1500
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("gauge"), cacheMaxBytes: cap)
        let store = await daemon.store
        let d1 = Data(repeating: 0x51, count: 1024)
        let d2 = Data(repeating: 0x52, count: 1024)
        let d3 = Data(repeating: 0x53, count: 1024)
        let h1 = try store.ingest(d1)[0]
        let h2 = try store.ingest(d2)[0]
        let h3 = try store.ingest(d3)[0]
        let old = Date(timeIntervalSinceNow: -600)
        store.setAtime(h1, old)
        store.setAtime(h2, old.addingTimeInterval(5))
        store.setAtime(h3, old.addingTimeInterval(10))
        // Pin all
        store.incrementRefCount(h1)
        store.incrementRefCount(h2)
        store.incrementRefCount(h3)
        let beforeGaugeSize = await daemon.sharedCacheSize
        XCTAssertGreaterThan(beforeGaugeSize, cap)
        let src = try writeSourceTree()
        _ = try await daemon.mount(src: src, readonly: false)
        // Still over cap because all pinned, gauge should be 1
        let pinnedGauge = await daemon.sharedCachePinnedOverCap
        XCTAssertEqual(pinnedGauge, 1, "gauge should be 1 when still over cap and all remaining pinned")
        // And no pinned evicted
        XCTAssertTrue(store.has(h1))
        XCTAssertTrue(store.has(h2))
        XCTAssertTrue(store.has(h3))
        // sharedCacheSize still > cap
        let stillOver = await daemon.sharedCacheSize
        XCTAssertGreaterThan(stillOver, cap)
    }

    // MARK: - DiskManager integration: eviction via gcIfNeeded / sweep

    func testDiskManagerIntegrationViaGC() async throws {
        let cap: UInt64 = 2000
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("diskmgr"), cacheMaxBytes: cap)
        let store = await daemon.store
        let d1 = Data(repeating: 0x61, count: 1024)
        let d2 = Data(repeating: 0x62, count: 1024)
        let d3 = Data(repeating: 0x63, count: 1024)
        let h1 = try store.ingest(d1)[0]
        let h2 = try store.ingest(d2)[0]
        let h3 = try store.ingest(d3)[0]
        let old = Date(timeIntervalSinceNow: -600)
        store.setAtime(h1, old)
        store.setAtime(h2, old.addingTimeInterval(5))
        store.setAtime(h3, old.addingTimeInterval(10))
        let result = await daemon.enforceStorageCapIfNeeded()
        XCTAssertGreaterThan(result.chunksRemoved, 0)
        let afterSweepSize = await daemon.sharedCacheSize
        XCTAssertLessThanOrEqual(afterSweepSize, cap)
    }

    // MARK: - helpers

    private func writeSourceTree() throws -> URL {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedfs-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "alpha".write(toFile: src.appendingPathComponent("a.txt").path, atomically: true, encoding: .utf8)
        return src
    }

    private func tempDir(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedfs-test-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cacheRoot(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedfs-cache-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
