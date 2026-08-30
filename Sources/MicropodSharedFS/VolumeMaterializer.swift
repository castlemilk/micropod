import Foundation

/// The container operations a materialization needs, behind a protocol so the
/// diff/tar/prune logic can be tested without a runtime.
public protocol VolumeContainerOps: Sendable {
    /// A value that changes when the volume is replaced, or nil if it no
    /// longer exists. Recorded alongside the manifest so a recreated volume
    /// forces a full re-ship instead of being reported "up to date" while
    /// actually empty.
    func fingerprint(volume: String) async throws -> String?
    /// Remove any helper left holding `volume` by an earlier, crashed sync.
    /// Such a helper holds the volume exclusively and would block this one.
    func reapStaleHelpers(volume: String) async
    /// Start a throwaway container with `volume` mounted at `mountPath`,
    /// returning its id. It must outlive the copy+extract and no longer.
    func startHelper(volume: String, mountPath: String) async throws -> String
    /// Copy a host file into the container.
    func copyIn(hostPath: String, containerID: String, containerPath: String) async throws
    /// Run a command in the container, returning combined output.
    @discardableResult
    func exec(containerID: String, arguments: [String]) async throws -> String
    /// Remove the container, whatever state it is in.
    func remove(containerID: String) async
}

public struct MaterializeStats: Sendable, Equatable {
    public var filesShipped: Int = 0
    public var directoriesCreated: Int = 0
    public var pathsRemoved: Int = 0
    public var bytesShipped: UInt64 = 0
    /// True when the source was already identical to the last sync and no
    /// container was started at all.
    public var skipped: Bool = false

    public init() {}
}

/// Incrementally mirrors a host directory into an Apple `container` **block**
/// volume.
///
/// Why not just bind-mount the directory: a virtiofs bind is ~32x slower than
/// a block volume for the small-file access CI does. Copying the whole tree in
/// on every run would give back most of that win, so only the diff since the
/// last sync is shipped — measured at ~0.1s for a one-file change against
/// ~1.9s for a full copy of a 4.8k-file tree.
///
/// Transport is a tar streamed through `container cp`, not a second bind
/// mount, because a bind mount would put us back on the slow path we are
/// avoiding.
///
/// **The volume is exclusive.** The Apple runtime attaches a block volume to
/// one running VM at a time — a second concurrent mount fails to bootstrap
/// with "The storage device attachment is invalid". So the helper container
/// must be gone before the job container starts, and two syncs into the same
/// volume cannot overlap.
public struct VolumeMaterializer: Sendable {
    public let ops: any VolumeContainerOps
    public let manifests: ManifestStore
    public let scanner: TreeScanner
    /// Where the helper mounts the volume. Arbitrary, but stable so a
    /// half-finished sync is recognisable in a stray container.
    public let mountPath: String

    public init(
        ops: any VolumeContainerOps,
        manifests: ManifestStore,
        scanner: TreeScanner = TreeScanner(),
        mountPath: String = "/__micropod_sync"
    ) {
        self.ops = ops
        self.manifests = manifests
        self.scanner = scanner
        self.mountPath = mountPath
    }

    /// Bring `volume`'s copy of `source` up to date at `destination`
    /// (a path *inside* the volume, e.g. "/" or "/workspace").
    @discardableResult
    public func sync(source: URL, volume: String, destination: String = "/") async throws
        -> MaterializeStats
    {
        let root = source.standardizedFileURL
        // Serialize against other syncs of this volume for the whole operation,
        // including the manifest write — two writers would otherwise record
        // conflicting histories for one volume. See VolumeSyncLock.
        let lock = try VolumeSyncLock(
            root: manifests.root.appendingPathComponent("locks"),
            volume: volume)
        // ARC could otherwise release the lock as soon as its last use goes by,
        // which here is immediately — the lock has no uses, only a lifetime.
        defer { withExtendedLifetime(lock) {} }

        guard let fingerprint = try await ops.fingerprint(volume: volume) else {
            throw SharedFSError.volumeMissing(volume)
        }

        var previous = manifests.load(source: root, volume: volume, destination: destination)
        if previous.volumeFingerprint != fingerprint {
            // The volume this history describes is gone or was replaced.
            // Trusting the history here is the one failure mode that reports
            // success while leaving the volume empty.
            previous = FileManifest(version: 0)
        }
        var current = try scanner.scan(root, reusing: previous)
        current.volumeFingerprint = fingerprint
        let diff = current.diff(against: previous)

        var stats = MaterializeStats()
        if diff.isEmpty {
            // Nothing moved: don't pay a container start to prove it.
            stats.skipped = true
            return stats
        }

        let staging = try StagingArea()
        defer { staging.cleanUp() }

        var tarURL: URL?
        if !diff.changed.isEmpty {
            tarURL = try Self.buildTar(source: root, paths: diff.changed, staging: staging)
            stats.bytesShipped =
                (try? FileManager.default.attributesOfItem(atPath: tarURL!.path)[.size] as? UInt64)
                .flatMap { $0 } ?? 0
        }

        // A helper from a crashed sync still holds the volume exclusively and
        // would make this bootstrap fail.
        await ops.reapStaleHelpers(volume: volume)

        let containerID = try await ops.startHelper(volume: volume, mountPath: mountPath)
        // The helper holds the volume exclusively; nothing else can start
        // against it until it is gone, so it must be removed on every path —
        // including a thrown error part-way through.
        var removed = false
        func releaseHelper() async {
            guard !removed else { return }
            removed = true
            await ops.remove(containerID: containerID)
        }
        do {
            let stats = try await materialize(
                containerID: containerID, diff: diff, tarURL: tarURL, staging: staging,
                destination: destination, stats: stats)
            await releaseHelper()
            // Only after the helper is gone and its writes are flushed is the
            // volume known to match: recording earlier would make a failed
            // sync look complete and under-ship forever after.
            try manifests.save(current, source: root, volume: volume, destination: destination)
            return stats
        } catch {
            await releaseHelper()
            throw error
        }
    }

    private func materialize(
        containerID: String, diff: ManifestDiff, tarURL: URL?, staging: StagingArea,
        destination: String, stats initial: MaterializeStats
    ) async throws -> MaterializeStats {
        var stats = initial

        let target = Self.joinedPath(mountPath, destination)
        try await ops.exec(containerID: containerID, arguments: ["mkdir", "-p", target])

        if !diff.removed.isEmpty {
            try await applyRemovals(
                diff.removed, containerID: containerID, target: target, staging: staging)
            stats.pathsRemoved = diff.removed.count
        }

        if !diff.directories.isEmpty {
            try await applyDirectories(
                diff.directories, containerID: containerID, target: target, staging: staging)
            stats.directoriesCreated = diff.directories.count
        }

        // The flush matters more than it looks: removing the helper tears down
        // its VM, and anything still in the guest page cache is lost —
        // silently, because the extract already "succeeded" and the manifest
        // would then record a volume that does not hold what we think it does.
        // It rides along with the extract rather than costing its own exec
        // round-trip, which is ~0.5s of the sync's total on this runtime.
        if let tarURL {
            let remote = "/tmp/micropod-sync-\(UUID().uuidString.prefix(8)).tar"
            try await ops.copyIn(
                hostPath: tarURL.path, containerID: containerID, containerPath: remote)
            try await ops.exec(
                containerID: containerID,
                arguments: [
                    "sh", "-c",
                    "tar -xf \(Self.shellQuoted(remote)) -C \(Self.shellQuoted(target)) "
                        + "&& rm -f \(Self.shellQuoted(remote)) && sync",
                ])
            stats.filesShipped = diff.changed.count
        } else {
            try await ops.exec(containerID: containerID, arguments: ["sync"])
        }
        return stats
    }

    /// Drop the recorded history so the next sync ships everything.
    public func invalidate(source: URL, volume: String, destination: String = "/") throws {
        try manifests.forget(
            source: source.standardizedFileURL, volume: volume, destination: destination)
    }

    // MARK: - Internals

    /// Builds a tar of exactly `paths`.
    ///
    /// `COPYFILE_DISABLE=1` is not optional: without it macOS `tar` emits an
    /// AppleDouble `._name` sidecar for every file carrying xattrs, which on a
    /// 4.8k-file tree doubled the entry count and littered the container with
    /// files no build expects.
    ///
    /// Paths go via `-T` rather than argv — a large first sync easily exceeds
    /// ARG_MAX, and the failure mode there is a truncated tree, not an error.
    static func buildTar(source: URL, paths: [String], staging: StagingArea) throws -> URL {
        let listURL = staging.url(named: "paths.txt")
        // NUL-separated: a newline is legal in a filename and would otherwise
        // split one path into two bogus ones.
        var list = Data()
        for path in paths {
            list.append(Data(path.utf8))
            list.append(0)
        }
        try list.write(to: listURL, options: .atomic)

        let tarURL = staging.url(named: "delta.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "--null", "-T", listURL.path, "-cf", tarURL.path, "-C", source.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SharedFSError.tarFailed(String(decoding: errorData, as: UTF8.self))
        }
        return tarURL
    }

    /// Deletions go in as a file list the container reads, not as argv: a
    /// large prune would blow ARG_MAX, and interpolating paths into a shell
    /// string would mis-handle spaces and quotes.
    private func applyRemovals(
        _ paths: [String], containerID: String, target: String, staging: StagingArea
    ) async throws {
        let listURL = staging.url(named: "removals.txt")
        try Self.newlineTerminatedList(paths).write(to: listURL, options: .atomic)
        let remote = "/tmp/micropod-rm-\(UUID().uuidString.prefix(8)).txt"
        try await ops.copyIn(hostPath: listURL.path, containerID: containerID, containerPath: remote)
        try await ops.exec(
            containerID: containerID,
            arguments: [
                "sh", "-c",
                "cd \(Self.shellQuoted(target)) && while IFS= read -r p || [ -n \"$p\" ]; do "
                    + "[ -n \"$p\" ] && rm -rf -- \"$p\"; done < \(Self.shellQuoted(remote)); "
                    + "rm -f \(Self.shellQuoted(remote))",
            ])
    }

    private func applyDirectories(
        _ paths: [String], containerID: String, target: String, staging: StagingArea
    ) async throws {
        let listURL = staging.url(named: "dirs.txt")
        try Self.newlineTerminatedList(paths).write(to: listURL, options: .atomic)
        let remote = "/tmp/micropod-mkdir-\(UUID().uuidString.prefix(8)).txt"
        try await ops.copyIn(hostPath: listURL.path, containerID: containerID, containerPath: remote)
        try await ops.exec(
            containerID: containerID,
            arguments: [
                "sh", "-c",
                "cd \(Self.shellQuoted(target)) && while IFS= read -r p || [ -n \"$p\" ]; do "
                    + "[ -n \"$p\" ] && mkdir -p -- \"$p\"; done < \(Self.shellQuoted(remote)); "
                    + "rm -f \(Self.shellQuoted(remote))",
            ])
    }

    /// Joins paths one-per-line **with a trailing newline**.
    ///
    /// `while IFS= read -r p` returns non-zero on a final line that has no
    /// newline, so the loop body never runs for it. With a single-entry list
    /// that means the whole prune silently does nothing — the volume keeps
    /// files the source deleted, and the manifest still records success.
    static func newlineTerminatedList(_ paths: [String]) -> Data {
        var data = Data()
        for path in paths {
            data.append(Data(path.utf8))
            data.append(0x0A)
        }
        return data
    }

    static func joinedPath(_ mount: String, _ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? mount : "\(mount)/\(trimmed)"
    }

    /// Single-quote for `sh -c`, escaping embedded quotes the POSIX way.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A private temp directory that cleans itself up.
public final class StagingArea: @unchecked Sendable {
    public let root: URL

    public init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("micropod-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func url(named name: String) -> URL {
        root.appendingPathComponent(name)
    }

    public func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
