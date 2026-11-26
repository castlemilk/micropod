import Containerization
import ContainerizationOCI
import Darwin
import Foundation
import MicropodCore

/// What `micropod machine install` copies into a root. Any asset left nil
/// keeps the root's existing copy; a root missing an asset needs its source.
public struct HVFInstallRequest: Sendable, Equatable {
    public var vmm: URL?
    public var kernel: URL?
    public var initrd: URL?
    public var tools: URL?
    /// ext4 image cloned (APFS `clonefile`) into `disk.ext4`.
    public var diskFrom: URL?
    /// OCI image unpacked into a fresh `disk.ext4` (instead of `diskFrom`).
    public var diskImage: String?
    public var diskBytes: UInt64
    /// Allows a new disk to discard an existing machine disk.
    public var replaceDisk: Bool
    public var cpus: Int?
    public var memoryMiB: Int?
    public var workspace: String?

    public init(
        vmm: URL? = nil, kernel: URL? = nil, initrd: URL? = nil, tools: URL? = nil, diskFrom: URL? = nil,
        diskImage: String? = nil, diskBytes: UInt64 = 32 << 30, replaceDisk: Bool = false, cpus: Int? = nil,
        memoryMiB: Int? = nil, workspace: String? = nil
    ) {
        self.vmm = vmm
        self.kernel = kernel
        self.initrd = initrd
        self.tools = tools
        self.diskFrom = diskFrom
        self.diskImage = diskImage
        self.diskBytes = diskBytes
        self.replaceDisk = replaceDisk
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.workspace = workspace
    }
}

public enum HVFMachineInstaller {
    public static let hypervisorEntitlement = "com.apple.security.hypervisor"

    /// The image Micropod's CI worker disk is unpacked from: Alpine with
    /// iptables, which the guest tools' `runner/start.sh` expects.
    public static let defaultDiskImage =
        "docker.io/library/docker:29.9.3-dind@sha256:7bf70dcb85c822e3fa6f2d332143e474b99147b9d7b39102b0cfe8b04a7dd61b"

    /// Installs into `layout`.
    ///
    /// Mutually exclusive with the machine: refuses while a supervisor runs
    /// or is being started, and holds `run/install.lock` (which every
    /// supervisor checks after taking its own lock) and `run/start.lock`
    /// (which on-demand starters take) for its whole run, so nothing can
    /// boot against a half-installed root.
    ///
    /// Every source is checked, and every fallible step — the disk pull and
    /// unpack or clone, the copies, the copied VMM's signature — is staged
    /// beside its target before anything installed is replaced: a bad
    /// request or a failed pull changes nothing. Staging an interrupted
    /// install left behind is removed by the next one.
    public static func install(
        _ request: HVFInstallRequest, layout: HVFMachineLayout, packagedExecutable: URL? = nil,
        progress: @Sendable (String) -> Void
    ) async throws {
        try layout.validatePaths()
        try refuseWhileRunning(layout)
        let fm = FileManager.default
        guard let installing = try HVFFileLock.acquire(layout.installLock, wait: .zero) else {
            throw MicropodError.message(
                "failedPrecondition: another `micropod machine install` is running on \(layout.root.path)")
        }
        defer { installing.release() }
        // A starter holds start.lock only until its supervisor holds the
        // supervisor lock; after that the check below sees the machine.
        guard
            let starting = try await HVFMachineClient.lock(
                layout.startLock, until: ContinuousClock.now + HVFMachineClient.startHandoverWait)
        else {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine under \(layout.root.path) is being started; "
                    + "stop it first (`micropod machine stop`)")
        }
        defer { starting.release() }
        try refuseWhileRunning(layout)
        removeLeftovers(in: layout)

        var config = try HVFMachineConfig.load(from: layout.config)
        if let cpus = request.cpus { config.cpus = cpus }
        if let memoryMiB = request.memoryMiB { config.memoryMiB = memoryMiB }
        if let workspace = request.workspace {
            config.workspace = workspace.isEmpty ? nil : HVFMachineLayout.canonicalPath(workspace)
        }
        try config.validate()
        if let workspace = config.workspace {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: workspace, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MicropodError.message("invalidArgument: hvf workspace \(workspace) is not a directory")
            }
        }

        // Validate every source, and that nothing stays missing, up front.
        // Sources are read through symlinks (`copyfile` with COPYFILE_CLONE
        // would copy a link as a link).
        func resolved(_ url: URL?) -> URL? { url.map { URL(fileURLWithPath: HVFMachineLayout.canonicalPath($0.path)) } }
        let package = packagedExecutable.flatMap { distributionDirectories(for: $0) }
        func source(_ explicit: URL?, target: URL, directory: URL?, name: String) -> URL? {
            if let explicit { return resolved(explicit) }
            guard !fm.fileExists(atPath: target.path), let directory else { return nil }
            let member = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: member.path), let canonical = resolved(member),
                canonical.pathComponents.starts(with: directory.pathComponents)
            else { return nil }
            return canonical
        }
        let vmm = source(request.vmm, target: layout.vmm, directory: package?.bin, name: "micropod-vmm")
        let kernel = source(request.kernel, target: layout.kernel, directory: package?.resources, name: "vmlinux-hvf")
        let initrd = source(request.initrd, target: layout.initrd, directory: package?.resources, name: "mp-hvf-init.cpio")
        let files: [(name: String, source: URL?, target: URL)] = [
            ("micropod-vmm", vmm, layout.vmm), ("Image", kernel, layout.kernel), ("mp-hvf-init.cpio", initrd, layout.initrd),
        ]
        let tools = source(request.tools, target: layout.tools, directory: package?.resources, name: "micropod-oci-tools")
        let diskFrom = resolved(request.diskFrom)
        var unresolved: [String] = []
        for file in files {
            if let source = file.source {
                guard HVFMachineLayout.isRegularFile(source) else {
                    throw MicropodError.message("invalidArgument: \(file.name) source \(source.path) is not a file")
                }
            } else if !HVFMachineLayout.isRegularFile(file.target) {
                unresolved.append("--\(flag(for: file.name)) <\(file.name)>")
            }
        }
        if let vmm = files[0].source { try verifyHypervisorEntitlement(vmm) }
        if let tools {
            guard fm.fileExists(atPath: tools.appendingPathComponent("runner/start.sh").path) else {
                throw MicropodError.message(
                    "invalidArgument: \(tools.path) is not a guest tool bundle (no runner/start.sh)")
            }
        } else if layout.missingAssets().contains(where: { $0.hasPrefix("tools/") }) {
            unresolved.append("--tools <dir>")
        }
        if diskFrom != nil, request.diskImage != nil {
            throw MicropodError.message("invalidArgument: pass either --disk-from or --disk-image, not both")
        }
        let replacesDisk = diskFrom != nil || request.diskImage != nil
        if replacesDisk, HVFMachineLayout.isRegularFile(layout.disk), !request.replaceDisk {
            throw MicropodError.message(
                "failedPrecondition: \(layout.disk.path) already holds this machine's containers, images and "
                    + "volumes; pass --replace-disk to discard it")
        }
        if let disk = diskFrom {
            guard HVFMachineLayout.isRegularFile(disk) else {
                throw MicropodError.message("invalidArgument: disk source \(disk.path) is not a file")
            }
            guard isExt4(disk) else {
                throw MicropodError.message("invalidArgument: \(disk.path) is not an ext4 image")
            }
        } else if let image = request.diskImage {
            guard request.diskBytes >= 1 << 30 else {
                throw MicropodError.message("invalidArgument: a machine disk needs at least 1 GiB")
            }
            _ = try Reference.parse(image)
        } else if !HVFMachineLayout.isRegularFile(layout.disk) {
            unresolved.append("--disk-from <ext4> (or --disk-image <ref>)")
        }
        guard unresolved.isEmpty else {
            throw MicropodError.message(
                "invalidArgument: \(layout.root.path) is missing assets; pass \(unresolved.joined(separator: " "))")
        }

        for directory in [layout.root, layout.runDirectory, layout.logsDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Stage: everything that can fail, before anything is replaced.
        var staged: [URL] = []
        defer { for url in staged { try? fm.removeItem(at: url) } }
        func stagingPath(for target: URL) -> URL {
            let url = target.deletingLastPathComponent()
                .appendingPathComponent(".install-\(UUID().uuidString)-\(target.lastPathComponent)")
            staged.append(url)
            return url
        }
        var stagedDisk: URL?
        if let disk = diskFrom {
            let into = stagingPath(for: layout.disk)
            guard clonefile(disk.path, into.path, 0) == 0 else {
                let code = errno
                throw MicropodError.message(
                    "failedPrecondition: cannot clone \(disk.path) into \(layout.root.path): "
                        + "\(String(cString: strerror(code))). The disk must be on the same APFS volume "
                        + "as the machine root (an instant `cp -c` copy-on-write clone)")
            }
            guard chmod(into.path, 0o600) == 0 else { throw HVFFiles.posixError("chmod \(into.path)") }
            stagedDisk = into
        } else if let image = request.diskImage {
            let into = stagingPath(for: layout.disk)
            let store = stagingPath(for: layout.root.appendingPathComponent("images"))
            try await provisionDisk(
                image: image, bytes: request.diskBytes, store: store, into: into, progress: progress)
            // The pulled blobs are only the unpack's input.
            try? fm.removeItem(at: store)
            stagedDisk = into
        }
        var stagedFiles: [(name: String, source: URL, staged: URL, target: URL)] = []
        for file in files {
            guard let source = file.source else { continue }
            let into = stagingPath(for: file.target)
            try copy(source, to: into)
            if file.target == layout.vmm {
                // The copy must still carry the signature that grants HVF access.
                try verifyHypervisorEntitlement(into)
            }
            stagedFiles.append((file.name, source, into, file.target))
        }
        var stagedTools: URL?
        if let tools {
            let into = stagingPath(for: layout.tools)
            try copy(tools, to: into)
            stagedTools = into
        }

        // Commit: renames within the root, disk last, then the config.
        for file in stagedFiles {
            try commit(file.staged, to: file.target)
            staged.removeAll { $0 == file.staged }
            progress("installed \(file.name) from \(file.source.path)")
        }
        if let stagedTools, let tools {
            try commit(stagedTools, to: layout.tools)
            staged.removeAll { $0 == stagedTools }
            progress("installed tools/ from \(tools.path)")
        }
        if let stagedDisk {
            try commit(stagedDisk, to: layout.disk)
            staged.removeAll { $0 == stagedDisk }
            // A new disk holds none of the old disk's containers.
            try? HVFContainerIndexStore(layout: layout).reset()
            if let disk = diskFrom {
                progress("cloned disk.ext4 from \(disk.path)")
            } else if let image = request.diskImage {
                progress("created disk.ext4 from \(image)")
            }
        }
        try config.save(to: layout.config)
        progress("wrote \(layout.config.path) (\(config.cpus) vCPU, \(config.memoryMiB) MiB)")
        progress(buildKitReport(layout.missingBuildKitFiles()))
    }

    private static func distributionDirectories(for executable: URL) -> (bin: URL, resources: URL)? {
        let exe = URL(fileURLWithPath: HVFMachineLayout.canonicalPath(executable.path))
        switch CLIInstall.kind(of: exe) {
        case let .appManaged(app):
            let contents = URL(fileURLWithPath: HVFMachineLayout.canonicalPath(app.path)).appendingPathComponent("Contents")
            return (contents.appendingPathComponent("MacOS"), contents.appendingPathComponent("Resources"))
        case .standalone:
            let directory = exe.deletingLastPathComponent()
            return (directory, directory)
        case .development:
            return nil
        }
    }

    /// What the installed tool bundle means for `docker buildx`.
    static func buildKitReport(_ missing: [String]) -> String {
        missing.isEmpty
            ? "guest tools ship BuildKit: `micropod machine buildkit-endpoint` names its socket"
            : "guest tools have no BuildKit (missing \(missing.joined(separator: ", "))): "
                + "this machine serves no buildx builder"
    }

    private static func refuseWhileRunning(_ layout: HVFMachineLayout) throws {
        if HVFFileLock.isHeld(layout.supervisorLock) {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine under \(layout.root.path) is running; "
                    + "stop it first (`micropod machine stop`)")
        }
    }

    /// Staging (`.install-*`) and retired trees (`.retired-*`) an
    /// interrupted install left in the root, and the pull store earlier
    /// installers kept at `images/`. Only called under install.lock, so
    /// none of it belongs to a live install.
    static func removeLeftovers(in layout: HVFMachineLayout) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: layout.root.path) else { return }
        for name in names where name.hasPrefix(".install-") || name.hasPrefix(".retired-") || name == "images" {
            try? fm.removeItem(at: layout.root.appendingPathComponent(name))
        }
    }

    /// Pulls `image` for this Mac's platform only into the staging `store`
    /// and unpacks it into a fresh journaled ext4 disk of `bytes` (sparse)
    /// at `disk`. The guest tools bring containerd and the engine; the
    /// image supplies the Linux userland they run on.
    static func provisionDisk(
        image: String, bytes: UInt64, store storePath: URL, into disk: URL, progress: @Sendable (String) -> Void
    ) async throws {
        let reference = try SandboxVM.normalize(image)
        let store = try ImageStore(path: storePath)
        progress("pulling \(reference)")
        let pulled = try await store.pull(reference: reference, platform: .current)
        progress("unpacking \(reference) into a \(bytes >> 30) GiB ext4 disk")
        // A journal: the disk outlives every VMM, including killed ones.
        _ = try await EXT4Unpacker(capacityInBytes: bytes, journal: .init(defaultMode: .ordered))
            .unpack(pulled, for: .current, at: disk)
        guard chmod(disk.path, 0o600) == 0 else { throw HVFFiles.posixError("chmod \(disk.path)") }
    }

    private static func flag(for asset: String) -> String {
        switch asset {
        case "micropod-vmm": return "vmm"
        case "Image": return "kernel"
        default: return "initrd"
        }
    }

    /// Swaps a staged replacement in by rename: a new inode, so the kernel
    /// never serves a stale code signature for an executable rewritten in
    /// place. A staged item that is not swapped in stays the caller's to
    /// remove.
    private static func commit(_ staged: URL, to target: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            guard rename(staged.path, target.path) == 0 else { throw HVFFiles.posixError("install \(target.path)") }
            return
        }
        // rename(2) cannot replace a non-empty directory: move the old tree
        // aside first.
        let retired = target.deletingLastPathComponent()
            .appendingPathComponent(".retired-\(UUID().uuidString)-\(target.lastPathComponent)")
        try fm.moveItem(at: target, to: retired)
        guard rename(staged.path, target.path) == 0 else {
            let failure = HVFFiles.posixError("install \(target.path)")
            try? fm.moveItem(at: retired, to: target)
            throw failure
        }
        // Left behind only if this fails; the next install removes it.
        try? fm.removeItem(at: retired)
    }

    /// `copyfile(3)`: clones on APFS, copies elsewhere; recursive for trees.
    private static func copy(_ source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
        if isDirectory.boolValue { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw HVFFiles.posixError("copy \(source.path) to \(destination.path)")
        }
    }

    /// `codesign --verify` plus the hypervisor entitlement in the signature.
    /// Without it Hypervisor.framework refuses `hv_vm_create`.
    public static func verifyHypervisorEntitlement(_ binary: URL) throws {
        let verify = try run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
        guard verify.status == 0 else {
            throw MicropodError.message(
                "failedPrecondition: \(binary.path) has no valid code signature: "
                    + verify.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let shown = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", binary.path])
        let entitlements =
            (try? PropertyListSerialization.propertyList(from: Data(shown.stdout.utf8), format: nil))
            as? [String: Any]
        guard shown.status == 0, entitlements?[hypervisorEntitlement] as? Bool == true else {
            throw MicropodError.message(
                "failedPrecondition: \(binary.path) is not signed with the \(hypervisorEntitlement) entitlement; "
                    + "sign it with `codesign --sign - --entitlements vmm/entitlements.plist --force \(binary.path)`")
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (
        status: Int32, stdout: String, stderr: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self)
        )
    }

    /// The ext4 superblock magic (0xEF53 at byte 1024 + 0x38).
    static func isExt4(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 1024 + 0x38)) != nil, let magic = try? handle.read(upToCount: 2),
            magic.count == 2
        else { return false }
        return magic[magic.startIndex] == 0x53 && magic[magic.startIndex + 1] == 0xEF
    }
}
