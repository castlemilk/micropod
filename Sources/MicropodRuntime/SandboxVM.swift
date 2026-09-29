import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import MicropodCore

/// Ephemeral CI sandboxes: one micro-VM per run, owned by this process.
///
/// The `container run` path pays for the apiserver + sandbox-service XPC
/// hops, a network allocation and a per-container rootfs prepare on every
/// run. This path skips all of it:
///
/// - base rootfs per image digest (or checkpoint) is unpacked to ext4
///   ONCE, then every run boots an APFS `clonefile` of it — CoW, ~1ms,
///   discarded on exit (shuru-style checkpoints fall out for free: keep
///   the clone instead of deleting it)
/// - `/tmp` is tmpfs — build caches and scratch copies live in guest RAM
/// - no network device unless asked for
/// - VZ is driven in-process via `LinuxContainer`, so parallel runs are
///   N independent VMs with no shared daemon to serialise on
///
/// Kernel and vminit image are borrowed from the `container` install.
public enum SandboxVM {
    public enum Base: Sendable {
        case image(String)
        case checkpoint(String)
    }

    public struct Options: Sendable {
        public var base: Base
        public var arguments: [String] = []
        public var cpus = 2
        public var memoryMiB: UInt64 = 2048
        public var diskBytes: UInt64 = 8 * 1024 * 1024 * 1024
        /// `host:guest[:ro]` — virtiofs shares.
        public var mounts: [String] = []
        public var env: [String] = []
        public var workdir: String?
        public var network = false
        public var tmpfsTmp = true
        public var tmpSizeMiB: UInt64?
        /// Keep the run's disk as checkpoint `saveAs` when it exits 0.
        public var saveAs: String?
        /// Kill the guest after this many seconds; run returns 124.
        public var timeoutSeconds: Int64?
        /// A guest that panics before vminitd answers never connects —
        /// fail instead of hanging the CI job.
        public var bootTimeout: Duration = .seconds(30)

        public init(base: Base) { self.base = base }
    }

    static let appSupport =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.container")
    public static let root =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".micropod/sandbox")
    static var imagesDir: URL { root.appendingPathComponent("images") }
    static var checkpointsDir: URL { root.appendingPathComponent("checkpoints") }
    static var runsDir: URL { root.appendingPathComponent("runs") }

    /// Base disk + the image whose config (env, cwd, entrypoint) applies.
    struct Checkpoint: Codable {
        var image: String
        var diskBytes: UInt64
        var created: Date
    }

    // MARK: - Run

    /// Boot, run `options.arguments`, tear down. Returns the guest exit code.
    public static func run(
        _ options: Options,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Int32 {
        let trace = Trace()
        let id = "sbx-" + UUID().uuidString.lowercased().prefix(12)
        let runDir = runsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDir) }

        let store = try imageStore()
        let (baseDisk, imageRef, diskBytes) = try await resolveBase(
            options, store: store, progress: progress)
        let image = try await store.get(reference: imageRef)
        let imageConfig = try await image.config(for: .current).config
        trace.mark("resolve")

        let rootfsPath = runDir.appendingPathComponent("rootfs.ext4")
        try clone(baseDisk, to: rootfsPath)
        let rootfs = Containerization.Mount.block(format: "ext4", source: rootfsPath.path, destination: "/")
        trace.mark("clone")

        let manager = VZVirtualMachineManager(
            kernel: Kernel(path: try kernelURL(), platform: .linuxArm),
            initialFilesystem: try await initfs(store: store, progress: progress))
        trace.mark("initfs")

        // One vmnet network per sandbox (macOS 26 vmnet_network_create —
        // no vm.networking entitlement): vmnet picks a free subnet, so
        // parallel runs never contend for addresses.
        // The network must outlive the VM: releasing it early kills the
        // guest mid-teardown ("virtual machine stopped unexpectedly").
        var vmnet = options.network ? try VmnetNetwork() : nil
        let network: (interface: any Interface, gateway: String)?
        if let net = vmnet, let iface = try vmnet?.createInterface(id) {
            network = (iface, net.ipv4Gateway.description)
            trace.mark("network")
        } else {
            network = nil
        }
        defer { withExtendedLifetime(vmnet) {} }

        let container = try LinuxContainer(id, rootfs: rootfs, vmm: manager) { cfg in
            if let imageConfig { cfg.process = .init(from: imageConfig) }
            cfg.cpus = options.cpus
            cfg.memoryInBytes = options.memoryMiB * 1024 * 1024
            cfg.hostname = "sandbox"
            if let path = ProcessInfo.processInfo.environment["MICROPOD_SANDBOX_BOOTLOG"] {
                cfg.bootLog = .file(path: URL(fileURLWithPath: path), append: false)
            }
            if !options.arguments.isEmpty {
                // Explicit command replaces CMD but keeps the entrypoint,
                // matching `docker run image cmd…`.
                cfg.process.arguments =
                    (imageConfig?.entrypoint ?? []) + options.arguments
            }
            guard !cfg.process.arguments.isEmpty else {
                throw MicropodError.message("image \(imageRef) has no default command")
            }
            cfg.process.environmentVariables = mergeEnv(
                cfg.process.environmentVariables, options.env)
            if let workdir = options.workdir { cfg.process.workingDirectory = workdir }
            cfg.process.stdout = FileHandleWriter(.standardOutput)
            cfg.process.stderr = FileHandleWriter(.standardError)
            if options.tmpfsTmp {
                var opts = ["nosuid", "nodev", "mode=1777"]
                if let size = options.tmpSizeMiB { opts.append("size=\(size)m") }
                cfg.mounts.append(
                    .any(type: "tmpfs", source: "tmpfs", destination: "/tmp", options: opts))
            }
            for spec in options.mounts {
                cfg.mounts.append(try shareMount(spec))
            }
            if let network {
                cfg.interfaces = [network.interface]
                cfg.dns = DNS(nameservers: [network.gateway])
            }
        }

        // No stop() on boot timeout: create() still holds the container's
        // state lock. The VM dies with this process.
        try await withTimeout(options.bootTimeout, "guest did not boot") {
            try await container.create()
        }
        trace.mark("create")
        var status: ExitStatus
        do {
            try await container.start()
            trace.mark("start")
            status = try await container.wait(timeoutInSeconds: options.timeoutSeconds)
            trace.mark("wait")
        } catch let err as ContainerizationError where err.code == .timeout {
            try? await container.stop()
            progress("timed out after \(options.timeoutSeconds!)s")
            return 124
        } catch {
            try? await container.stop()
            throw error
        }
        // stop() unmounts the rootfs in-guest, so a kept disk is clean.
        try await container.stop()
        trace.mark("stop")

        if let name = options.saveAs, status.exitCode == 0 {
            try saveCheckpoint(
                name: name, disk: rootfsPath, image: imageRef, diskBytes: diskBytes)
            progress("checkpoint '\(name)' saved")
        }
        trace.report()
        return status.exitCode
    }

    static func withTimeout(
        _ limit: Duration, _ message: String, _ body: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw MicropodError.message("\(message) within \(limit)")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Checkpoints

    public struct CheckpointInfo: Sendable {
        public let name: String
        public let image: String
        public let sizeBytes: Int64
        public let created: Date
    }

    public static func listCheckpoints() -> [CheckpointInfo] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: checkpointsDir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { file in
            let name = String(file.dropLast(5))
            guard let meta = try? loadCheckpoint(name) else { return nil }
            let disk = checkpointsDir.appendingPathComponent("\(name).ext4")
            let size =
                (try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            return CheckpointInfo(
                name: name, image: meta.image, sizeBytes: Int64(size), created: meta.created)
        }
    }

    public static func deleteCheckpoint(_ name: String) throws {
        guard (try? loadCheckpoint(name)) != nil else {
            throw MicropodError.message("no checkpoint '\(name)'")
        }
        for ext in ["ext4", "json"] {
            try? FileManager.default.removeItem(
                at: checkpointsDir.appendingPathComponent("\(name).\(ext)"))
        }
    }

    static func loadCheckpoint(_ name: String) throws -> Checkpoint {
        let url = checkpointsDir.appendingPathComponent("\(name).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Checkpoint.self, from: Data(contentsOf: url))
    }

    static func saveCheckpoint(name: String, disk: URL, image: String, diskBytes: UInt64) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        else { throw MicropodError.message("invalid checkpoint name '\(name)'") }
        let fm = FileManager.default
        try fm.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        let dest = checkpointsDir.appendingPathComponent("\(name).ext4")
        // rename(2) replaces atomically — concurrent runs cloning the old
        // checkpoint keep their already-cloned copy.
        guard rename(disk.path, dest.path) == 0 else {
            throw MicropodError.message("saving checkpoint: \(String(cString: strerror(errno)))")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Checkpoint(image: image, diskBytes: diskBytes, created: Date()))
            .write(to: checkpointsDir.appendingPathComponent("\(name).json"), options: .atomic)
    }

    // MARK: - Base disks

    /// (base disk to clone, image reference for config, disk size).
    static func resolveBase(
        _ options: Options, store: ImageStore, progress: @Sendable (String) -> Void
    ) async throws -> (URL, String, UInt64) {
        switch options.base {
        case .checkpoint(let name):
            let meta = try loadCheckpoint(name)
            return (checkpointsDir.appendingPathComponent("\(name).ext4"), meta.image, meta.diskBytes)
        case .image(let raw):
            let ref = try normalize(raw)
            let image = try await store.get(reference: ref, pull: true)
            let key = image.digest.replacingOccurrences(of: ":", with: "-")
            let gib = options.diskBytes / (1024 * 1024 * 1024)
            let base = imagesDir.appendingPathComponent("\(key)-\(gib)g.ext4")
            if !FileManager.default.fileExists(atPath: base.path) {
                progress("unpacking \(ref) (first run for this digest)")
                try FileManager.default.createDirectory(
                    at: imagesDir, withIntermediateDirectories: true)
                // Unpack beside the target then rename: concurrent first
                // runs each unpack, last rename wins, nobody sees a partial.
                let tmp = imagesDir.appendingPathComponent(".\(key)-\(UUID().uuidString).ext4")
                defer { try? FileManager.default.removeItem(at: tmp) }
                _ = try await EXT4Unpacker(capacityInBytes: options.diskBytes)
                    .unpack(image, for: .current, at: tmp)
                guard rename(tmp.path, base.path) == 0 else {
                    throw MicropodError.message("caching rootfs: \(String(cString: strerror(errno)))")
                }
            }
            return (base, ref, options.diskBytes)
        }
    }

    /// vminitd initfs, unpacked once from the store's `vminit` image.
    static func initfs(store: ImageStore, progress: @Sendable (String) -> Void) async throws -> Containerization.Mount {
        let images = try await store.list()
        guard let vminit = images.first(where: { $0.reference.contains("containerization/vminit") })
        else {
            throw MicropodError.message("no vminit image — run `container system start` once")
        }
        let tag = vminit.digest.replacingOccurrences(of: ":", with: "-")
        let path = root.appendingPathComponent("initfs-\(tag).ext4")
        if !FileManager.default.fileExists(atPath: path.path) {
            progress("preparing initfs from \(vminit.reference)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let tmp = root.appendingPathComponent(".initfs-\(UUID().uuidString).ext4")
            defer { try? FileManager.default.removeItem(at: tmp) }
            _ = try await InitImage(image: vminit).initBlock(at: tmp, for: .linuxArm)
            guard rename(tmp.path, path.path) == 0 else {
                throw MicropodError.message("caching initfs: \(String(cString: strerror(errno)))")
            }
        }
        return .block(format: "ext4", source: path.path, destination: "/", options: ["ro"])
    }

    static func kernelURL() throws -> URL {
        let link = appSupport.appendingPathComponent("kernels/default.kernel-arm64")
        guard FileManager.default.fileExists(atPath: link.path) else {
            throw MicropodError.message("no kernel at \(link.path) — run `container system start` once")
        }
        return link.resolvingSymlinksInPath()
    }

    static func imageStore() throws -> ImageStore {
        try ImageStore(
            path: appSupport,
            contentStore: try LocalContentStore(path: appSupport.appendingPathComponent("content")))
    }

    static func normalize(_ raw: String) throws -> String {
        // `parse` never defaults the registry — `container` does that itself.
        var ref = try Reference.parse(raw)
        if ref.domain == nil { ref = try Reference.parse("docker.io/\(raw)") }
        ref.normalize()
        return ref.description
    }

    /// APFS clonefile: constant-time CoW copy of the base disk.
    static func clone(_ src: URL, to dst: URL) throws {
        guard clonefile(src.path, dst.path, 0) == 0 else {
            throw MicropodError.message(
                "clonefile \(src.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    static func shareMount(_ spec: String) throws -> Containerization.Mount {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || (parts.count == 3 && ["ro", "rw"].contains(parts[2])),
            !parts[0].isEmpty, parts[1].hasPrefix("/")
        else { throw MicropodError.message("mount '\(spec)' — want host:/guest[:ro]") }
        let host = URL(fileURLWithPath: parts[0]).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: host) else {
            throw MicropodError.message("mount source \(host) does not exist")
        }
        return .share(
            source: host, destination: parts[1], options: parts.count == 3 && parts[2] == "ro" ? ["ro"] : [])
    }

    /// Later `KEY=value` entries override earlier ones by key.
    static func mergeEnv(_ base: [String], _ overrides: [String]) -> [String] {
        var out = base
        for entry in overrides {
            let key = entry.split(separator: "=", maxSplits: 1).first.map(String.init) ?? entry
            let value = entry.contains("=") ? entry : ProcessInfo.processInfo.environment[key].map { "\(key)=\($0)" }
            guard let value else { continue }
            out.removeAll { $0.hasPrefix("\(key)=") }
            out.append(value)
        }
        return out
    }
}

/// `MICROPOD_SANDBOX_TRACE=1` — per-phase wall-clock on stderr.
final class Trace: @unchecked Sendable {
    private let enabled = ProcessInfo.processInfo.environment["MICROPOD_SANDBOX_TRACE"] != nil
    private var last = ContinuousClock.now
    private var phases: [(String, Duration)] = []

    func mark(_ phase: String) {
        guard enabled else { return }
        let now = ContinuousClock.now
        phases.append((phase, now - last))
        last = now
    }

    func report() {
        guard enabled else { return }
        let line = phases.map { name, d in
            "\(name)=\(Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000))ms"
        }
        FileHandle.standardError.write(Data("sandbox trace: \(line.joined(separator: " "))\n".utf8))
    }
}

/// Streams guest stdio straight to a host file descriptor.
final class FileHandleWriter: Writer {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
    }
    func close() throws {}
}
