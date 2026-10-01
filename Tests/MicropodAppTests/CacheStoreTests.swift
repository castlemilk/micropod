import Foundation
import MicropodSharedFS
import XCTest

@testable import MicropodApp

final class CacheStoreTests: XCTestCase {
    @MainActor
    func testRefreshCoalescesAndThrottlesWithoutHidingSeparateBudgets() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("packages"), cacheMaxBytes: 54321)
        let client = CountingCacheClient(snapshot: try await daemon.cacheSnapshot())
        let contexts = root.appendingPathComponent("contexts")
        let entry = contexts.appendingPathComponent(String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let manifest = BuildManifest(
            treeHash: entry.lastPathComponent,
            files: [BuildFileEntry(path: "Dockerfile", sha256: "content-hash", size: 1024)],
            tarBytes: 2048)
        try JSONEncoder().encode(manifest).write(to: entry.appendingPathComponent("manifest.json"))
        let cache = CacheStore(buildRoot: contexts, client: client, refreshInterval: 60)
        async let window: Void = cache.refresh()
        async let tray: Void = cache.refresh()
        _ = await (window, tray)
        let firstCalls = await client.snapshotCalls
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(cache.snapshot?.buildStats.entries, 1)
        XCTAssertEqual(cache.snapshot?.buildStats.contentBytes, 1024)
        XCTAssertEqual(cache.snapshot?.buildStats.capBytes, BuildCacheStore.capBytes())
        XCTAssertEqual(cache.snapshot?.package?.capBytes, 54321)
        XCTAssertFalse(cache.isRefreshing)
        await cache.refresh()
        let throttledCalls = await client.snapshotCalls
        XCTAssertEqual(throttledCalls, 1)
        await cache.refresh(force: true)
        let forcedCalls = await client.snapshotCalls
        XCTAssertEqual(forcedCalls, 2)
    }

    @MainActor
    func testUnavailablePackageAgentDoesNotHideReadableBuildContexts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("packages"))
        let client = CountingCacheClient(snapshot: try await daemon.cacheSnapshot(), unavailable: true)
        let cache = CacheStore(buildRoot: root.appendingPathComponent("no-contexts-yet"), client: client)
        await cache.refresh()
        XCTAssertEqual(cache.snapshot?.buildStats.entries, 0)
        XCTAssertNil(cache.snapshot?.buildError)
        XCTAssertNil(cache.snapshot?.package)
        XCTAssertNotNil(cache.snapshot?.packageError)
        XCTAssertFalse(cache.isRefreshing)
    }

    @MainActor
    func testPreviewNeverRefreshesOrMutatesRealCache() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SharedFSDaemon(cacheRoot: root.appendingPathComponent("packages"))
        let package = try await daemon.cacheSnapshot()
        let client = CountingCacheClient(snapshot: package)
        let cache = CacheStore(buildRoot: root, client: client)
        cache.applyForPreview(
            CacheSnapshot(
                measuredAt: .distantPast, buildRoot: root, buildEntries: [], buildStats: .empty,
                buildDisabled: false, buildError: nil, package: package, packageError: nil))
        await cache.refresh(force: true)
        await cache.setKeepEnabled(true)
        await cache.reviewCleanup()
        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(cache.snapshot?.measuredAt, .distantPast)
        XCTAssertNil(cache.cleanupReview)
        XCTAssertNil(cache.error)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor CountingCacheClient: SharedFSClient {
    private let snapshot: SharedCacheSnapshot
    private let unavailable: Bool
    private(set) var snapshotCalls = 0

    init(snapshot: SharedCacheSnapshot, unavailable: Bool = false) {
        self.snapshot = snapshot
        self.unavailable = unavailable
    }

    func cacheSnapshot() async throws -> SharedCacheSnapshot {
        snapshotCalls += 1
        try await Task.sleep(nanoseconds: 25_000_000)
        if unavailable { throw SharedFSError.daemonUnavailable }
        return snapshot
    }

    func mount(src: URL, readonly: Bool) async throws -> MountInfo { throw SharedFSError.daemonUnavailable }
    func mountShared(src: URL, readonly: Bool) async throws -> MountInfo { throw SharedFSError.daemonUnavailable }
    func unmount(id: ViewID) async throws { throw SharedFSError.daemonUnavailable }
    func inspect(id: ViewID) async throws -> MountInfo { throw SharedFSError.daemonUnavailable }
    func sync(id: ViewID) async throws -> SyncResult { throw SharedFSError.daemonUnavailable }
    func refresh(id: ViewID) async throws -> MountInfo { throw SharedFSError.daemonUnavailable }
    func list() async throws -> [MountInfo] { throw SharedFSError.daemonUnavailable }
    func gc() async throws -> GCResult { throw SharedFSError.daemonUnavailable }
}
