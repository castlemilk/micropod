import Darwin
import Foundation
import MicropodCore

/// The machine's two disks, their sizes, and growing them without losing
/// what is on them (`micropod machine disk grow`).
///
/// Both disks are ext4 with sparse_super2 and no resize inode, which the
/// guest kernel will not grow while mounted, so a grow is offline and never in
/// place:
///
/// 1. the disk is cloned beside itself (APFS `clonefile`: instant, and only
///    what the grow writes takes space) and the clone extended (sparse);
/// 2. a maintenance boot of the machine's own payload, with its own OS disk
///    and the clone as the second disk and `mp.disk_grow=1`, has guest init
///    replay the clone's journal, check it (e2fsck), grow it to the new size
///    (resize2fs, from the tool bundle's `e2fsprogs/`), check it again and
///    power off; nothing else runs, so the OS disk changes no more than in a
///    boot that stops at once;
/// 3. the clone is flushed, its superblock must say it grew to the new size,
///    and only then is it renamed over the disk (atomic) and the directory
///    flushed.
///
/// A kill anywhere before the rename leaves the disk as it was (the next grow
/// removes the clone); after it, the disk is the grown, checked clone. A disk
/// is never shrunk. The machine must be stopped, and stays so: the grow holds
/// the locks an install holds, which every supervisor checks.
public enum HVFMachineDisks {
    public enum Disk: String, Sendable, CaseIterable, Codable {
        case os, cache

        public var label: String { self == .os ? "OS disk" : "cache disk" }
    }

    /// One disk's sizes: the image (what the guest sees), the filesystem on
    /// it (smaller until it is grown), and what the image takes on the Mac.
    public struct Sizes: Sendable, Equatable, Encodable {
        public var imageBytes: UInt64
        public var filesystemBytes: UInt64?
        public var allocatedBytes: UInt64?

        /// The image is larger than its filesystem by more than one block
        /// group: a grow that did not finish (or an image extended by hand).
        public var filesystemBehind: Bool {
            guard let fs = filesystemBytes else { return false }
            return imageBytes > fs + Self.groupBytes
        }

        static let groupBytes: UInt64 = 128 << 20
    }

    public static func url(_ disk: Disk, layout: HVFMachineLayout) -> URL {
        disk == .os ? layout.disk : layout.cacheDisk
    }

    public static func sizes(_ disk: Disk, layout: HVFMachineLayout) -> Sizes? {
        sizes(of: url(disk, layout: layout))
    }

    public static func sizes(of url: URL) -> Sizes? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Sizes(
            imageBytes: UInt64(st.st_size), filesystemBytes: ext4Bytes(url),
            allocatedBytes: UInt64(st.st_blocks) * 512)
    }

    /// The ext4 superblock's blocks × block size, or nil when it is not one.
    public static func ext4Bytes(_ url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 1024)) != nil, let data = try? handle.read(upToCount: 1024),
            data.count == 1024
        else { return nil }
        let sb = [UInt8](data)
        func u16(_ o: Int) -> UInt64 { UInt64(sb[o]) | UInt64(sb[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt64 { u16(o) | u16(o + 2) << 16 }
        guard u16(0x38) == 0xEF53, u32(0x18) <= 6 else { return nil }
        var blocks = u32(0x04)
        if u32(0x60) & 0x80 != 0 { blocks |= u32(0x150) << 32 }
        return blocks * (1024 << u32(0x18))
    }

    public struct Grown: Sendable, Equatable, Encodable {
        public var disk: Disk
        public var before: Sizes
        public var after: Sizes
    }

    /// Grows each disk `targets` names to its new size (bytes). A size equal
    /// to the disk's leaves it; a smaller one is refused before anything is
    /// done.
    @discardableResult
    public static func grow(
        _ targets: [Disk: UInt64], layout: HVFMachineLayout, timeout: Duration = .seconds(1800),
        progress: @Sendable (String) -> Void
    ) async throws -> [Grown] {
        try layout.validatePaths()
        try refuseWhileRunning(layout)
        guard let installing = try HVFFileLock.acquire(layout.installLock, wait: .zero) else {
            throw MicropodError.message(
                "failedPrecondition: a `micropod machine install` or disk grow is running on \(layout.root.path)")
        }
        defer { installing.release() }
        guard
            let starting = try await HVFMachineClient.lock(
                layout.startLock, until: ContinuousClock.now + HVFMachineClient.startHandoverWait)
        else {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine under \(layout.root.path) is being started; stop it first")
        }
        defer { starting.release() }
        try refuseWhileRunning(layout)
        guard let updating = try HVFFileLock.acquire(layout.updateLock, wait: .milliseconds(250)) else {
            throw MicropodError.message(
                "failedPrecondition: an HVF payload update is running on \(layout.root.path); retry when it finishes")
        }
        defer { updating.release() }
        removeLeftovers(in: layout)

        // Every check before anything is cloned.
        var plan: [(disk: Disk, target: UInt64, before: Sizes)] = []
        for disk in Disk.allCases {
            guard let target = targets[disk] else { continue }
            guard let before = Self.sizes(disk, layout: layout) else {
                throw MicropodError.message(
                    "failedPrecondition: \(url(disk, layout: layout).path) is not there; this machine has no \(disk.label)"
                )
            }
            guard before.filesystemBytes != nil else {
                throw MicropodError.message(
                    "failedPrecondition: \(url(disk, layout: layout).path) is not an ext4 disk")
            }
            guard target >= before.imageBytes else {
                throw MicropodError.message(
                    "invalidArgument: the \(disk.label) is \(gib(before.imageBytes)); a disk is never shrunk "
                        + "(asked for \(gib(target)))")
            }
            guard target <= 16 << 40 else {
                throw MicropodError.message("invalidArgument: an ext4 disk without 64-bit blocks holds at most 16 TiB")
            }
            if target == before.imageBytes, !before.filesystemBehind {
                progress("\(disk.label) is already \(gib(target))")
                continue
            }
            plan.append((disk, target, before))
        }
        guard !plan.isEmpty else { return [] }
        let payload = layout.resolvePayload()
        let resize = payload.tools.appendingPathComponent("e2fsprogs/resize2fs")
        guard FileManager.default.isExecutableFile(atPath: resize.path) else {
            throw MicropodError.message(
                "failedPrecondition: the installed payload \(payload.id) has no e2fsprogs (\(resize.path)); "
                    + "update the machine's payload to one that grows disks first (nothing was changed)")
        }
        let config = try HVFMachineConfig.load(from: layout.config)

        var grown: [Grown] = []
        for step in plan {
            let target = url(step.disk, layout: layout)
            let clone = target.deletingLastPathComponent()
                .appendingPathComponent(".grow-\(UUID().uuidString)-\(target.lastPathComponent)")
            defer { unlink(clone.path) }
            progress(
                "\(step.disk.label): cloning \(target.lastPathComponent) and extending the clone to \(gib(step.target))"
            )
            guard clonefile(target.path, clone.path, 0) == 0 else {
                throw HVFFiles.posixError("clone \(target.path)")
            }
            guard truncate(clone.path, off_t(step.target)) == 0 else {
                throw HVFFiles.posixError("extend \(clone.path)")
            }
            try fullSync(clone)
            progress("\(step.disk.label): checking and growing the clone in a maintenance boot")
            let log = layout.logsDirectory.appendingPathComponent("disk-grow.log")
            let result = try await maintenanceBoot(
                payload: payload, layout: layout, config: config, clone: clone, log: log, timeout: timeout)
            guard result.ok else {
                throw MicropodError.message(
                    "internal: growing the \(step.disk.label) failed in the maintenance boot (\(result.detail)); "
                        + "the disk is unchanged. Its log: \(log.path)")
            }
            try fullSync(clone)
            // The new size, give or take the last block group (resize2fs
            // leaves out one too small to hold its metadata), and never less
            // than before.
            guard let after = sizes(of: clone), let fs = after.filesystemBytes, fs <= step.target,
                fs + Sizes.groupBytes >= step.target, fs >= step.before.filesystemBytes ?? 0
            else {
                throw MicropodError.message(
                    "internal: the grown clone's filesystem is not the new size "
                        + "(\(gib(sizes(of: clone)?.filesystemBytes ?? 0)) of \(gib(step.target))); the disk is unchanged"
                )
            }
            guard rename(clone.path, target.path) == 0 else { throw HVFFiles.posixError("replace \(target.path)") }
            try syncDirectory(target.deletingLastPathComponent())
            progress("\(step.disk.label): \(gib(step.before.filesystemBytes ?? 0)) → \(gib(fs)) (\(result.detail))")
            grown.append(
                Grown(disk: step.disk, before: step.before, after: Self.sizes(step.disk, layout: layout) ?? after))
        }
        if grown.contains(where: { $0.disk == .cache }), let size = layout.cacheDiskBytes() {
            var updated = try HVFMachineConfig.load(from: layout.config)
            updated.cacheDiskBytes = size
            try updated.save(to: layout.config)
        }
        return grown
    }

    struct MaintenanceResult {
        var ok: Bool
        var detail: String
    }

    /// Boots the payload with the clone as the second disk and
    /// `mp.disk_grow=1`, and reads guest init's result line from its console.
    static func maintenanceBoot(
        payload: HVFMachinePayload, layout: HVFMachineLayout, config: HVFMachineConfig, clone: URL, log: URL,
        timeout: Duration
    ) async throws -> MaintenanceResult {
        try FileManager.default.createDirectory(at: layout.logsDirectory, withIntermediateDirectories: true)
        var args = [
            "--kernel", payload.kernel.path, "--initrd", payload.initrd.path,
            "--disk", layout.disk.path, "--cache-disk", clone.path,
            "--share", "oci-tools:\(payload.tools.path):ro",
            "--cpus", "2", "--memory-mib", "2048",
            "--cmdline-append", growBootArgument, "--cmdline-append", HVFVMMCommand.kernelLogLevelBootArgument,
        ]
        if let flush = config.osDiskFlush { args += [HVFVMMFeatures.osDiskFlushFlag, flush] }
        args += ["--shutdown-timeout", "10", "--json-summary", "--parent-pid", String(getpid())]
        let process = Process()
        process.executableURL = payload.vmm
        process.arguments = args
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: log)
        defer { try? out.close() }
        out.seekToEndOfFile()
        out.write(
            Data("\n=== \(ISO8601DateFormatter().string(from: Date())) disk grow: \(clone.lastPathComponent)\n".utf8))
        let start = out.offsetInFile
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now > deadline {
                process.terminate()
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return MaintenanceResult(ok: false, detail: "it did not finish within \(timeout)")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        try reader.seek(toOffset: start)
        let text = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let range = line.range(of: "MICROPOD_DISK_GROW_OK") {
                return MaintenanceResult(
                    ok: process.terminationStatus == 0,
                    detail: line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
            if let range = line.range(of: "MICROPOD_DISK_GROW_FAILED") {
                return MaintenanceResult(
                    ok: false, detail: line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
        }
        return MaintenanceResult(
            ok: false, detail: "the maintenance boot exited \(process.terminationStatus) without a result")
    }

    /// The guest init argument for a maintenance boot that grows /dev/vdb.
    public static let growBootArgument = "mp.disk_grow=1"

    /// Clones an interrupted grow left beside the disks. Only called under
    /// install.lock, so none of them belongs to a live grow.
    static func removeLeftovers(in layout: HVFMachineLayout) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: layout.root.path) else { return }
        for name in names where name.hasPrefix(".grow-") {
            unlink(layout.root.appendingPathComponent(name).path)
        }
    }

    private static func refuseWhileRunning(_ layout: HVFMachineLayout) throws {
        if HVFFileLock.isHeld(layout.supervisorLock) {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine under \(layout.root.path) is running; "
                    + "stop it first (`micropod machine stop`)")
        }
    }

    /// F_FULLFSYNC: the file's data and size on the disk, past its cache.
    static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw HVFFiles.posixError("open \(url.path)") }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw HVFFiles.posixError("flush \(url.path)") }
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw HVFFiles.posixError("open \(url.path)") }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw HVFFiles.posixError("flush \(url.path)") }
    }

    public static func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(1 << 30))
    }
}
