import Foundation
import MicropodSharedFS
import Observation
import XCTest

@testable import MicropodApp

final class ForcedCacheRefreshTests: XCTestCase {
    @MainActor
    func testKeepMutationWaitsForASnapshotStartedAfterTheMutation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GatedCacheClient()
        let cache = CacheStore(buildRoot: root, client: client, refreshInterval: 60)
        defer {
            cache.cancelRefresh()
            Task { await client.releaseFirstRead() }
        }

        let oldRead = Task { await cache.refresh() }
        try await waitForClient(client) { await $0.snapshotCalls == 1 }
        let mutation = Task { await cache.setKeepEnabled(true) }
        try await waitForClient(client) { await $0.keepEnabled }
        try await waitUntil { !cache.isMutating }
        await client.releaseFirstRead()
        await oldRead.value
        await mutation.value

        XCTAssertEqual(cache.snapshot?.package?.keepEnabled, true, "An older snapshot must not undo the Keep switch")
        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(cache.isRefreshing)
        XCTAssertFalse(cache.isMutating)
        XCTAssertNil(cache.error)
        await cache.refresh()
        let throttledCalls = await client.snapshotCalls
        XCTAssertEqual(throttledCalls, 2)
    }

    @MainActor
    func testCleanupRefreshesBytesAfterAnOlderSnapshotWasCaptured() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GatedCacheClient()
        let cache = CacheStore(buildRoot: root, client: client)
        defer {
            cache.cancelRefresh()
            Task { await client.releaseFirstRead() }
        }

        await cache.reviewCleanup()
        XCTAssertNotNil(cache.cleanupReview)
        let oldRead = Task { await cache.refresh() }
        try await waitForClient(client) { await $0.snapshotCalls == 1 }
        let mutation = Task { await cache.cleanReviewedCache() }
        try await waitForClient(client) { await $0.storedBytes == 0 }
        try await waitUntil { !cache.isMutating && cache.lastCleanup != nil }
        await client.releaseFirstRead()
        await oldRead.value
        await mutation.value

        XCTAssertEqual(cache.lastCleanup?.bytesReclaimed, 1024)
        XCTAssertEqual(cache.snapshot?.package?.storedBytes, 0, "Cleaned bytes must not reappear from the older read")
        XCTAssertEqual(cache.snapshot?.package?.chunkCount, 0)
        XCTAssertNil(cache.cleanupReview)
        XCTAssertNil(cache.error)
        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testForcedObserversBehindTheSameReadShareOneFreshSnapshot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GatedCacheClient()
        let cache = CacheStore(buildRoot: root, client: client)
        defer {
            cache.cancelRefresh()
            Task { await client.releaseFirstRead() }
        }

        let oldRead = Task { await cache.refresh() }
        try await waitForClient(client) { await $0.snapshotCalls == 1 }
        var started = 0
        let window = Task {
            started += 1
            await cache.refresh(force: true)
        }
        let tray = Task {
            started += 1
            await cache.refresh(force: true)
        }
        try await waitUntil { started == 2 }
        await client.releaseFirstRead()
        await oldRead.value
        await window.value
        await tray.value

        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 2, "Both forced callers require the same next read, not one extra read per observer")
    }

    @MainActor
    func testCancelledOldReadCannotReplaceANewerSnapshotOrRestartAQueuedForce() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GatedCacheClient()
        let cache = CacheStore(buildRoot: root, client: client)
        defer {
            cache.cancelRefresh()
            Task { await client.releaseFirstRead() }
        }

        let oldRead = Task { await cache.refresh() }
        try await waitForClient(client) { await $0.snapshotCalls == 1 }
        var forceStarted = false
        let forcedRead = Task {
            forceStarted = true
            await cache.refresh(force: true)
        }
        try await waitUntil { forceStarted }
        cache.cancelRefresh()
        XCTAssertFalse(cache.isRefreshing)
        XCTAssertNil(cache.snapshot)
        try await client.setCacheKeepEnabled(true)
        await cache.refresh(force: true)
        XCTAssertEqual(cache.snapshot?.package?.keepEnabled, true)

        // The fixture deliberately completes its captured old result despite
        // cancellation, as a disk read or IPC implementation may do.
        await client.releaseFirstRead()
        await oldRead.value
        await forcedRead.value
        XCTAssertEqual(cache.snapshot?.package?.keepEnabled, true)
        XCTAssertFalse(cache.isRefreshing)
        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 2, "A cancelled waiter must not revive the old refresh after the replacement completes")
    }

    @MainActor
    func testCancellingAForcedObserverDoesNotCancelSharedWorkOrStartAFollowup() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GatedCacheClient()
        let cache = CacheStore(buildRoot: root, client: client)
        defer {
            cache.cancelRefresh()
            Task { await client.releaseFirstRead() }
        }

        let oldRead = Task { await cache.refresh() }
        try await waitForClient(client) { await $0.snapshotCalls == 1 }
        var forceStarted = false
        let forcedRead = Task {
            forceStarted = true
            await cache.refresh(force: true)
        }
        try await waitUntil { forceStarted }
        forcedRead.cancel()
        await client.releaseFirstRead()
        await oldRead.value
        await forcedRead.value

        XCTAssertNotNil(cache.snapshot, "The other observer must still receive the shared read")
        XCTAssertFalse(cache.isRefreshing)
        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 1, "A cancelled forced observer must not add another read")
    }

    @MainActor
    func testCancellationAfterProducerClearsItsHandleStopsQueuedForcedObservers() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GatedCacheClient()
        let cache = CacheStore(buildRoot: root, client: client)
        defer {
            cache.cancelRefresh()
            Task { await client.releaseFirstRead() }
        }

        let oldRead = Task { await cache.refresh() }
        try await waitForClient(client) { await $0.snapshotCalls == 1 }
        var forceStarted = false
        let forcedRead = Task {
            forceStarted = true
            await cache.refresh(force: true)
        }
        try await waitUntil { forceStarted }
        XCTAssertTrue(cache.isRefreshing)
        let completion = RefreshCompletionProbe()
        // Completion clears the task handle before changing isRefreshing.
        // Observation fires synchronously at that change, before awaiters resume.
        // Its callback is removed after returning, so guard reentrant changes
        // made by cancellation itself before entering the checkpoint action.
        withObservationTracking {
            _ = cache.isRefreshing
        } onChange: {
            MainActor.assumeIsolated {
                guard !completion.reached else { return }
                completion.reached = true
                cache.cancelRefresh()
            }
        }
        await client.releaseFirstRead()
        await oldRead.value
        await forcedRead.value

        XCTAssertTrue(completion.reached, "The producer must reach the deterministic cancellation checkpoint")
        XCTAssertFalse(cache.isRefreshing)
        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 1, "Stopping after handle cleanup must still invalidate queued forced observers")

        await cache.refresh(force: true)
        let restartedCalls = await client.snapshotCalls
        XCTAssertEqual(restartedCalls, 2, "An explicit request after cancellation may start a new refresh")
    }

    @MainActor
    func testEnteringPreviewAfterProducerCompletesPreventsQueuedRealIO() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GatedCacheClient()
        let cache = CacheStore(buildRoot: root, client: client)
        defer {
            cache.cancelRefresh()
            Task { await client.releaseFirstRead() }
        }
        let preview = CacheSnapshot(
            measuredAt: .distantPast, buildRoot: root, buildEntries: [], buildStats: .empty,
            buildDisabled: false, buildError: nil, package: nil, packageError: nil)

        let oldRead = Task { await cache.refresh() }
        try await waitForClient(client) { await $0.snapshotCalls == 1 }
        var forceStarted = false
        let forcedRead = Task {
            forceStarted = true
            await cache.refresh(force: true)
        }
        try await waitUntil { forceStarted }
        let completion = RefreshCompletionProbe()
        withObservationTracking {
            _ = cache.isRefreshing
        } onChange: {
            MainActor.assumeIsolated {
                guard !completion.reached else { return }
                completion.reached = true
                cache.applyForPreview(preview)
            }
        }
        await client.releaseFirstRead()
        await oldRead.value
        await forcedRead.value
        await cache.refresh(force: true)

        XCTAssertTrue(completion.reached)
        XCTAssertEqual(cache.snapshot?.measuredAt, .distantPast, "A queued real read must not replace the preview")
        XCTAssertNil(cache.snapshot?.package)
        XCTAssertFalse(cache.isRefreshing)
        let calls = await client.snapshotCalls
        XCTAssertEqual(calls, 1, "Preview must suppress both queued and later real refresh requests")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cache-refresh-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func waitForClient(
        _ client: GatedCacheClient,
        _ condition: @Sendable (GatedCacheClient) async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await condition(client) { return }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw CacheRefreshTestTimeout()
    }
}

private struct CacheRefreshTestTimeout: Error {}

@MainActor
private final class RefreshCompletionProbe {
    var reached = false
}

private actor GatedCacheClient: SharedFSClient {
    private(set) var snapshotCalls = 0
    private(set) var keepEnabled = false
    private(set) var storedBytes: UInt64 = 1024
    private var firstRead: CheckedContinuation<Void, Never>?
    private var firstReadReleased = false

    func cacheSnapshot() async throws -> SharedCacheSnapshot {
        snapshotCalls += 1
        let snapshot = SharedCacheSnapshot(
            cacheRoot: "/isolated/package-cache", measuredAt: Date(), storedBytes: storedBytes, capBytes: 4096,
            chunkCount: storedBytes == 0 ? 0 : 1, activeMounts: [], keepEnabled: keepEnabled, overCap: false)
        if snapshotCalls == 1, !firstReadReleased {
            await withCheckedContinuation { firstRead = $0 }
        }
        return snapshot
    }

    func releaseFirstRead() {
        firstReadReleased = true
        firstRead?.resume()
        firstRead = nil
    }

    func setCacheKeepEnabled(_ enabled: Bool) async throws { keepEnabled = enabled }

    func reviewCacheCleanup() async throws -> SharedCacheCleanupReview {
        try JSONDecoder().decode(
            SharedCacheCleanupReview.self,
            from: Data(
                #"{"id":"cleanup","createdAt":0,"chunkCount":1,"storedBytes":1024,"protectedChunkCount":0}"#.utf8))
    }

    func cleanReviewedCache(id: String) async throws -> GCResult {
        guard id == "cleanup" else { throw SharedFSError.invalidResponse("Unknown cleanup review") }
        storedBytes = 0
        return try JSONDecoder().decode(GCResult.self, from: Data(#"{"chunksRemoved":1,"bytesReclaimed":1024}"#.utf8))
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
