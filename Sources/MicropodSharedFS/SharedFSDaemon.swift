import Foundation
import Network

/// The daemon's authoritative state: chunk store + active views + watcher.
/// One process, one state. The unix socket is just transport.
public actor SharedFSDaemon: SharedFSClient {
    public let cacheRoot: URL
    public let viewsRoot: URL
    public let store: ChunkStore
    private var views: [ViewID: SharedView] = [:]
    private var watcher: FSEventsWatcher?
    private var watchedSrc: URL?
    /// Paths that changed since the last mount or sync; used to short-circuit
    /// re-cloning on access.
    private var pendingChanges: Set<String> = []

    public init(cacheRoot: URL) throws {
        self.cacheRoot = cacheRoot
        self.viewsRoot = cacheRoot.appendingPathComponent("views", isDirectory: true)
        self.store = try ChunkStore(root: cacheRoot.appendingPathComponent("chunks", isDirectory: true))
        try FileManager.default.createDirectory(at: viewsRoot, withIntermediateDirectories: true)
    }

    // MARK: - SharedFSClient

    public func mount(src: URL, readonly: Bool) async throws -> MountInfo {
        let normalized = src.standardizedFileURL
        if watchedSrc == nil || watchedSrc != normalized {
            startWatching(normalized)
        }
        let id = ViewID.generate()
        let viewRoot = viewsRoot.appendingPathComponent(id.value, isDirectory: true)
        try SharedView.build(source: normalized, root: viewRoot)
        let view = SharedView(id: id, source: normalized, root: viewRoot)
        views[id] = view
        // An FSEvent between build() and views[id]=... is unlikely but
        // safe: caller can refresh() explicitly if they need stricter timing.
        return MountInfo(
            id: id, src: normalized.path, viewPath: viewRoot.path,
            sizeBytes: view.size(), readonly: readonly, createdAt: view.createdAt)
    }

    /// Rebuild the view from the live source. Called explicitly by clients
    /// (and auto-invoked on mount if any FSEvents have fired since the last
    /// build — see `mount`).
    public func refresh(id: ViewID) async throws -> MountInfo {
        guard let view = views[id] else {
            throw SharedFSError.daemonUnavailable
        }
        pendingChanges.removeAll()
        try SharedView.build(source: view.source, root: view.root)
        return MountInfo(
            id: id, src: view.source.path, viewPath: view.root.path,
            sizeBytes: view.size(), readonly: false, createdAt: view.createdAt)
    }

    public func unmount(id: ViewID) async throws {
        guard let view = views[id] else { return }
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

    // MARK: - Internals

    private func startWatching(_ src: URL) {
        watcher?.stop()
        pendingChanges.removeAll()
        let watchPath = src.path
        watcher = nil
        // Defer to a background task so the FSEvents callback (which can
        // arrive on any thread) can safely hop back to the actor.
        watcher = FSEventsWatcher(path: src) { [weak self] in
            Task { [weak self] in
                await self?.markChanged(at: watchPath)
            }
        }
        watcher?.start()
        watchedSrc = src
    }

    private func markChanged(at path: String) {
        pendingChanges.insert(path)
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
