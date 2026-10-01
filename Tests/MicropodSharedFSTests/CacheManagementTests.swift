import Foundation
import XCTest

@testable import MicropodSharedFS

final class CacheManagementTests: XCTestCase {
    func testSnapshotIncludesOrdinaryAndSharedMountsAndRealCap() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = try source(in: root)
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("cache"), cacheMaxBytes: 12345)
        let ordinary = try await daemon.mount(src: src, readonly: false)
        let shared = try await daemon.mountShared(src: src, readonly: false)
        let snapshot = try await daemon.cacheSnapshot()
        XCTAssertEqual(snapshot.capBytes, 12345)
        XCTAssertEqual(Set(snapshot.activeMounts.map(\.id)), [ordinary.id, shared.id])
        let listed = try await daemon.list()
        XCTAssertEqual(listed.count, 2)
        try await daemon.unmount(id: ordinary.id)
        try await daemon.unmount(id: shared.id)
    }

    func testManualGCProtectsSharedViewsAndExplicitChunkPins() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = try source(in: root)
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("cache"))
        let store = await daemon.store
        let chunk = try store.ingest(Data("retained package".utf8))[0]
        let shared = try await daemon.mountShared(src: src, readonly: false)
        let busyGC = try await daemon.gc()
        XCTAssertEqual(busyGC.chunksRemoved, 0)
        XCTAssertTrue(store.exists(chunk))
        let review = try await daemon.reviewCacheCleanup()
        XCTAssertNotNil(review.blockedReason)
        try await daemon.unmount(id: shared.id)
        store.incrementRefCount(chunk)
        let pinnedGC = try await daemon.gc()
        XCTAssertEqual(pinnedGC.chunksRemoved, 0)
        XCTAssertTrue(store.exists(chunk))
        store.decrementRefCount(chunk)
        let idleGC = try await daemon.gc()
        XCTAssertEqual(idleGC.chunksRemoved, 1)
        XCTAssertFalse(store.exists(chunk))
    }

    func testReviewedCleanupExcludesNewerChunksAndRechecksPins() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("cache"))
        let store = await daemon.store
        let old = try store.ingest(Data("reviewed".utf8))[0]
        let pinned = try store.ingest(Data("pin-after-review".utf8))[0]
        let review = try await daemon.reviewCacheCleanup()
        XCTAssertEqual(review.chunkCount, 2)
        let newer = try store.ingest(Data("arrived-later".utf8))[0]
        store.incrementRefCount(pinned)
        let result = try await daemon.cleanReviewedCache(id: review.id)
        XCTAssertEqual(result.chunksRemoved, 1)
        XCTAssertEqual(result.bytesReclaimed, UInt64("reviewed".utf8.count))
        XCTAssertFalse(store.exists(old))
        XCTAssertTrue(store.exists(pinned))
        XCTAssertTrue(store.exists(newer))
    }

    func testMountAfterReviewRejectsCleanup() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = try source(in: root)
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("cache"))
        let store = await daemon.store
        let chunk = try store.ingest(Data("must survive".utf8))[0]
        let review = try await daemon.reviewCacheCleanup()
        let mount = try await daemon.mountShared(src: src, readonly: false)
        do {
            _ = try await daemon.cleanReviewedCache(id: review.id)
            XCTFail("A new active mount must reject the reviewed cleanup.")
        } catch {}
        XCTAssertTrue(store.exists(chunk))
        try await daemon.unmount(id: mount.id)
    }

    func testKeepPersistsAndProtectsFutureChunksFromEvictionAndGC() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("cache")
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot, cacheMaxBytes: 1)
        try await daemon.setCacheKeepEnabled(true)
        let store = await daemon.store
        let chunk = try store.ingest(Data("new package after Keep".utf8))[0]
        let capped = await daemon.enforceStorageCapIfNeeded()
        let collected = try await daemon.gc()
        XCTAssertEqual(capped.chunksRemoved, 0)
        XCTAssertEqual(collected.chunksRemoved, 0)
        XCTAssertTrue(store.exists(chunk))
        let restarted = try SharedFSDaemon(cacheRoot: cacheRoot, cacheMaxBytes: 1)
        let snapshot = try await restarted.cacheSnapshot()
        XCTAssertTrue(snapshot.keepEnabled)
        XCTAssertTrue(snapshot.overCap)
        XCTAssertGreaterThan(snapshot.storedBytes, 1)
        try await restarted.setCacheKeepEnabled(false)
        let evicted = await restarted.enforceStorageCapIfNeeded()
        XCTAssertEqual(evicted.chunksRemoved, 1)
    }

    func testCapProtectsEveryChunkOfHiddenLargeActiveFile() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("source/.npm")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("package.bin")
        var data = Data(repeating: 0x11, count: 256 * 1024)
        data.append(Data(repeating: 0x22, count: 4096))
        try data.write(to: file)
        let daemon = try SharedFSDaemon(
            cacheRoot: root.appendingPathComponent("cache"), cacheMaxBytes: UInt64(data.count))
        let store = await daemon.store
        let hashes = try store.ingestFile(file).hashes
        let old = Date(timeIntervalSinceNow: -600)
        for hash in hashes { store.setAtime(hash, old) }
        let mount = try await daemon.mountShared(src: src.deletingLastPathComponent(), readonly: false)
        let orphan = try store.ingest(Data(repeating: 0x33, count: 1024))[0]
        store.setAtime(orphan, old.addingTimeInterval(1))
        _ = await daemon.enforceStorageCapIfNeeded()
        XCTAssertTrue(hashes.allSatisfy { store.exists($0) })
        XCTAssertFalse(store.exists(orphan))
        try await daemon.unmount(id: mount.id)
    }

    func testDamagedRetentionPreferenceFailsClosedUntilExplicitlyChanged() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data("damaged preference".utf8).write(to: cacheRoot.appendingPathComponent("retention.json"))
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot, cacheMaxBytes: 1)
        let store = await daemon.store
        let chunk = try store.ingest(Data("keep me".utf8))[0]
        _ = await daemon.enforceStorageCapIfNeeded()
        let snapshot = try await daemon.cacheSnapshot()
        XCTAssertTrue(snapshot.keepEnabled)
        XCTAssertNotNil(snapshot.retentionWarning)
        XCTAssertTrue(store.exists(chunk))
        try await daemon.setCacheKeepEnabled(false)
        let repaired = try await daemon.cacheSnapshot()
        XCTAssertFalse(repaired.keepEnabled)
        XCTAssertNil(repaired.retentionWarning)
    }

    func testUnregisteredViewDirectoryBlocksCleanupAfterRestart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("cache")
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot, cacheMaxBytes: 1)
        let store = await daemon.store
        let chunk = try store.ingest(Data("package possibly used by old view".utf8))[0]
        let review = try await daemon.reviewCacheCleanup()
        // A daemon restart can leave views on disk without a registered
        // mount. Simulate that state entirely inside this temporary root.
        try FileManager.default.createDirectory(
            at: cacheRoot.appendingPathComponent("views/retained-view"), withIntermediateDirectories: true)
        do {
            _ = try await daemon.cleanReviewedCache(id: review.id)
            XCTFail("An unregistered retained view must reject cleanup.")
        } catch {}
        let blocked = try await daemon.reviewCacheCleanup()
        let gc = try await daemon.gc()
        let automaticGC = await daemon.enforceStorageCapIfNeeded()
        XCTAssertNotNil(blocked.blockedReason)
        XCTAssertEqual(blocked.chunkCount, 0)
        XCTAssertEqual(gc.chunksRemoved, 0)
        XCTAssertEqual(automaticGC.chunksRemoved, 0)
        XCTAssertTrue(store.exists(chunk))
    }

    func testSocketTransportsSnapshotReviewRetentionAndCleanup() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("cache"), cacheMaxBytes: 45678)
        let store = await daemon.store
        let payload = Data("package retained for IPC cleanup".utf8)
        let chunk = try store.ingest(payload)[0]
        let socket = root.appendingPathComponent("socket").path
        let server = SharedFSServer(socketPath: socket, daemon: daemon)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketClient(socketPath: socket, timeout: 3)
        // NWListener publishes its socket asynchronously; bounded retries
        // avoid introducing a fixed startup sleep into the production path.
        var response: SharedCacheSnapshot?
        for _ in 0..<20 {
            response = try? await client.cacheSnapshot()
            if response != nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(response?.capBytes, 45678)
        XCTAssertEqual(response?.storedBytes, UInt64(payload.count))
        XCTAssertEqual(response?.chunkCount, 1)
        try await client.setCacheKeepEnabled(true)
        let kept = try await client.cacheSnapshot()
        let review = try await client.reviewCacheCleanup()
        XCTAssertTrue(kept.keepEnabled)
        XCTAssertNotNil(review.blockedReason)
        try await client.setCacheKeepEnabled(false)
        let removable = try await client.reviewCacheCleanup()
        XCTAssertNil(removable.blockedReason)
        XCTAssertEqual(removable.chunkCount, 1)
        let result = try await client.cleanReviewedCache(id: removable.id)
        XCTAssertEqual(result.chunksRemoved, 1)
        XCTAssertEqual(result.bytesReclaimed, UInt64(payload.count))
        XCTAssertFalse(store.exists(chunk))
        let cleaned = try await client.cacheSnapshot()
        XCTAssertEqual(cleaned.storedBytes, 0)
        XCTAssertEqual(cleaned.chunkCount, 0)
        let emptyReview = try await client.reviewCacheCleanup()
        XCTAssertEqual(emptyReview.chunkCount, 0)
        XCTAssertEqual(emptyReview.storedBytes, 0)
        XCTAssertEqual(emptyReview.protectedChunkCount, 0)
        do {
            _ = try await client.cleanReviewedCache(id: removable.id)
            XCTFail("A consumed review token must be rejected over IPC.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("expired"))
        }
    }

    private func temporaryRoot() throws -> URL {
        // Keep the Unix socket path below macOS sockaddr_un's limit.
        let root = URL(fileURLWithPath: "/private/tmp/cache-management-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func source(in root: URL) throws -> URL {
        let src = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("a package input".utf8).write(to: src.appendingPathComponent("file.txt"))
        return src
    }
}
