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

    /// Installs into `layout`. Refuses while a supervisor runs (the VMM
    /// has the disk and binaries open). Every source is checked before the
    /// first copy, so a bad request changes nothing.
    public static func install(
        _ request: HVFInstallRequest, layout: HVFMachineLayout, progress: @Sendable (String) -> Void
    ) async throws {
        if HVFFileLock.isHeld(layout.supervisorLock) {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine under \(layout.root.path) is running; "
                    + "stop it first (`micropod machine stop`)")
        }
        try layout.validatePaths()
        let fm = FileManager.default

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
        let files: [(name: String, source: URL?, target: URL)] = [
            ("micropod-vmm", request.vmm, layout.vmm), ("Image", request.kernel, layout.kernel),
            ("mp-hvf-init.cpio", request.initrd, layout.initrd),
        ]
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
        if let vmm = request.vmm { try verifyHypervisorEntitlement(vmm) }
        if let tools = request.tools {
            guard fm.fileExists(atPath: tools.appendingPathComponent("runner/start.sh").path) else {
                throw MicropodError.message(
                    "invalidArgument: \(tools.path) is not a guest tool bundle (no runner/start.sh)")
            }
        } else if layout.missingAssets().contains(where: { $0.hasPrefix("tools/") }) {
            unresolved.append("--tools <dir>")
        }
        if request.diskFrom != nil, request.diskImage != nil {
            throw MicropodError.message("invalidArgument: pass either --disk-from or --disk-image, not both")
        }
        if request.diskFrom != nil || request.diskImage != nil, HVFMachineLayout.isRegularFile(layout.disk),
            !request.replaceDisk
        {
            throw MicropodError.message(
                "failedPrecondition: \(layout.disk.path) already holds this machine's containers, images and "
                    + "volumes; pass --replace-disk to discard it")
        }
        if let disk = request.diskFrom {
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
        for file in files {
            guard let source = file.source else { continue }
            try replace(file.target) { staged in try copy(source, to: staged) }
            progress("installed \(file.name) from \(source.path)")
        }
        if request.vmm != nil {
            // The copy must still carry the signature that grants HVF access.
            try verifyHypervisorEntitlement(layout.vmm)
        }
        if let tools = request.tools {
            try replace(layout.tools) { staged in try copy(tools.resolvingSymlinksInPath(), to: staged) }
            progress("installed tools/ from \(tools.path)")
        }
        if let disk = request.diskFrom {
            try replace(layout.disk) { staged in
                guard clonefile(disk.path, staged.path, 0) == 0 else {
                    let code = errno
                    throw MicropodError.message(
                        "failedPrecondition: cannot clone \(disk.path) into \(layout.root.path): "
                            + "\(String(cString: strerror(code))). The disk must be on the same APFS volume "
                            + "as the machine root (an instant `cp -c` copy-on-write clone)")
                }
                guard chmod(staged.path, 0o600) == 0 else { throw HVFFiles.posixError("chmod \(staged.path)") }
            }
            progress("cloned disk.ext4 from \(disk.path)")
        }
        if let image = request.diskImage {
            try await provisionDisk(image: image, bytes: request.diskBytes, layout: layout, progress: progress)
        }
        try config.save(to: layout.config)
        progress("wrote \(layout.config.path) (\(config.cpus) vCPU, \(config.memoryMiB) MiB)")
    }

    /// Pulls `image` into a store under the root and unpacks it into a
    /// fresh journaled ext4 `disk.ext4` of `bytes` (sparse). The guest
    /// tools bring containerd and the engine; the image supplies the Linux
    /// userland they run on.
    static func provisionDisk(
        image: String, bytes: UInt64, layout: HVFMachineLayout, progress: @Sendable (String) -> Void
    ) async throws {
        let reference = try SandboxVM.normalize(image)
        let store = try ImageStore(path: layout.root.appendingPathComponent("images"))
        progress("pulling \(reference)")
        let pulled = try await store.get(reference: reference, pull: true)
        progress("unpacking \(reference) into a \(bytes >> 30) GiB ext4 disk")
        let staged = layout.root.appendingPathComponent(".install-\(UUID().uuidString)-disk.ext4")
        do {
            // A journal: the disk outlives every VMM, including killed ones.
            _ = try await EXT4Unpacker(capacityInBytes: bytes, journal: .init(defaultMode: .ordered))
                .unpack(pulled, for: .current, at: staged)
            guard chmod(staged.path, 0o600) == 0 else { throw HVFFiles.posixError("chmod \(staged.path)") }
            guard rename(staged.path, layout.disk.path) == 0 else {
                throw HVFFiles.posixError("install \(layout.disk.path)")
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        progress("created disk.ext4 from \(reference)")
    }

    private static func flag(for asset: String) -> String {
        switch asset {
        case "micropod-vmm": return "vmm"
        case "Image": return "kernel"
        default: return "initrd"
        }
    }

    /// Builds the replacement beside `target`, then swaps it in by rename:
    /// a new inode, so the kernel never serves a stale code signature for
    /// an executable rewritten in place.
    private static func replace(_ target: URL, build: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".install-\(UUID().uuidString)-\(target.lastPathComponent)")
        do {
            try build(staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // rename(2) cannot replace a non-empty directory: move the old
            // tree aside first.
            let retired = target.deletingLastPathComponent()
                .appendingPathComponent(".retired-\(UUID().uuidString)-\(target.lastPathComponent)")
            try fm.moveItem(at: target, to: retired)
            guard rename(staged.path, target.path) == 0 else {
                let failure = HVFFiles.posixError("install \(target.path)")
                try? fm.moveItem(at: retired, to: target)
                throw failure
            }
            try fm.removeItem(at: retired)
        } else {
            guard rename(staged.path, target.path) == 0 else {
                let failure = HVFFiles.posixError("install \(target.path)")
                try? fm.removeItem(at: staged)
                throw failure
            }
        }
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
