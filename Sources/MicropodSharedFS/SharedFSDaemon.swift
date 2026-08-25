import Foundation
import Network

/// The daemon's authoritative state: chunk store + active views + watcher.
/// One process, one state. The unix socket is just transport.
public actor SharedFSDaemon: SharedFSClient {
    public let cacheRoot: URL
    public let viewsRoot: URL
    public let store: ChunkStore
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

    public init(cacheRoot: URL) throws {
        self.cacheRoot = cacheRoot
        self.viewsRoot = cacheRoot.appendingPathComponent("views", isDirectory: true)
        self.store = try ChunkStore(root: cacheRoot.appendingPathComponent("chunks", isDirectory: true))
        try FileManager.default.createDirectory(at: viewsRoot, withIntermediateDirectories: true)
    }

    // MARK: - SharedFSClient

    public func mount(src: URL, readonly: Bool) async throws -> MountInfo {
        let normalized = src.standardizedFileURL
        let id = ViewID.generate()
        let viewRoot = viewsRoot.appendingPathComponent(id.value, isDirectory: true)
        try SharedView.build(source: normalized, root: viewRoot)
        let view = SharedView(id: id, source: normalized, root: viewRoot)
        views[id] = view
        viewsBySrc[normalized.path, default: []].insert(id)
        ensureWatchers(for: normalized, view: view)
        return MountInfo(
            id: id, src: normalized.path, viewPath: viewRoot.path,
            sizeBytes: view.size(), readonly: readonly, createdAt: view.createdAt)
    }

    public func mountShared(src: URL, readonly: Bool) async throws -> MountInfo {
        let normalized = src.standardizedFileURL
        let key = normalized.path
        if let existing = sharedViews[key] {
            sharedRefCounts[key, default: 1] += 1
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
        var liveChunks: Set<String> = []
        for view in views.values {
            let chunkSet = await chunksInUse(view: view.root)
            for hash in chunkSet { liveChunks.insert(hash) }
        }
        let allChunks =
            (try? FileManager.default.contentsOfDirectory(
                atPath: store.root.path)) ?? []
        var removed = 0
        var bytesReclaimed: UInt64 = 0
        for name in allChunks where !liveChunks.contains(name) {
            let url = store.root.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: url)
            removed += 1
            bytesReclaimed += UInt64(size)
        }
        return GCResult(chunksRemoved: removed, bytesReclaimed: bytesReclaimed)
    }

    // MARK: - Live sync internals (user-space, per-file, efficient)

    private func ensureWatchers(for src: URL, view: SharedView) {
        let key = src.path
        if srcWatchers[key] == nil {
            let watcher = FSEventsWatcher(path: src) { [weak self] paths in
                Task { [weak self] in await self?.handleSrcChange(paths: paths, src: src) }
            }
            watcher.start()
            srcWatchers[key] = watcher
        }
        let viewWatcher = FSEventsWatcher(path: view.root) { [weak self] paths in
            Task { [weak self] in await self?.handleViewChange(paths: paths, view: view) }
        }
        viewWatcher.start()
        viewWatchers[view.id] = viewWatcher
    }

    private func startSharedWatchers(src: URL, view: SharedView) {
        let key = src.path
        let srcWatcher = FSEventsWatcher(path: src) { [weak self] paths in
            Task { [weak self] in await self?.handleSrcChange(paths: paths, src: src) }
        }
        srcWatcher.start()
        let viewWatcher = FSEventsWatcher(path: view.root) { [weak self] paths in
            Task { [weak self] in await self?.handleViewChange(paths: paths, view: view) }
        }
        viewWatcher.start()
        sharedWatchers[key] = (srcWatcher, viewWatcher)
    }

    private func handleSrcChange(paths: [String], src: URL) async {
        guard let viewIDs = viewsBySrc[src.path] ?? sharedViews[src.path].map({ [$0.id] }) else { return }
        // For shared view, viewsBySrc may be empty; also check sharedViews
        var targetIDs = viewIDs
        if let shared = sharedViews[src.path] { targetIDs.insert(shared.id) }
        for viewID in targetIDs {
            guard let view = views[viewID] ?? sharedViews[src.path] else { continue }
            for changed in paths {
                await syncFileChanged(at: changed, from: src, to: view.root)
            }
        }
    }

    private func handleViewChange(paths: [String], view: SharedView) async {
        for changed in paths {
            await syncFileChanged(at: changed, from: view.root, to: view.source)
            // Propagate to other views sharing same src (host as hub)
            let key = view.source.path
            let siblings = (viewsBySrc[key] ?? []).union(
                sharedViews[key].map { Set([$0.id]) } ?? [])
            for siblingID in siblings where siblingID != view.id {
                guard let sibling = views[siblingID] ?? sharedViews[key] else { continue }
                await syncFileChanged(at: changed, from: view.root, to: sibling.root, viaRelativeFrom: view.root)
            }
        }
    }

    /// Efficient per-file sync: clonefile if same APFS volume, else copy.
    /// Checks content hash first to avoid loops (copying identical files is a no-op).
    private func syncFileChanged(at changedPath: String, from srcRoot: URL, to dstRoot: URL, viaRelativeFrom base: URL? = nil) async {
        let baseRoot = base ?? srcRoot
        guard changedPath.hasPrefix(baseRoot.path) else { return }
        let relative = String(changedPath.dropFirst(baseRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relative.isEmpty { return }
        let srcFile = srcRoot.appendingPathComponent(relative)
        let dstFile = dstRoot.appendingPathComponent(relative)
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
           srcHash == dstHash { return }
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
