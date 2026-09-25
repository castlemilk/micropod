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

    /// Where container `containerID`'s clone of `volume` lives.
    public static func clonePath(containerID: String, volume: String) -> URL {
        cloneRoot.appendingPathComponent(containerID, isDirectory: true)
            .appendingPathComponent("\(volume).img")
    }

    /// Names of the volumes with a clone image in the container's clone
    /// dir (sorted; empty when the dir does not exist).
    public static func clonedVolumes(containerID: String) -> [String] {
        let dir = cloneRoot.appendingPathComponent(containerID, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".img") }.map { String($0.dropLast(4)) }.sorted()
    }

    /// Bytes actually allocated to the file (`st_blocks × 512`): sparse
    /// holes and extents still shared with a clone source are excluded, so
    /// this is real usage rather than the provisioned size. 0 when absent.
    public static func allocatedBytes(atPath path: String) -> UInt64 {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return 0 }
        return UInt64(max(info.st_blocks, 0)) * 512
    }

    /// APFS copy-on-write clone of `source` at `destination` (parent
    /// directories are created). The clone lands in a temp file next to the
    /// destination and is renamed into place, so a concurrent reader never
    /// sees a partial image. `COPYFILE_CLONE` is O(1) on APFS and falls back
    /// to a regular copy on other filesystems.
    public static func cloneImage(from source: String, to destination: String) throws {
        let target = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = tempPath(nextTo: target)
        guard copyfile(source, temp, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            let code = errno
            unlink(temp)
            throw MicropodError.message("failed to clone volume image \(source): \(Self.describe(code))")
        }
        guard rename(temp, destination) == 0 else {
            let code = errno
            unlink(temp)
            throw MicropodError.message("failed to place clone at \(destination): \(Self.describe(code))")
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

    /// No running container may have the golden attached read-write: a
    /// clone of it would be crash-consistent at best, and replacing it
    /// underneath the writer would corrupt both.
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
    public static func requireClone(containerID: String, volume: String) throws -> String {
        let path = clonePath(containerID: containerID, volume: volume).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw notFound("container '\(containerID)' has no clone of volume '\(volume)'")
        }
        return path
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

/// Which named volumes running containers hold read-write — the precondition
/// `CloneVolume`, `CommitVolumeClone` and create's multi-attach guard share.
/// Apple named volumes are ext4 block images with no multi-attach
/// protection in the runtime, so this is the only guard there is.
public struct VolumeAttachments: Sendable {
    /// Running container id keyed by volume name (`type.volume.name`, the
    /// real runtime's named-volume mount) and by mount source (a backing
    /// image path; the volume name itself under the mock CLI).
    private let holders: [String: String]

    public init(entries: [ContainerListEntry]) {
        var holders: [String: String] = [:]
        for entry in entries where entry.status.state == "running" {
            for mount in entry.configuration.mounts ?? [] where !(mount.options ?? []).contains("ro") {
                if case .object(let fields)? = mount.type?["volume"],
                    case .string(let name)? = fields["name"]
                {
                    holders[name] = holders[name] ?? entry.id
                }
                if let source = mount.source, !source.isEmpty {
                    holders[source] = holders[source] ?? entry.id
                }
            }
        }
        self.holders = holders
    }

    /// The running container holding `volume` read-write — matched by name
    /// or, when given, by the volume's backing image path.
    public func holder(of volume: String, source: String? = nil) -> String? {
        if let id = holders[volume] { return id }
        if let source, !source.isEmpty, let id = holders[source] { return id }
        return nil
    }

    /// `failedPrecondition:`-prefixed error naming volume and holder.
    public static func inUseError(volume: String, holder: String) -> MicropodError {
        VolumeClone.failedPrecondition(
            "volume '\(volume)' is attached read-write to running container '\(holder)'")
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
