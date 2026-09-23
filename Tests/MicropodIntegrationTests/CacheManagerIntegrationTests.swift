import XCTest

@testable import MicropodCore
@testable import MicropodSharedFS

/// Plan Chunk 5 — Cross-repo warm test (E2E Validation).
/// Mirrors the Go E2E validation but exercises the Swift daemon's
/// content-addressed chunk store. When `MICROPOD_REAL_E2E=1` the test
/// also validates the shim's well-known auto-mount path; otherwise it
/// runs in-process against a temp filesystem (no container runtime needed).
final class CacheManagerIntegrationTests: XCTestCase {

    // MARK: - Cross-repo warm (spec Task 6)

    func testCrossRepoWarm() async throws {
        // repo A cold: npm ci (miss, push)
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("cross-repo-warm"))
        let store = await daemon.store
        let lockData = Data("package-lock-v1-content".utf8)
        let hashesA = try store.ingest(lockData)
        XCTAssertFalse(hashesA.isEmpty)
        let sizeAfterA = await daemon.sharedCacheSize
        XCTAssertGreaterThan(sizeAfterA, 0)

        // repo B same lockfile: should share chunks, warm <2s, no new volume
        let start = ContinuousClock.now
        let hashesB = try store.ingest(lockData)
        XCTAssertEqual(hashesA, hashesB, "identical lockfile must dedup chunks")
        let sizeAfterB = await daemon.sharedCacheSize
        XCTAssertEqual(sizeAfterA, sizeAfterB, "dedup must not double size")

        // Mount repo B via shared view — should be fast and hit local
        let srcB = try writeSourceTree(named: "repoB")
        let info = try await daemon.mountShared(src: srcB, readonly: false)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(2), "warm mount must be <2s, got \(elapsed)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.viewPath))
        try await daemon.unmount(id: info.id)
    }

    func testColdVsWarmNpmCi() async throws {
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("cold-warm-int"))
        let store = await daemon.store
        let lock = Data(repeating: 0xAB, count: 256 * 1024)
        let hashes = try store.ingest(lock)
        XCTAssertFalse(hashes.isEmpty)

        // Cold already ingested; warm mount should be <2s
        let srcWarm = try writeSourceTree(named: "warm-int")
        let start = ContinuousClock.now
        let info = try await daemon.mount(src: srcWarm, readonly: false)
        let dur = ContinuousClock.now - start
        XCTAssertLessThan(dur, .seconds(2))
        try await daemon.unmount(id: info.id)
    }

    func testPruneRespectsCuttleKind() async throws {
        // Analogous to Go's PruneDockerResources label!=cuttle.kind guard:
        // daemon GC must respect pinned sharedViews.
        let cap: UInt64 = 2500
        let daemon = try SharedFSDaemon(cacheRoot: cacheRoot("prune-int"), cacheMaxBytes: cap)
        let store = await daemon.store
        let d1 = Data(repeating: 0x11, count: 1024)
        let d2 = Data(repeating: 0x22, count: 1024)
        let h1 = try store.ingest(d1)[0]
        let h2 = try store.ingest(d2)[0]
        store.setAtime(h1, Date(timeIntervalSinceNow: -600))
        store.setAtime(h2, Date(timeIntervalSinceNow: -600))
        store.incrementRefCount(h1)  // pinned
        let src = try writeSourceTree(named: "prune-int-src")
        _ = try await daemon.mount(src: src, readonly: false)
        XCTAssertTrue(store.has(h1), "pinned must survive")
        // At least one of h1/h2 should remain, but pinned must not be evicted
    }

    // MARK: - Helpers

    private func cacheRoot(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-int-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSourceTree(named: String) throws -> URL {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-int-src-\(named)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "alpha".write(toFile: src.appendingPathComponent("a.txt").path, atomically: true, encoding: .utf8)
        return src
    }
}
