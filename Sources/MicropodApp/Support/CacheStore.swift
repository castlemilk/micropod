import Foundation
import MicropodSharedFS
import Observation

struct CacheSnapshot: Sendable {
    let measuredAt: Date
    let buildRoot: URL
    let buildEntries: [BuildManifest]
    let buildStats: BuildCacheStats
    let buildDisabled: Bool
    let buildError: String?
    let package: SharedCacheSnapshot?
    let packageError: String?
}

/// One shared snapshot for the window and tray. Disk reads run outside
/// the main actor; concurrent observers share the same refresh task.
@MainActor
@Observable
final class CacheStore {
    private(set) var snapshot: CacheSnapshot?
    private(set) var isRefreshing = false
    private(set) var isMutating = false
    private(set) var error: String?
    private(set) var cleanupReview: SharedCacheCleanupReview?
    private(set) var lastCleanup: GCResult?

    @ObservationIgnored private let buildRoot: URL
    @ObservationIgnored private let client: any SharedFSClient
    @ObservationIgnored private var refreshTask: Task<CacheSnapshot, Never>?
    @ObservationIgnored private let refreshInterval: TimeInterval
    @ObservationIgnored private var isPreview = false

    init(
        buildRoot: URL = BuildCacheStore.standardRoot(),
        client: (any SharedFSClient)? = nil,
        refreshInterval: TimeInterval = 10
    ) {
        self.buildRoot = buildRoot
        self.refreshInterval = refreshInterval
        let socket =
            ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_SOCKET"]
            ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
        self.client = client ?? UnixSocketClient(socketPath: socket, timeout: 5)
    }

    func refresh(force: Bool = false) async {
        guard !isPreview else { return }
        if let refreshTask {
            _ = await refreshTask.value
            return
        }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.measuredAt) < refreshInterval { return }
        isRefreshing = true
        let root = buildRoot
        let cacheClient = client
        let task = Task.detached(priority: .utility) {
            let cap = BuildCacheStore.capBytes()
            var entries: [BuildManifest] = []
            var stats = BuildCacheStats(entries: 0, contentBytes: 0, sharedBytes: 0, capBytes: cap)
            var buildError: String?
            if FileManager.default.fileExists(atPath: root.path) {
                do {
                    // Distinguish unreadable roots from an empty cache. The
                    // manifest scan itself tolerates concurrent eviction.
                    _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    let scanned = BuildCacheStore.scan(root: root)
                    entries = scanned.manifests.sorted { $0.storedAt > $1.storedAt }
                    stats = scanned.stats
                } catch {
                    buildError = "Build contexts could not be read: \(error.localizedDescription)"
                }
            }
            let package: SharedCacheSnapshot?
            let packageError: String?
            do {
                package = try await cacheClient.cacheSnapshot()
                packageError = nil
            } catch {
                package = nil
                packageError =
                    "Package cache is unavailable. Start the shared cache agent, or update it if already running."
            }
            return CacheSnapshot(
                measuredAt: Date(), buildRoot: root, buildEntries: entries, buildStats: stats,
                buildDisabled: BuildCacheStore.disabled(), buildError: buildError,
                package: package, packageError: packageError)
        }
        refreshTask = task
        snapshot = await task.value
        refreshTask = nil
        isRefreshing = false
    }

    func reviewCleanup() async {
        guard !isMutating, !isPreview else { return }
        isMutating = true
        error = nil
        lastCleanup = nil
        do {
            cleanupReview = try await client.reviewCacheCleanup()
        } catch {
            cleanupReview = nil
            self.error = "Could not review package cache cleanup: \(error.localizedDescription)"
        }
        isMutating = false
    }

    func cleanReviewedCache() async {
        guard !isMutating, !isPreview, let review = cleanupReview, review.blockedReason == nil else { return }
        isMutating = true
        error = nil
        cleanupReview = nil
        do {
            lastCleanup = try await client.cleanReviewedCache(id: review.id)
        } catch {
            self.error = "Package cache cleanup did not complete: \(error.localizedDescription)"
        }
        isMutating = false
        await refresh(force: true)
    }

    func setKeepEnabled(_ enabled: Bool) async {
        guard !isMutating, !isPreview else { return }
        isMutating = true
        error = nil
        cleanupReview = nil
        do {
            try await client.setCacheKeepEnabled(enabled)
        } catch {
            self.error = "Could not change package cache retention: \(error.localizedDescription)"
        }
        isMutating = false
        await refresh(force: true)
    }

    func dismissCleanupReview() { cleanupReview = nil }

    /// Used by deterministic native previews; never scans the user's
    /// cache directories or connects to the shared-cache agent.
    func applyForPreview(_ snapshot: CacheSnapshot, review: SharedCacheCleanupReview? = nil) {
        isPreview = true
        self.snapshot = snapshot
        cleanupReview = review
    }
}
