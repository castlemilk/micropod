import Foundation
import Network

/// The daemon's authoritative state: chunk store + active views + watcher.
/// One process, one state. The unix socket is just transport.
public actor SharedFSDaemon: SharedFSClient {
    public let cacheRoot: URL
    public let viewsRoot: URL
    public let store: ChunkStore
    /// Per-runner cap: 10GB global LRU (RUNNER_CACHE_MAX_BYTES, default 10<<30).
    public let cacheMaxBytes: UInt64
    /// Gauge `shared_cache_pinned_over_cap`: 1 when still over cap after eviction because all remaining are pinned.
    public private(set) var sharedCachePinnedOverCap: Int = 0
    /// Synchronous indexed size via store index (no `du`).
    public var sharedCacheSize: UInt64 { store.indexedSize }
    // MARK: - Metrics: shared_cache_* observables (mirrors cuttlefish runner)
    public private(set) var localHits: Int = 0
    public private(set) var remoteHits: Int = 0
    public private(set) var misses: Int = 0
    public private(set) var gcsPushErrors: Int = 0
    public private(set) var evictedChunksTotal: Int = 0
    private let gracePeriod: TimeInterval = 300 // 5m grace
    private var sweepTask: Task<Void, Never>?
    private var views: [ViewID: SharedView] = [:]
    // Live shared mounts: one view per src, bidirectional sync for live writes.
    private var sharedViews: [String: SharedView] = [:]
    private var sharedWatchers: [String: (srcWatcher: FSEventsWatcher, viewWatcher: FSEventsWatcher)] =
        [:]
    private var sharedRefCounts: [String: Int] = [:]
    // Per-container live sync via host hub
    private var viewsBySrc: [String: Set<ViewID>] = [:]
    private var viewWatchers: [ViewID: FSEventsWatcher] = [:]
    private var srcWatchers: [String: FSEventsWatcher] = [:]

    public init(cacheRoot: URL, cacheMaxBytes: UInt64? = nil) throws {
        self.cacheRoot = cacheRoot
        self.viewsRoot = cacheRoot.appendingPathComponent("views", isDirectory: true)
        self.store = try ChunkStore(root: cacheRoot.appendingPathComponent("chunks", isDirectory: true))
        try FileManager.default.createDirectory(at: viewsRoot, withIntermediateDirectories: true)
        if let cacheMaxBytes {
            self.cacheMaxBytes = cacheMaxBytes
        } else if let env = ProcessInfo.processInfo.environment["RUNNER_CACHE_MAX_BYTES"],
            let parsed = UInt64(env)
        {
            self.cacheMaxBytes = parsed
        } else {
            self.cacheMaxBytes = 10 << 30 // 10GB default
        }
        // DiskManager integration: async 5m sweep (same interval as sweepOrphanedVolumes).
        // Start background sweep; not awaited, runs for daemon lifetime.
        // Use detached task to avoid actor isolation deadlock during init.
        Task.detached { [weak self] in
            guard let self else { return }
            await self.startSweepLoop()
        }
    }

    private func startSweepLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5m
            _ = await enforceStorageCapIfNeeded()
            // Also run orphan-volume style sweep if needed (disk hygiene).
            try? await sweepOrphanedIfNeeded()
        }
    }

    /// DiskManager hook: placeholder for sweepOrphanedVolumes integration.
    /// In micropod the equivalent is `gc()` on idle views; we expose for observability.
    public func sweepOrphanedIfNeeded() async throws {
        // For now, enforce cap also covers orphan sweep. Real DiskManager
        // would age-gate cf-cache-* volumes; here we just log.
        _ = await enforceStorageCapIfNeeded()
    }

    // MARK: - Storage cap (indexed size gate + LRU eviction)

    /// Enforced *before* next mount (synchronous indexed-size check via store metadata, no `du`)
    /// and via async 5m sweep. LRU-evict oldest chunks (by atime, refCount==0, 5m grace) until under cap;
    /// if still over and all remaining are pinned or <5m old, bypass grace and evict oldest refCount==0 anyway;
    /// emit `shared_cache_pinned_over_cap` gauge if still over.
    @discardableResult
    public func enforceStorageCapIfNeeded() async -> GCResult {
        let cap = cacheMaxBytes
        var removed = 0
        var reclaimed: UInt64 = 0
        // Fast path: already under cap
        if store.indexedSize <= cap {
            sharedCachePinnedOverCap = 0
            return GCResult(chunksRemoved: 0, bytesReclaimed: 0)
        }
        // Collect live pinned chunks from active views (view-backed pinning)
        var livePinned: Set<String> = []
        for view in views.values {
            let hashes = await chunksInUse(view: view.root)
            livePinned.formUnion(hashes)
        }
        for view in sharedViews.values {
            let hashes = await chunksInUse(view: view.root)
            livePinned.formUnion(hashes)
        }

        let now = Date()
        let graceCutoff = now.addingTimeInterval(-gracePeriod)

        // Build mutable list of candidates from store index
        // Use store's internal tracking; we need atime/size/refCount per hash.
        // To avoid exposing internals, we enumerate all chunk files and query store metadata.
        var didEvict = true
        while store.indexedSize > cap, didEvict {
            didEvict = false
            let allHashes = store.allChunkHashes()
            if allHashes.isEmpty { break }
            struct Candidate {
                let hash: ChunkHash
                let atime: Date
                let size: UInt64
                let refCount: Int
                let isLivePinned: Bool
            }
            var candidates: [Candidate] = []
            for h in allHashes {
                let atime = store.atime(for: h) ?? Date.distantPast
                let size = store.chunkSize(h) ?? 0
                let rc = store.refCount(for: h)
                let live = livePinned.contains(h.value)
                candidates.append(Candidate(hash: h, atime: atime, size: size, refCount: rc, isLivePinned: live))
            }
            // Sort by atime oldest first for deterministic LRU
            candidates.sort { $0.atime < $1.atime }

            // Phase 1: grace-respecting candidates (refCount==0 && !livePinned && atime < graceCutoff)
            var chosen: Candidate?
            for c in candidates where c.refCount == 0 && !c.isLivePinned && c.atime < graceCutoff {
                chosen = c
                break
            }
            // Phase 2: bypass grace if still over cap — evict oldest refCount==0 anyway
            if chosen == nil {
                for c in candidates where c.refCount == 0 && !c.isLivePinned {
                    chosen = c
                    break
                }
            }
            if let victim = chosen {
                do {
                    try store.remove(victim.hash)
                    removed += 1
                    reclaimed += victim.size
                    didEvict = true
                    fputs("[sharedfs] evicted \(victim.hash.value.prefix(12)) size \(victim.size) atime \(victim.atime) (cap \(cap) size \(store.indexedSize))\n", stderr)
                } catch {
                    fputs("[sharedfs] evict failed \(victim.hash.value): \(error)\n", stderr)
                    break
                }
            } else {
                // No evictable candidates — all remaining are pinned
                break
            }
        }
        if store.indexedSize > cap {
            sharedCachePinnedOverCap = 1
            fputs("[sharedfs] shared_cache_pinned_over_cap=1 size \(store.indexedSize) cap \(cap)\n", stderr)
        } else {
            sharedCachePinnedOverCap = 0
        }
        if removed > 0 {
            fputs("[sharedfs] storage cap enforced: removed \(removed) chunks, reclaimed \(reclaimed) bytes, size now \(store.indexedSize) cap \(cap)\n", stderr)
            evictedChunksTotal += removed
        }
        return GCResult(chunksRemoved: removed, bytesReclaimed: reclaimed)
    }

    // MARK: - Metrics (shared_cache_*)

    /// Records a cache lookup outcome for `shared_cache_hit_total{hit="local|remote|miss"}`.
    @discardableResult
    public func recordCacheHit(hit: String, hash: ChunkHash) -> Int {
        switch hit {
        case "local":
            localHits += 1
            return localHits
        case "remote":
            remoteHits += 1
            return remoteHits
        case "miss":
            misses += 1
            return misses
        default:
            misses += 1
            return misses
        }
    }

    /// Records a GCS push error for `gcs_push_errors_total`.
    public func recordGCSPushError() {
        gcsPushErrors += 1
    }

    /// Returns the current shared-cache observable set, mirroring the Go
    /// RunnerMetric names: shared_cache_hit_total{hit="..."}, shared_cache_bytes,
    /// evicted_chunks_total, gcs_push_errors_total, shared_views_pinned.
    public func cacheMetrics() -> [String: Int] {
        // shared_views_pinned = active sharedViews count (pinned)
        let pinned = sharedViews.count + views.count // approx
        return [
            "shared_cache_hit_total_local": localHits,
            "shared_cache_hit_total_remote": remoteHits,
            "shared_cache_hit_total_miss": misses,
            "shared_cache_bytes": Int(sharedCacheSize),
            "evicted_chunks_total": evictedChunksTotal,
            "gcs_push_errors_total": gcsPushErrors,
            "shared_views_pinned": pinned,
            "shared_cache_pinned_over_cap": sharedCachePinnedOverCap,
        ]
    }

    // MARK: - SharedFSClient

    public func mount(src: URL, readonly: Bool) async throws -> MountInfo {
        // Enforce storage cap before next mount (synchronous indexed-size check, no du)
        _ = await enforceStorageCapIfNeeded()
        let normalized = src.resolvingSymlinksInPath().standardizedFileURL
        let id = ViewID.generate()
        let viewRoot = viewsRoot.appendingPathComponent(id.value, isDirectory: true)
        try SharedView.build(source: normalized, root: viewRoot)
        let view = SharedView(id: id, source: normalized, root: viewRoot)
        views[id] = view
        viewsBySrc[normalized.path, default: []].insert(id)
        ensureWatchers(for: normalized, view: view)
        fputs("[sharedfs] mount \(normalized.path) -> \(viewRoot.path) (\(view.size()) bytes)\n", stderr)
        return MountInfo(
            id: id, src: normalized.path, viewPath: viewRoot.path,
            sizeBytes: view.size(), readonly: readonly, createdAt: view.createdAt)
    }

    public func mountShared(src: URL, readonly: Bool) async throws -> MountInfo {
        // Enforce storage cap before next mount (synchronous, no du)
        _ = await enforceStorageCapIfNeeded()
        let normalized = src.resolvingSymlinksInPath().standardizedFileURL
        let key = normalized.path
        if let existing = sharedViews[key] {
            sharedRefCounts[key, default: 1] += 1
            fputs("[sharedfs] mountShared reuse \(key) -> \(existing.root.path)\n", stderr)
            return MountInfo(
                id: existing.id, src: key, viewPath: existing.root.path,
                sizeBytes: existing.size(), readonly: readonly,
                createdAt: existing.createdAt)
        }
        // Deterministic ID for shared view (so restarts can re-derive).
        let hash = (try? ChunkHash.compute(Data(key.utf8)))?.value.prefix(12) ?? Substring(UUID().uuidString.prefix(12))
        let id = ViewID(String(hash))
        let viewRoot = viewsRoot.appendingPathComponent("shared-\(id.value)", isDirectory: true)
        // Clean stale view dir if any.
        if FileManager.default.fileExists(atPath: viewRoot.path) {
            try? FileManager.default.removeItem(at: viewRoot)
        }
        try SharedView.build(source: normalized, root: viewRoot)
        let view = SharedView(id: id, source: normalized, root: viewRoot)
        sharedViews[key] = view
        sharedRefCounts[key] = 1
        // Also register in views for list/inspect visibility.
        views[id] = view
        startSharedWatchers(src: normalized, view: view)
        fputs("[sharedfs] mountShared \(key) -> \(viewRoot.path)\n", stderr)
        return MountInfo(
            id: id, src: key, viewPath: viewRoot.path,
            sizeBytes: view.size(), readonly: readonly, createdAt: view.createdAt)
    }

    /// Rebuild the view from the live source. Called explicitly by clients
    /// (and auto-invoked on mount if any FSEvents have fired since the last
    /// build — see `mount`).
    public func refresh(id: ViewID) async throws -> MountInfo {
        guard let view = views[id] else {
            throw SharedFSError.daemonUnavailable
        }
        try SharedView.build(source: view.source, root: view.root)
        return MountInfo(
            id: id, src: view.source.path, viewPath: view.root.path,
            sizeBytes: view.size(), readonly: false, createdAt: view.createdAt)
    }

    public func unmount(id: ViewID) async throws {
        // Shared view path: ref-counted, only destroyed when last user leaves.
        if let sharedKey = sharedViews.first(where: { $0.value.id == id })?.key {
            let remaining = (sharedRefCounts[sharedKey] ?? 1) - 1
            if remaining <= 0 {
                sharedWatchers[sharedKey]?.srcWatcher.stop()
                sharedWatchers[sharedKey]?.viewWatcher.stop()
                sharedWatchers.removeValue(forKey: sharedKey)
                if let sharedView = sharedViews[sharedKey] { try? sharedView.destroy() }
                sharedViews.removeValue(forKey: sharedKey)
                sharedRefCounts.removeValue(forKey: sharedKey)
                views.removeValue(forKey: id)
            } else {
                sharedRefCounts[sharedKey] = remaining
                // Keep the view alive for other containers; just forget the
                // per-container mapping (viewsBySrc not used for shared).
            }
            return
        }
        guard let view = views[id] else { return }
        viewWatchers[view.id]?.stop()
        viewWatchers.removeValue(forKey: view.id)
        if let srcKey = viewsBySrc.first(where: { $0.value.contains(view.id) })?.key {
            viewsBySrc[srcKey]?.remove(view.id)
            if viewsBySrc[srcKey]?.isEmpty == true {
                srcWatchers[srcKey]?.stop()
                srcWatchers.removeValue(forKey: srcKey)
                viewsBySrc.removeValue(forKey: srcKey)
            }
        }
        try view.destroy()
        views.removeValue(forKey: id)
    }

    public func inspect(id: ViewID) async throws -> MountInfo {
        guard let view = views[id] else {
            throw SharedFSError.daemonUnavailable
        }
        return MountInfo(
            id: id, src: view.source.path, viewPath: view.root.path,
            sizeBytes: view.size(), readonly: false, createdAt: view.createdAt)
    }

    public func sync(id: ViewID) async throws -> SyncResult {
        guard let view = views[id] else {
            throw SharedFSError.daemonUnavailable
        }
        let changed = try SharedView.syncToSource(view: view.root, source: view.source)
        let bytes = changed.reduce(0) { acc, url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { acc + UInt64($0 ?? 0) } ?? acc
        }
        return SyncResult(id: id, synced: changed.map { $0.path }, bytesWritten: bytes)
    }

    public func list() async throws -> [MountInfo] {
        views.values.map { view in
            MountInfo(
                id: view.id, src: view.source.path, viewPath: view.root.path,
                sizeBytes: view.size(), readonly: false, createdAt: view.createdAt)
        }
    }

    public func gc() async throws -> GCResult {
        // Reference count = sum of live views' file references. We do a
        // simple GC by counting how many store chunks each view references
        // (by walking and hashing), then removing anything not referenced.
        // Also keep indexedSize in sync via ChunkStore index (no du).
        var liveChunks: Set<String> = []
        for view in views.values {
            let chunkSet = await chunksInUse(view: view.root)
            for hash in chunkSet { liveChunks.insert(hash) }
        }
        // Use store index for size tracking; enumerate via store to keep index authoritative.
        let allHashes = store.allChunkHashes()
        // Also include any stray files not in index (e.g., pre-existing) by scanning filesystem.
        let fsNames = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
        var allNames = Set(allHashes.map { $0.value })
        allNames.formUnion(fsNames.filter { $0.count == 64 })
        var removed = 0
        var bytesReclaimed: UInt64 = 0
        for name in allNames where !liveChunks.contains(name) {
            let hash = ChunkHash(unchecked: name)
            let url = store.root.appendingPathComponent(name)
            let size = store.chunkSize(hash) ?? {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                if let s = attrs?[.size] as? UInt64 { return s }
                if let s = attrs?[.size] as? Int { return UInt64(s) }
                return UInt64(0)
            }()
            // Use store.remove to keep indexedSize consistent; check existence without bumping atime.
            let exists = store.exists(hash) || FileManager.default.fileExists(atPath: url.path)
            if exists {
                try? store.remove(hash)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            removed += 1
            bytesReclaimed += size
        }
        if removed > 0 {
            evictedChunksTotal += removed
        }
        return GCResult(chunksRemoved: removed, bytesReclaimed: bytesReclaimed)
    }

    // MARK: - Live sync internals (user-space, per-file, efficient)

    private func ensureWatchers(for src: URL, view: SharedView) {
        let realSrc = src.resolvingSymlinksInPath()
        let realView = view.root.resolvingSymlinksInPath()
        let key = realSrc.path
        if srcWatchers[key] == nil {
            let watcher = FSEventsWatcher(path: realSrc) { [weak self] paths in
                Task { [weak self] in await self?.handleSrcChange(paths: paths, src: realSrc) }
            }
            watcher.start()
            srcWatchers[key] = watcher
            fputs("[sharedfs] watching src \(key)\n", stderr)
        }
        let viewWatcher = FSEventsWatcher(path: realView) { [weak self] paths in
            Task { [weak self] in await self?.handleViewChange(paths: paths, view: view) }
        }
        viewWatcher.start()
        viewWatchers[view.id] = viewWatcher
        fputs("[sharedfs] watching view \(view.id.value) at \(realView.path)\n", stderr)
    }

    private func startSharedWatchers(src: URL, view: SharedView) {
        let realSrc = src.resolvingSymlinksInPath()
        let realView = view.root.resolvingSymlinksInPath()
        let key = realSrc.path
        let srcWatcher = FSEventsWatcher(path: realSrc) { [weak self] paths in
            Task { [weak self] in await self?.handleSrcChange(paths: paths, src: realSrc) }
        }
        srcWatcher.start()
        let viewWatcher = FSEventsWatcher(path: realView) { [weak self] paths in
            Task { [weak self] in await self?.handleViewChange(paths: paths, view: view) }
        }
        viewWatcher.start()
        sharedWatchers[key] = (srcWatcher, viewWatcher)
        fputs("[sharedfs] watching shared \(key) <-> \(realView.path)\n", stderr)
    }

    private func handleSrcChange(paths: [String], src: URL) async {
        let key = src.resolvingSymlinksInPath().path
        // Filter out atomic-write temp files (e.g., .sb-...) to avoid syncing
        // incomplete writes; the final file's event will arrive shortly after.
        let filtered = paths.filter {
            !$0.contains(".sb-") && !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".")
        }
        let effective = filtered.isEmpty ? paths.filter { !$0.contains(".sb-") } : filtered
        fputs("[sharedfs] src change \(effective.first ?? "?") (\(effective.count) paths)\n", stderr)
        var targetIDs = viewsBySrc[key] ?? []
        if let shared = sharedViews[key] { targetIDs.insert(shared.id) }
        guard !targetIDs.isEmpty else { return }
        for viewID in targetIDs {
            guard let view = views[viewID] ?? sharedViews[key] else { continue }
            for changed in effective {
                await syncFileChanged(at: changed, from: src, to: view.root)
            }
            // If FSEvents coalesced to a directory-only event, fall back to full tree for that dir
            if effective.allSatisfy({ $0 == key || $0.hasPrefix(key + "/") }) && effective.count == 1
                && effective.first == key
            {
                await syncTree(from: src, to: view.root)
            }
        }
    }

    private func handleViewChange(paths: [String], view: SharedView) async {
        let filtered = paths.filter {
            !$0.contains(".sb-") && !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".")
        }
        let effective = filtered.isEmpty ? paths.filter { !$0.contains(".sb-") } : filtered
        fputs("[sharedfs] view \(view.id.value) change \(effective.first ?? "?") (\(effective.count) paths)\n", stderr)
        for changed in effective {
            await syncFileChanged(at: changed, from: view.root, to: view.source)
        }
        // Host -> siblings (host as hub for cross-container)
        let key = view.source.resolvingSymlinksInPath().path
        let siblings = (viewsBySrc[key] ?? []).union(
            sharedViews[key].map { Set([$0.id]) } ?? [])
        for siblingID in siblings where siblingID != view.id {
            guard let sibling = views[siblingID] ?? sharedViews[key] else { continue }
            for changed in effective {
                await syncFileChanged(at: changed, from: view.root, to: sibling.root, viaRelativeFrom: view.root)
            }
        }
        // Directory-only event fallback
        if effective.allSatisfy({
            $0 == view.root.resolvingSymlinksInPath().path
                || $0.hasPrefix(view.root.resolvingSymlinksInPath().path + "/")
        }) && effective.count == 1 && effective.first == view.root.resolvingSymlinksInPath().path {
            await syncTree(from: view.root, to: view.source)
        }
    }

    private func syncTree(from srcRoot: URL, to dstRoot: URL) async {
        let realSrc = srcRoot.resolvingSymlinksInPath().standardized
        let realDst = dstRoot.resolvingSymlinksInPath().standardized
        var srcFiles: [String: URL] = [:]
        var dstFiles: [String: URL] = [:]
        if let e = FileManager.default.enumerator(
            at: realSrc, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        {
            for url in e.allObjects.compactMap({ $0 as? URL }) {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { continue }
                if url.lastPathComponent.contains(".sb-") || url.lastPathComponent.hasPrefix(".") { continue }
                let rel = relativePath(from: realSrc, to: url)
                srcFiles[rel] = url
            }
        }
        if let e = FileManager.default.enumerator(
            at: realDst, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        {
            for url in e.allObjects.compactMap({ $0 as? URL }) {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { continue }
                if url.lastPathComponent.contains(".sb-") || url.lastPathComponent.hasPrefix(".") { continue }
                let rel = relativePath(from: realDst, to: url)
                dstFiles[rel] = url
            }
        }
        for (rel, srcURL) in srcFiles {
            let dstURL = realDst.appendingPathComponent(rel)
            if let dstURLExisting = dstFiles[rel] {
                if let srcHash = try? ChunkHash.computeFile(srcURL),
                    let dstHash = try? ChunkHash.computeFile(dstURLExisting),
                    srcHash == dstHash
                {
                    continue
                }
            }
            do {
                try FileManager.default.createDirectory(
                    at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dstURL.path) {
                    try FileManager.default.removeItem(at: dstURL)
                }
                try cloneOrCopyFile(from: srcURL, to: dstURL)
            } catch {}
        }
        for (rel, dstURL) in dstFiles where srcFiles[rel] == nil {
            try? FileManager.default.removeItem(at: dstURL)
        }
    }

    private func cloneOrCopyFile(from src: URL, to dst: URL) throws {
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var done = false
        src.withUnsafeFileSystemRepresentation { s in
            dst.withUnsafeFileSystemRepresentation { d in
                guard let s, let d else { return }
                if clonefile(s, d, 0) == 0 { done = true }
            }
        }
        if done { return }
        let data = try Data(contentsOf: src)
        try data.write(to: dst, options: .atomic)
    }

    /// Efficient per-file sync: clonefile if same APFS volume, else copy.
    /// Checks content hash first to avoid loops (copying identical files is a no-op).
    private func syncFileChanged(
        at changedPath: String, from srcRoot: URL, to dstRoot: URL, viaRelativeFrom base: URL? = nil
    ) async {
        let realChanged = URL(fileURLWithPath: changedPath).resolvingSymlinksInPath().standardized.path
        let realBase = (base ?? srcRoot).resolvingSymlinksInPath().standardized.path
        guard realChanged.hasPrefix(realBase) else { return }
        let relative = String(realChanged.dropFirst(realBase.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        if relative.isEmpty { return }
        let realSrcRoot = srcRoot.resolvingSymlinksInPath().standardized
        let realDstRoot = dstRoot.resolvingSymlinksInPath().standardized
        let srcFile = realSrcRoot.appendingPathComponent(relative)
        let dstFile = realDstRoot.appendingPathComponent(relative)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: changedPath, isDirectory: &isDir)
        if !exists {
            try? FileManager.default.removeItem(at: dstFile)
            return
        }
        if isDir.boolValue {
            try? FileManager.default.createDirectory(at: dstFile, withIntermediateDirectories: true)
            return
        }
        // File: compare hashes before copying (loop avoidance + efficiency)
        if FileManager.default.fileExists(atPath: dstFile.path),
            let srcHash = try? ChunkHash.computeFile(srcFile),
            let dstHash = try? ChunkHash.computeFile(dstFile),
            srcHash == dstHash
        {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dstFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dstFile.path) {
                try FileManager.default.removeItem(at: dstFile)
            }
            // Prefer clonefile (CoW) for same-volume copies.
            let cloned = srcFile.withUnsafeFileSystemRepresentation { srcPtr in
                dstFile.withUnsafeFileSystemRepresentation { dstPtr in
                    guard let s = srcPtr, let d = dstPtr else { return Int32(-1) }
                    return clonefile(s, d, 0)
                }
            }
            if cloned != 0 {
                if FileManager.default.fileExists(atPath: srcFile.path) {
                    let data = try Data(contentsOf: srcFile)
                    try data.write(to: dstFile, options: .atomic)
                }
            }
        } catch {
            // Best-effort; FSEvents will retry on next change.
        }
    }

    /// Returns the set of chunk hashes a view's file contents resolve to,
    /// used for refcounted GC. The per-view tree is built from cloned chunks
    /// so the mapping is chunk→view; we walk and hash to recompute.
    private func chunksInUse(view: URL) async -> Set<String> {
        var chunks: Set<String> = []
        guard
            let enumerator = FileManager.default.enumerator(
                at: view, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return chunks }
        let urls = enumerator.allObjects.compactMap { $0 as? URL }
        for url in urls {
            if let size = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                size != true
            {
                continue
            }
            // Map the view file back to a chunk hash by reading its inode
            // via `lstat` and matching that to a chunk filename. Cheap because
            // chunks are filename = hash and APFS clonefile preserves the
            // source inode. We do a fast stat + readlink-free match against
            // the chunk store by content: just compute the digest and add.
            // (This is heavier than inode matching but the daemon runs
            // out-of-band on GC so it's fine; for hot paths we'd cache.)
            if let hash = try? ChunkHash.computeFile(url) {
                chunks.insert(hash.value)
            }
        }
        return chunks
    }
}
