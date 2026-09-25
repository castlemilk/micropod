import Darwin
import Foundation

/// File-level primitives for clone-backed volumes, shared by the CLI and
/// native volume services and by the native container service.
///
/// A *golden* is a named volume's backing image (`volume.img`). Containers
/// never attach a golden directly when cloning is in effect: each gets an
/// APFS copy-on-write clone under ``cloneRoot`` (`<container>/<volume>.img`)
/// and writes there at ext4 speed. `CommitVolumeClone` promotes such a clone
/// back over the golden with an fsync + atomic rename, serialised per volume
/// by ``VolumeLocks`` against the container delete that removes clone dirs.
public enum VolumeClone {
    /// Label stamped on volumes made by `CloneVolume`, naming the source.
    public static let cloneOfLabel = "com.micropod.clone-of"

    /// Per-container clone root: `~/Library/Application Support/
    /// micropod/volume-clones/<containerID>/<volume>.img`.
    /// `MICROPOD_VOLUME_CLONE_ROOT` overrides the root (tests/ops).
    public static var cloneRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MICROPOD_VOLUME_CLONE_ROOT"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("micropod/volume-clones", isDirectory: true)
    }

    /// Where container `containerID`'s clone of `volume` lives. Both are
    /// path components: an id or a name outside ``componentGrammar`` is
    /// `invalid_argument` (``requireSafeComponent(_:as:)``).
    public static func clonePath(containerID: String, volume: String) throws -> URL {
        try requireSafeComponent(containerID, as: "container id")
        try requireSafeComponent(volume, as: "volume name")
        return cloneDir(containerID).appendingPathComponent("\(volume).img")
    }

    /// `<cloneRoot>/<containerID>` — callers have checked the id.
    private static func cloneDir(_ containerID: String) -> URL {
        cloneRoot.appendingPathComponent(containerID, isDirectory: true)
    }

    /// Names of the volumes with a clone image in the container's clone
    /// dir (sorted; empty when the dir does not exist or the id is not a
    /// safe path component).
    public static func clonedVolumes(containerID: String) -> [String] {
        guard isSafeComponent(containerID) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cloneDir(containerID).path)) ?? []
        return names.filter { $0.hasSuffix(".img") }.map { String($0.dropLast(4)) }.sorted()
    }

    // MARK: - Path-component grammar

    /// What a container id or volume name must look like to become a
    /// component of a clone path: the runtime's own container-ID grammar —
    /// an ASCII letter or digit, then letters, digits, `_`, `.` and `-`, at
    /// most 63 characters. No separator can pass, so neither `..` nor `a/b`
    /// can steer a clone-dir operation outside `<cloneRoot>/<id>/`.
    public static let componentGrammar = "[A-Za-z0-9][A-Za-z0-9_.-]{0,62}"

    public static func isSafeComponent(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard let first = scalars.first, isASCIIAlphanumeric(first), scalars.count <= 63 else { return false }
        return scalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    /// `invalidArgument:` (→ `invalid_argument`) unless `value` matches
    /// ``componentGrammar``. A request's container name reaches the
    /// clone-dir lifecycle — orphan sweep, stale-dir reclaim, placement,
    /// removal — before the runtime validates it, so the grammar is enforced
    /// at the API edge, by the native create before its mutex, and again
    /// inside every function here that builds a path from an id or a volume
    /// name: none of them touches the filesystem for an unsafe one.
    public static func requireSafeComponent(_ value: String, as kind: String = "name") throws {
        guard isSafeComponent(value) else {
            throw MicropodError.message("invalidArgument: \(kind) '\(value)' must match \(componentGrammar)")
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9": return true
        default: return false
        }
    }

    /// Bytes actually allocated to the file (`st_blocks × 512`): sparse
    /// holes are excluded, so this is real usage rather than the provisioned
    /// size. Extents shared with a clone source *are* counted — APFS reports
    /// a fresh clonefile at its source's full allocation, not its private
    /// delta — so a golden's figure and its clones' overlap and must not be
    /// summed as if they were disjoint. 0 when absent.
    public static func allocatedBytes(atPath path: String) -> UInt64 {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return 0 }
        return UInt64(max(info.st_blocks, 0)) * 512
    }

    /// How ``cloneImage(from:to:placement:)`` lands the clone at its
    /// destination.
    public enum Placement: Sendable {
        /// Rename over whatever is there — `CloneVolume`, whose destination
        /// is the empty backing image the runtime just made for the new volume.
        case replace
        /// `renamex_np(RENAME_EXCL)`: an existing destination is refused as
        /// `already_exists` and left untouched — the create path, where a
        /// clone already at `<root>/<id>/<volume>.img` belongs to the
        /// container that won a replayed create and may be its live block
        /// device.
        case exclusive
    }

    /// APFS copy-on-write clone of `source` at `destination` (parent
    /// directories are created). The clone lands in a temp file next to the
    /// destination and is renamed into place, so a concurrent reader never
    /// sees a partial image. `COPYFILE_CLONE` is O(1) on APFS and falls back
    /// to a regular copy on other filesystems.
    public static func cloneImage(from source: String, to destination: String, placement: Placement = .replace)
        throws
    {
        let target = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = tempPath(nextTo: target)
        guard copyfile(source, temp, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            let code = errno
            unlink(temp)
            throw MicropodError.message("failed to clone volume image \(source): \(Self.describe(code))")
        }
        let placed: Int32
        switch placement {
        case .replace: placed = rename(temp, destination)
        case .exclusive: placed = renamex_np(temp, destination, UInt32(RENAME_EXCL))
        }
        guard placed == 0 else {
            let code = errno
            unlink(temp)
            if placement == .exclusive, code == EEXIST {
                throw MicropodError.message("alreadyExists: clone image \(destination) already exists")
            }
            throw MicropodError.message("failed to place clone at \(destination): \(Self.describe(code))")
        }
    }

    // MARK: - Clone-dir lifecycle (shared by the CLI and native container services)

    /// Removes a container's clone dir: each clone image under its volume's
    /// lock — a `CommitVolumeClone` in flight for that volume either
    /// completes first or finds the clone gone (`not_found`), never a rename
    /// of a file being unlinked — then any staging file a crashed placement
    /// left, then the dir itself. The dir is only removed while empty, so a
    /// clone a concurrent create placed for a new container of the same id
    /// after the listing keeps its dir. Never throws: a dir that is already
    /// gone is the desired end state. An id that is not a safe path
    /// component names nothing under the root and is a no-op.
    public static func removeClones(containerID: String) async {
        guard isSafeComponent(containerID) else { return }
        let dir = cloneDir(containerID)
        await unlinkClones(containerID: containerID, volumes: clonedVolumes(containerID: containerID))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(".") && name.contains(".img.tmp-") {
            unlink(dir.appendingPathComponent(name).path)
        }
        rmdir(dir.path)
    }

    /// Removes only the named clone images of a container's dir (each under
    /// its volume's lock) and the dir if that leaves it empty. A create that
    /// fails after placing some of its clones removes exactly those: with
    /// exclusive placement, a clone it did not place belongs to the create
    /// that did — a replay of the same id that won the name, possibly
    /// running on it — and stays, as does any staging file (a placement of
    /// that create may be in flight). Never throws; an unsafe id is a no-op.
    public static func removeClones(containerID: String, volumes: [String]) async {
        guard isSafeComponent(containerID) else { return }
        await unlinkClones(containerID: containerID, volumes: volumes)
        rmdir(cloneDir(containerID).path)
    }

    private static func unlinkClones(containerID: String, volumes: [String]) async {
        for volume in Array(Set(volumes)).sorted() {
            // A name that is not a safe path component never names a clone.
            guard let clone = try? clonePath(containerID: containerID, volume: volume) else { continue }
            await VolumeLocks.shared.withLock(volume) {
                _ = unlink(clone.path)
            }
        }
    }

    /// Removes container `containerID`'s clone dir whatever its age when no
    /// container of that id exists (`live` is the runtime's answer, as for
    /// ``sweepOrphanClones``). The orphan grace protects a create that has
    /// placed its clones but not yet reached the runtime, so this may only
    /// be called by a create that holds the id's in-process create mutex
    /// (the native backend's `InFlightCreates.withExclusive`) for its whole
    /// duration — then no other create of this id can be placing under the
    /// dir, and it can only be the leftover of a create that died with its
    /// process. A retried create of the same id must not be refused
    /// `already_exists` for a container that never was. Returns whether a
    /// dir was removed; an id that is not a safe path component is refused
    /// without a look at the filesystem.
    @discardableResult
    public static func reclaimStaleCloneDir(containerID: String, live: Set<String>) async -> Bool {
        guard isSafeComponent(containerID), !live.contains(containerID) else { return false }
        let dir = cloneDir(containerID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        await removeClones(containerID: containerID)
        return !FileManager.default.fileExists(atPath: dir.path)
    }

    /// Clone dirs younger than this are never swept as orphans: they may
    /// belong to a create that has not reached the runtime yet, so the
    /// container is not in `live` although it is about to be.
    public static let orphanGrace: TimeInterval = 60

    /// Removes clone dirs whose container is not in `live` — dirs orphaned
    /// by a raw `container delete` or a crashed runtime. Callers pass a list
    /// the runtime answered, never an empty one standing in for a failed
    /// list: sweeping against that would unlink live containers' clones.
    /// A dir whose name is outside ``componentGrammar`` (only a pre-guard
    /// build or a hand can have put one here) is never a path this code
    /// builds: it is left in place, and said so on stderr.
    public static func sweepOrphanClones(live: Set<String>) async {
        let cutoff = Date().addingTimeInterval(-orphanGrace)
        for dir
            in (try? FileManager.default.contentsOfDirectory(
                at: cloneRoot, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? []
        where !live.contains(dir.lastPathComponent)
            && (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && ((try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < cutoff
        {
            let id = dir.lastPathComponent
            guard isSafeComponent(id) else {
                FileHandle.standardError.write(
                    Data(
                        ("micropod: clone dir \(id.debugDescription) under \(cloneRoot.path) is not a container id "
                            + "(\(componentGrammar)); left in place\n").utf8))
                continue
            }
            await removeClones(containerID: id)
        }
    }

    /// Promotes a container's clone to be the golden image.
    ///
    /// The clone is fsync'd, an O(1) CoW twin of it is made next to the
    /// golden and fsync'd, that twin is `rename(2)`d over the golden, and the
    /// golden's directory is fsync'd so the swap is durable. Readers see
    /// either the old golden or the new one — never a partial image. The
    /// clone file itself stays where the container's configuration points
    /// (it goes with the container on delete), so a stopped container remains
    /// startable after its clone was promoted.
    ///
    /// Staging files a commit that crashed between clone and rename left next
    /// to the golden (`.volume.img.tmp-*`) are swept first.
    ///
    /// Returns the clone's allocated bytes — what was promoted. The caller
    /// holds the volume's ``VolumeLocks`` lock and has verified the
    /// container is stopped and the golden is not attached read-write.
    public static func commit(clonePath: String, goldenPath: String) throws -> UInt64 {
        let cloneFD = open(clonePath, O_RDONLY)
        guard cloneFD >= 0 else {
            let code = errno
            if code == ENOENT {
                throw notFound("clone image \(clonePath) does not exist")
            }
            throw MicropodError.message("cannot open clone image \(clonePath): \(describe(code))")
        }
        defer { close(cloneFD) }

        var info = Darwin.stat()
        guard fstat(cloneFD, &info) == 0 else {
            throw MicropodError.message("cannot stat clone image \(clonePath): \(describe(errno))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MicropodError.message("clone image \(clonePath) is not a regular file")
        }
        guard fsync(cloneFD) == 0 else {
            throw MicropodError.message("fsync of clone image \(clonePath) failed: \(describe(errno))")
        }
        let allocated = UInt64(max(info.st_blocks, 0)) * 512

        let golden = URL(fileURLWithPath: goldenPath)
        let goldenDir = golden.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: goldenDir, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw MicropodError.message("golden image directory \(goldenDir) does not exist")
        }
        removeStaleStaging(nextTo: golden)

        let temp = tempPath(nextTo: golden)
        guard copyfile(clonePath, temp, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            let code = errno
            unlink(temp)
            throw MicropodError.message("failed to stage \(clonePath) next to \(goldenPath): \(describe(code))")
        }
        do {
            let tempFD = open(temp, O_RDONLY)
            guard tempFD >= 0 else {
                throw MicropodError.message("cannot open staged image \(temp): \(describe(errno))")
            }
            defer { close(tempFD) }
            guard fsync(tempFD) == 0 else {
                throw MicropodError.message("fsync of staged image \(temp) failed: \(describe(errno))")
            }
            guard rename(temp, goldenPath) == 0 else {
                throw MicropodError.message("failed to replace \(goldenPath): \(describe(errno))")
            }
        } catch {
            unlink(temp)
            throw error
        }

        // Make the directory entry swap durable too; a failure here does not
        // undo an already-visible, correct promotion.
        let dirFD = open(goldenDir, O_RDONLY)
        if dirFD >= 0 {
            fsync(dirFD)
            close(dirFD)
        }
        return allocated
    }

    // MARK: - Shared CloneVolume / CommitVolumeClone preconditions

    /// A volume cannot be cloned onto itself — `invalid_argument`, checked
    /// before any lock is taken (the per-volume locks are not reentrant).
    public static func requireDistinct(source: String, name: String) throws {
        guard source != name else {
            throw MicropodError.message("invalidArgument: name must differ from source '\(source)'")
        }
    }

    /// The volume must exist and have a backing image — `not_found` otherwise.
    public static func requireVolume(_ volume: Micropod_V1_Volume?, named name: String) throws -> Micropod_V1_Volume {
        guard let volume else { throw notFound("volume '\(name)' not found") }
        guard !volume.source.isEmpty else { throw notFound("volume '\(name)' has no backing image") }
        return volume
    }

    /// The golden's backing image must be on disk — the path about to be
    /// cloned or replaced.
    public static func requireBackingImage(_ volume: Micropod_V1_Volume) throws {
        guard FileManager.default.fileExists(atPath: volume.source) else {
            throw notFound("volume '\(volume.id)' backing image \(volume.source) is missing")
        }
    }

    /// No running or stopping container may have the golden attached
    /// read-write: a clone of it would be crash-consistent at best, and
    /// replacing it underneath the writer would corrupt both.
    public static func requireQuiescent(_ volume: Micropod_V1_Volume, attachments: VolumeAttachments) throws {
        if let holder = attachments.holder(of: volume.id, source: volume.source) {
            throw VolumeAttachments.inUseError(volume: volume.id, holder: holder)
        }
    }

    /// The container must exist (`not_found`) and be exactly `stopped`
    /// (`failed_precondition`): `stopping` may still be flushing the image.
    public static func requireStopped(containerID: String, in entries: [ContainerListEntry]) throws {
        guard let container = entries.first(where: { $0.id == containerID }) else {
            throw notFound("container '\(containerID)' not found")
        }
        let state = container.status.state ?? "unknown"
        guard state == "stopped" else {
            throw failedPrecondition("container '\(containerID)' is \(state), not stopped")
        }
    }

    /// The container's clone of the volume must exist; returns its path.
    /// An id or volume name outside ``componentGrammar`` is
    /// `invalid_argument` before any look at the filesystem.
    public static func requireClone(containerID: String, volume: String) throws -> String {
        let path = try clonePath(containerID: containerID, volume: volume).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw notFound("container '\(containerID)' has no clone of volume '\(volume)'")
        }
        return path
    }

    /// The container's configuration must carry a mount whose source is the
    /// clone — the block device it ran on. A clone file under a container's
    /// id that the container does not mount is the leftover of an earlier
    /// container of that name (a raw `container delete` keeps the dir, and
    /// a same-name container attaching the golden directly inherits it),
    /// not this container's writes: `not_found`. Only the container that
    /// mounts a clone can promote it.
    public static func requireMounted(
        clone: String, containerID: String, volume: String, in entries: [ContainerListEntry]
    ) throws {
        let wanted = URL(fileURLWithPath: clone).standardizedFileURL.path
        let mounted = entries.first { $0.id == containerID }?.configuration.mounts?.contains { mount in
            guard mount.typeName != "tmpfs", let source = mount.source, !source.isEmpty else { return false }
            return URL(fileURLWithPath: source).standardizedFileURL.path == wanted
        }
        guard mounted == true else {
            throw notFound(
                "container '\(containerID)' does not mount its clone of volume '\(volume)' (\(clone)): "
                    + "only the container that mounts a clone can promote it")
        }
    }

    /// Size for a clone: the request's, else the source's provisioned size
    /// in bytes (the CLI and the apiserver both accept a bare byte count),
    /// else nil for the runtime default.
    public static func cloneSize(requested: String?, source: Micropod_V1_Volume) -> String? {
        if let requested, !requested.isEmpty { return requested }
        return source.sizeBytes > 0 ? String(source.sizeBytes) : nil
    }

    /// Request labels plus the `clone-of` marker naming the source.
    public static func cloneLabels(_ labels: [String], source: String) -> [String] {
        labels + ["\(cloneOfLabel)=\(source)"]
    }

    /// The volume with `allocated_bytes` re-read from disk (after a clone
    /// or commit changed what the image occupies).
    public static func withAllocatedBytes(_ volume: Micropod_V1_Volume) -> Micropod_V1_Volume {
        var refreshed = volume
        refreshed.allocatedBytes = allocatedBytes(atPath: volume.source)
        return refreshed
    }

    /// `notFound:`-prefixed error — the prefix `ConnectCodeMapping` turns
    /// into `not_found`.
    public static func notFound(_ detail: String) -> MicropodError {
        .message("notFound: \(detail)")
    }

    /// `failedPrecondition:`-prefixed error (→ `failed_precondition`).
    public static func failedPrecondition(_ detail: String) -> MicropodError {
        .message("failedPrecondition: \(detail)")
    }

    // MARK: - Internals

    /// Unlinks staging files (`.<name>.tmp-*`) a crashed commit left next to
    /// `file`. Only this volume's commit creates them and the caller holds
    /// that volume's lock, so nothing live can be swept.
    private static func removeStaleStaging(nextTo file: URL) {
        let dir = file.deletingLastPathComponent()
        let prefix = ".\(file.lastPathComponent).tmp-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            unlink(dir.appendingPathComponent(name).path)
        }
    }

    private static func tempPath(nextTo file: URL) -> String {
        file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).tmp-\(UUID().uuidString.prefix(8).lowercased())")
            .path
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Per-volume-name async mutex. `CommitVolumeClone` holds a volume's lock
/// across its checks and the rename; container delete/prune take the same
/// lock before removing that volume's clone image, so a commit never races
/// the removal of the file it is promoting.
public actor VolumeLocks {
    public static let shared = VolumeLocks()

    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs `body` while holding `name`'s lock. Waiters are served in FIFO
    /// order; the lock is released whether `body` returns or throws.
    public nonisolated func withLock<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(name)
        do {
            let value = try await body()
            await release(name)
            return value
        } catch {
            await release(name)
            throw error
        }
    }

    /// Runs `body` while holding every lock in `names` (a volume prune
    /// touches all volumes). Names are acquired in sorted order — two
    /// callers holding overlapping sets always take their common names in
    /// the same order, so they cannot deadlock against each other — and
    /// released whether `body` returns or throws. The body must not take
    /// one of these names again: the locks are not reentrant.
    public nonisolated func withLocks<T>(_ names: [String], _ body: () async throws -> T) async rethrows -> T {
        let ordered = Array(Set(names)).sorted()
        for name in ordered { await acquire(name) }
        do {
            let value = try await body()
            for name in ordered.reversed() { await release(name) }
            return value
        } catch {
            for name in ordered.reversed() { await release(name) }
            throw error
        }
    }

    private func acquire(_ name: String) async {
        if held.insert(name).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[name, default: []].append(continuation)
        }
    }

    private func release(_ name: String) {
        if var queue = waiters[name], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[name] = queue.isEmpty ? nil : queue
            // Ownership passes straight to the next waiter; `held` stays set.
            next.resume()
        } else {
            waiters[name] = nil
            held.remove(name)
        }
    }
}

/// Which named volumes containers hold read-write — the precondition
/// `CloneVolume`, `CommitVolumeClone` and create's multi-attach guard share.
/// A container holds its volumes while `running` and while `stopping`: the
/// runtime keeps the block image attached, and flushes it, until the
/// container is `stopped`, so both states count as writers. Apple named
/// volumes are ext4 block images with no multi-attach protection in the
/// runtime, so this is the only guard there is.
public struct VolumeAttachments: Sendable {
    /// A container holding a volume read-write, and the state (`running` or
    /// `stopping`) that keeps the image attached.
    public struct Holder: Sendable, Equatable {
        public let id: String
        public let state: String
    }

    /// Holder keyed by volume name (`type.volume.name`, the real runtime's
    /// named-volume mount) and by mount source (a backing image path; the
    /// volume name itself under the mock CLI). tmpfs mounts are skipped:
    /// their source is the literal `tmpfs`, which would otherwise mark a
    /// volume of that name as held.
    private let holders: [String: Holder]

    /// Whether a container in `state` still has its block images attached.
    public static func holdsVolumes(state: String?) -> Bool {
        state == "running" || state == "stopping"
    }

    public init(entries: [ContainerListEntry]) {
        var holders: [String: Holder] = [:]
        for entry in entries {
            guard let state = entry.status.state, Self.holdsVolumes(state: state) else { continue }
            let holder = Holder(id: entry.id, state: state)
            for mount in entry.configuration.mounts ?? [] where !(mount.options ?? []).contains("ro") {
                if case .object(let fields)? = mount.type?["volume"],
                    case .string(let name)? = fields["name"]
                {
                    holders[name] = holders[name] ?? holder
                }
                if mount.typeName != "tmpfs", let source = mount.source, !source.isEmpty {
                    holders[source] = holders[source] ?? holder
                }
            }
        }
        self.holders = holders
    }

    /// The running or stopping container holding `volume` read-write —
    /// matched by name or, when given, by the volume's backing image path.
    public func holder(of volume: String, source: String? = nil) -> Holder? {
        if let holder = holders[volume] { return holder }
        if let source, !source.isEmpty, let holder = holders[source] { return holder }
        return nil
    }

    /// `failedPrecondition:`-prefixed error naming volume, holder and the
    /// holder's state (so a `stopping` writer reads as "wait", not "stop").
    public static func inUseError(volume: String, holder: Holder) -> MicropodError {
        VolumeClone.failedPrecondition(
            "volume '\(volume)' is attached read-write to \(holder.state) container '\(holder.id)'")
    }

    /// Named volumes among `-v` specs (`name:/dst[:opts]`), in order. Host
    /// paths (anything with a `/`, `.` or `..`) are bind mounts and single-
    /// segment specs are anonymous volumes — neither can already be held.
    public static func namedVolumes(in specs: [String]) -> [String] {
        var names: [String] = []
        for raw in specs {
            var spec = raw
            while spec.hasPrefix(":") { spec = String(spec.dropFirst()) }
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3 else { continue }
            let source = String(parts[0])
            guard !source.isEmpty, !source.contains("/"), source != ".", source != ".." else { continue }
            names.append(source)
        }
        return names
    }

    /// `MICROPOD_ALLOW_MULTI_ATTACH=1`: the operator takes responsibility for
    /// attaching a volume more than once; the guard only warns.
    public static func multiAttachAllowed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["MICROPOD_ALLOW_MULTI_ATTACH"] == "1"
    }
}
