import Darwin
import Dispatch
import Foundation
import Synchronization

/// Frees large disk images on one background queue instead of inside the
/// call that retires them.
///
/// Freeing an APFS file costs time in proportion to its extents, not its
/// size: a container's `rootfs.ext4` or a workspace volume's `volume.img` is
/// a sparse clone that the job dirtied in tens of thousands of scattered
/// 4 KiB blocks, and unlinking one takes 0.5–3.5 s on Gamma-128 (93 % full,
/// CI running) and 25 s for a bundle whose rootfs took 30 000 small files.
/// Where the unlink happens is what hurts:
///
///  - container-apiserver removes a container's bundle (`containerDelete`)
///    and a volume's directory (`volumeDelete`) while it holds the one lock
///    every create, bootstrap and start also waits for, and on the
///    containers actor that stats, lists and gets wait for;
///  - this process unlinks a deleted container's cache clones, and the
///    golden a `CommitVolumeClone` replaces, under that volume's
///    ``VolumeLocks`` lock, which every create cloning the same golden waits
///    for — and does it on Swift's cooperative pool.
///
/// So the file gets a second name first, and the free happens here:
///
///  - ``stage(_:)`` hard-links a file the runtime is about to remove into
///    ``root`` (`link(2)`, O(1)); the runtime's unlink then only drops a
///    name. ``settle(_:)`` after the call: if the original name is gone (or
///    names another file now), the staged name is the file's last one and is
///    queued; if it is still there, the staged name is dropped at once,
///    which frees nothing because the file keeps its own name.
///  - ``retire(_:)`` renames a file this process owns outright (a cache
///    clone) into ``root`` and queues it.
///
/// The queue is one serial dispatch queue at utility QoS, so frees run one
/// at a time, off the cooperative pool, with their I/O throttled behind the
/// VMs' own. A file whose name cannot be added (another volume, a hard
/// link already, a permission refusal) is left alone and the caller frees it
/// as before; `MICROPOD_RECLAIM=off` turns the whole thing off. Names left
/// in ``root`` by a process that died before freeing them are queued by
/// ``sweep()`` at startup; freeing a name another live process staged only
/// drops a name, so a concurrent sweep is harmless.
public final class PayloadReclaimer: Sendable {
    public static let shared = PayloadReclaimer()

    /// `<micropod>/reclaim`, beside the clone root: the same volume as the
    /// clones, and as the apiserver's bundles and volumes (both under
    /// `~/Library`), which a hard link needs. `MICROPOD_RECLAIM_ROOT`
    /// overrides it.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MICROPOD_RECLAIM_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return VolumeClone.cloneRoot.deletingLastPathComponent().appendingPathComponent("reclaim", isDirectory: true)
    }

    /// False when `MICROPOD_RECLAIM=off`: frees happen inline again.
    public static var enabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment["MICROPOD_RECLAIM"] != "off"
    }

    /// A second name for a file the runtime is about to remove.
    public struct Stage: Sendable, Equatable {
        public let original: String
        public let link: String
        let device: dev_t
        let inode: ino_t
    }

    public struct Snapshot: Sendable, Equatable {
        /// Names handed to the queue.
        public var queued = 0
        /// Of those, freed (or already gone).
        public var freed = 0
        /// Of those, whose unlink failed; the name stays for the next sweep.
        public var failed = 0
        /// Allocated bytes of the freed files (shared extents included).
        public var bytes: UInt64 = 0
        /// Time spent in unlink.
        public var seconds: Double = 0
        /// Stages dropped at once because the original kept its name.
        public var released = 0
        public var pending: Int { queued - freed - failed }
    }

    /// Frees slower than this are logged.
    static let slowFree: Duration = .seconds(5)

    private let fixedRoot: URL?
    private let fixedEnabled: Bool?
    private let queue: DispatchQueue
    private let state = Mutex(Snapshot())
    public let metrics = APIMetrics(prefix: "micropod_reclaim")

    /// `root`/`enabled` nil: read the environment on every call (the shared
    /// instance, so tests and the API can set it).
    public init(root: URL? = nil, enabled: Bool? = nil, qos: DispatchQoS = .utility) {
        self.fixedRoot = root
        self.fixedEnabled = enabled
        self.queue = DispatchQueue(label: "dev.micropod.reclaim", qos: qos)
    }

    public var root: URL { fixedRoot ?? Self.defaultRoot }
    public var enabled: Bool { fixedEnabled ?? Self.enabledByEnvironment }

    public func snapshot() -> Snapshot { state.withLock { $0 } }

    /// Adds a name for the regular, singly-linked file at `path` under
    /// ``root``; nil (nothing done) when that is not possible.
    public func stage(_ path: String) -> Stage? {
        guard enabled else { return nil }
        var info = Darwin.stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { return nil }
        guard let root = preparedRoot(device: info.st_dev) else { return nil }
        let link = Self.name(in: root, for: path)
        guard Darwin.link(path, link) == 0 else { return nil }
        return Stage(original: path, link: link, device: info.st_dev, inode: info.st_ino)
    }

    /// The call that was to remove `stage.original` is over. Queues the
    /// staged name when the original no longer names the same file; drops it
    /// at once otherwise.
    public func settle(_ stage: Stage) {
        var info = Darwin.stat()
        if lstat(stage.original, &info) == 0, info.st_dev == stage.device, info.st_ino == stage.inode {
            unlink(stage.link)
            state.withLock { $0.released += 1 }
            return
        }
        enqueue(stage.link)
    }

    /// Moves `path` into ``root`` and queues it. False when it cannot (off,
    /// missing, another volume): the caller frees it as before.
    @discardableResult
    public func retire(_ path: String) -> Bool {
        guard enabled else { return false }
        var info = Darwin.stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            let root = preparedRoot(device: info.st_dev)
        else { return false }
        let target = Self.name(in: root, for: path)
        guard rename(path, target) == 0 else { return false }
        enqueue(target)
        return true
    }

    /// Queues every name left under ``root`` (a process that died before
    /// freeing them). Returns how many.
    @discardableResult
    public func sweep() -> Int {
        guard enabled else { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names { enqueue(root.appendingPathComponent(name).path) }
        return names.count
    }

    /// Blocks until everything queued before the call has been freed.
    public func drain() {
        queue.sync {}
    }

    /// The reclaim counters, Prometheus text (appended to `/metrics`).
    public func renderMetrics() -> String {
        let s = snapshot()
        return metrics.render()
            + "# TYPE micropod_reclaim_pending gauge\nmicropod_reclaim_pending \(s.pending)\n"
            + "# TYPE micropod_reclaim_freed_bytes_total counter\nmicropod_reclaim_freed_bytes_total \(s.bytes)\n"
            + "# TYPE micropod_reclaim_released_total counter\nmicropod_reclaim_released_total \(s.released)\n"
    }

    // MARK: - Internals

    private func enqueue(_ path: String) {
        state.withLock { $0.queued += 1 }
        queue.async { [self] in free(path) }
    }

    private func free(_ path: String) {
        let bytes = VolumeClone.allocatedBytes(atPath: path)
        let clock = ContinuousClock()
        let started = clock.now
        let result = unlink(path)
        let code = result == 0 ? 0 : errno
        let took = clock.now - started
        let ok = result == 0 || code == ENOENT
        state.withLock { s in
            if ok {
                s.freed += 1
                s.bytes += bytes
            } else {
                s.failed += 1
            }
            s.seconds += Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        }
        metrics.record(
            route: "unlink", method: "reclaim", status: ok ? 200 : 500,
            duration: Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
        if took >= Self.slowFree || !ok {
            let what = ok ? "freed" : "could not free (\(String(cString: strerror(code))))"
            let line = String(
                format: "micropod: reclaim %@ %@ (%.1f GiB allocated) in %.1fs\n", what,
                (path as NSString).lastPathComponent, Double(bytes) / 1_073_741_824,
                Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// ``root``, created when missing, when it is on `device`; nil otherwise
    /// (a link or rename across volumes fails, or would copy).
    private func preparedRoot(device: dev_t) -> URL? {
        let root = self.root
        var info = Darwin.stat()
        if stat(root.path, &info) != 0 {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard stat(root.path, &info) == 0 else { return nil }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_dev == device else { return nil }
        return root
    }

    /// `<root>/<uuid>-<file name>`: unique, and the file name still says
    /// what it was when a sweep logs it.
    private static func name(in root: URL, for path: String) -> String {
        root.appendingPathComponent("\(UUID().uuidString.lowercased())-\((path as NSString).lastPathComponent)").path
    }
}
