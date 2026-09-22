import Foundation
import MicropodCore

/// Read-through cache for the shim's hottest read paths (`list`, `inspect`).
///
/// Every Docker client polls: `docker ps` loops, compose re-lists per
/// operation, testcontainers lists per wait cycle, the runner stats-loops.
/// Each miss costs a full `container` CLI spawn (~15-85 ms); hits cost
/// microseconds. The cache is correct by construction:
///
/// - Full results are cached (never filtered views), so per-request label
///   filters apply identically on hits and misses.
/// - Every mutation through THIS shim invalidates synchronously before
///   responding (create/delete/start/stop/kill → containers; pull/push/
///   build/delete/tag → images), so a client can never read stale data it
///   just wrote (the Ryuk list-after-create pattern).
/// - Out-of-band changes (another client, direct CLI use) are picked up by
///   the EventsHub poll loop, which invalidates on any observed transition;
///   the TTL bounds the remainder (default 1 s).
///
/// Disabled with MICROPOD_SHIM_CACHE_DISABLE=1. TTL honors
/// MICROPOD_SHIM_CACHE_TTL_MS (default 1000).
actor ReadThroughCache {
    struct Entry: Sendable {
        var value: [Micropod_V1_Container]
        var expiresAt: Date
    }

    struct ImageEntry: Sendable {
        var value: [Micropod_V1_Image]
        var expiresAt: Date
    }

    struct VolumeEntry: Sendable {
        var value: [Micropod_V1_Volume]
        var expiresAt: Date
    }

    private var containersAll: Entry?
    private var containersByID: [String: Entry] = [:]
    private var imagesAll: ImageEntry?
    private var volumesAll: VolumeEntry?
    /// Encoded response bodies for hot filter-less reads
    /// (key "containers:true", "containers:false", "images"). Same TTL and
    /// invalidation as the model entries; skips per-request map+encode
    /// (~8 ms for 40+ containers).
    private var bodies: [String: (data: Data, expiresAt: Date)] = [:]
    private let ttl: TimeInterval
    private let disabled: Bool

    /// Hits/misses for observability (logged on eviction pressure only —
    /// per-request logging would spam).
    private(set) var hits = 0
    private(set) var misses = 0

    init(ttl: TimeInterval? = nil, disabled: Bool? = nil) {
        let env = ProcessInfo.processInfo.environment
        if let ttl {
            self.ttl = ttl
        } else if let raw = env["MICROPOD_SHIM_CACHE_TTL_MS"], let ms = Double(raw) {
            self.ttl = max(ms / 1000, 0.05)
        } else {
            self.ttl = 1.0
        }
        if let disabled {
            self.disabled = disabled
        } else {
            self.disabled = env["MICROPOD_SHIM_CACHE_DISABLE"] == "1"
        }
    }

    var isDisabled: Bool { disabled }

    // MARK: - Containers

    func cachedList(now: Date = Date()) -> [Micropod_V1_Container]? {
        guard !disabled, let entry = containersAll, entry.expiresAt > now else {
            if !disabled { misses += 1 }
            return nil
        }
        hits += 1
        return entry.value
    }

    func storeList(_ list: [Micropod_V1_Container], now: Date = Date()) {
        guard !disabled else { return }
        containersAll = Entry(value: list, expiresAt: now.addingTimeInterval(ttl))
        // Single-container entries share the list's freshness window.
        for container in list {
            containersByID[container.id] = Entry(value: [container], expiresAt: now.addingTimeInterval(ttl))
        }
    }

    func cachedInspect(id: String, now: Date = Date()) -> Micropod_V1_Container? {
        guard !disabled, let entry = containersByID[id], entry.expiresAt > now else {
            if !disabled { misses += 1 }
            return nil
        }
        hits += 1
        return entry.value.first
    }

    func storeInspect(_ container: Micropod_V1_Container, now: Date = Date()) {
        guard !disabled else { return }
        containersByID[container.id] = Entry(
            value: [container], expiresAt: now.addingTimeInterval(ttl))
    }

    /// Any container mutation (create/delete/start/stop/kill/rename).
    /// Drops the whole container namespace: per-id entries could disagree
    /// with the list otherwise (e.g. a renamed id listed under two names).
    func invalidateContainers() {
        containersAll = nil
        containersByID.removeAll(keepingCapacity: true)
        bodies = bodies.filter { !$0.key.hasPrefix("containers") }
    }

    // MARK: - Images

    func cachedImages(now: Date = Date()) -> [Micropod_V1_Image]? {
        guard !disabled, let entry = imagesAll, entry.expiresAt > now else {
            if !disabled { misses += 1 }
            return nil
        }
        hits += 1
        return entry.value
    }

    func storeImages(_ list: [Micropod_V1_Image], now: Date = Date()) {
        guard !disabled else { return }
        imagesAll = ImageEntry(value: list, expiresAt: now.addingTimeInterval(ttl))
    }

    /// Any image mutation (pull/push/build/delete/tag/prune).
    func invalidateImages() {
        imagesAll = nil
        bodies = bodies.filter { !$0.key.hasPrefix("images") }
    }

    // MARK: - Volumes

    func cachedVolumes(now: Date = Date()) -> [Micropod_V1_Volume]? {
        guard !disabled, let entry = volumesAll, entry.expiresAt > now else {
            if !disabled { misses += 1 }
            return nil
        }
        hits += 1
        return entry.value
    }

    func storeVolumes(_ list: [Micropod_V1_Volume], now: Date = Date()) {
        guard !disabled else { return }
        volumesAll = VolumeEntry(value: list, expiresAt: now.addingTimeInterval(ttl))
    }

    /// Any volume mutation (create/delete/prune).
    func invalidateVolumes() {
        volumesAll = nil
    }

    /// Encoded-body fast path for filter-less reads.
    func cachedBody(_ key: String, now: Date = Date()) -> Data? {
        guard !disabled, let entry = bodies[key], entry.expiresAt > now else {
            return nil
        }
        hits += 1
        return entry.data
    }

    func storeBody(_ data: Data, for key: String, now: Date = Date()) {
        guard !disabled else { return }
        bodies[key] = (data, now.addingTimeInterval(ttl))
    }

    func stats() -> (hits: Int, misses: Int) { (hits, misses) }
}
