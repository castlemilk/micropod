import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import MicropodCore
import Virtualization
import vmnet

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
        /// `host:guest[:ro|rw|overlay]` — virtiofs shares. `overlay` shares
        /// an APFS clone of the host directory made for this run: the guest
        /// can write, the host copy is untouched, the clone is discarded.
        public var mounts: [String] = []
        public var env: [String] = []
        public var workdir: String?
        /// Replaces the image entrypoint (`arguments` become its args).
        public var entrypoint: [String]?
        public var hostname = "sandbox"
        /// NAT network with internet access (`--allow-net`).
        public var network = false
        /// Published TCP ports. Without `network` the VM gets a host-only
        /// network — reachable from the host, no route out.
        public var ports: [PortForward] = []
        /// Host loopback ports the guest reaches as
        /// `host.micropod.internal:<port>`.
        public var exposeHost: [UInt16] = []
        /// Guest nameservers; default is the network gateway.
        public var dnsResolvers: [String] = []
        /// Keep stdin attached (`-i`).
        public var interactive = false
        /// Drive a guest pty from the host terminal (`-t`).
        public var tty = false
        /// Host allowlist and injected secrets. Non-empty with `network`, the
        /// VM gets a host-only network and reaches the internet solely
        /// through the host's egress proxy.
        public var egress = EgressPolicy()
        /// Host directory holding `micropod-guest`, shared read-only at
        /// ``SandboxGuestTool/guestDirectory`` (SandboxService sandboxes).
        public var guestTool: URL?
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

        /// Whether the VM needs a network device, and which kind.
        public var networkMode: vmnet.operating_modes_t? {
            if network { return egress.isEmpty ? .VMNET_SHARED_MODE : .VMNET_HOST_MODE }
            return ports.isEmpty && exposeHost.isEmpty ? nil : .VMNET_HOST_MODE
        }
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

    /// A configured-but-not-booted sandbox VM. `network` keeps the vmnet
    /// network alive for the VM's lifetime: releasing it early kills the
    /// guest mid-teardown ("virtual machine stopped unexpectedly").
    struct Prepared: @unchecked Sendable {
        let id: String
        let container: LinuxContainer
        let rootfsPath: URL
        let imageRef: String
        let diskBytes: UInt64
        let network: SandboxNetwork?
        let guestIP: String?
        let gateway: String?
        let ports: [PortForward]
        let exposeHost: [UInt16]
        let egress: EgressProxy?
        /// The main process's env, user and working directory, no argv —
        /// the base for processes exec'd into the sandbox.
        let processTemplate: LinuxProcessConfiguration
        /// `micropod-guest` is mounted at ``SandboxGuestTool/guestPath``.
        let hasGuestTool: Bool
        let forwarding = SandboxForwarding()
    }

    /// Resolve the base disk, clone it into `runDir` and configure the VM.
    static func prepare(
        _ options: Options,
        id: String,
        runDir: URL,
        stdout: any Writer,
        stderr: any Writer,
        stdin: (any ReaderStream)? = nil,
        terminal: Terminal? = nil,
        trace: Trace = Trace(),
        progress: @Sendable (String) -> Void
    ) async throws -> Prepared {
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

        var kernel = Kernel(path: try kernelURL(), platform: .linuxArm)
        kernel.commandLine.kernelArgs += kernelArgs
        if let extra = ProcessInfo.processInfo.environment["MICROPOD_SANDBOX_KERNEL_ARGS"] {
            kernel.commandLine.kernelArgs += extra.split(separator: " ").map(String.init)
        }
        let manager = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: try await initfs(store: store, progress: progress))
        trace.mark("initfs")

        // One vmnet network per sandbox. Host mode (published ports or
        // exposed host ports without --allow-net) reaches the host and
        // nothing else.
        let vmnet = try options.networkMode.map { try SandboxNetwork(mode: $0) }
        let network = vmnet.map { (interface: $0.interface, gateway: $0.gateway.description) }
        if vmnet != nil { trace.mark("network") }
        var shares: [Containerization.Mount] = []
        for (index, spec) in options.mounts.enumerated() {
            shares.append(try shareMount(spec, runDir: runDir, index: index))
        }
        if let tool = options.guestTool {
            shares.append(.share(source: tool.path, destination: SandboxGuestTool.guestDirectory, options: ["ro"]))
        }
        // Proxied egress: the guest's only way out is the host proxy on the
        // gateway; secrets reach it as placeholders, plus a CA to trust.
        var egressEnv: [String] = []
        var egress: EgressProxy?
        if options.network, !options.egress.isEmpty, let network {
            let proxy = "http://\(network.gateway):\(EgressProxy.port)"
            egressEnv = ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"].map { "\($0)=\(proxy)" }
            egressEnv += ["NO_PROXY=localhost,127.0.0.1,::1", "no_proxy=localhost,127.0.0.1,::1"]
            egressEnv += options.egress.secrets.map { "\($0.name)=\($0.placeholder)" }
            var ca: SandboxCA?
            if !options.egress.secrets.isEmpty {
                let authority = try SandboxCA.loadOrCreate()
                let dir = runDir.appendingPathComponent("ca")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try authority.pem.write(to: dir.appendingPathComponent("ca.pem"), atomically: true, encoding: .utf8)
                try authority.bundle().write(
                    to: dir.appendingPathComponent("bundle.pem"), atomically: true, encoding: .utf8)
                shares.append(.share(source: dir.path, destination: "/etc/micropod-ca", options: ["ro"]))
                let bundle = "/etc/micropod-ca/bundle.pem"
                egressEnv += [
                    "SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "GIT_SSL_CAINFO", "AWS_CA_BUNDLE",
                ]
                .map { "\($0)=\(bundle)" }
                egressEnv.append("NODE_EXTRA_CA_CERTS=/etc/micropod-ca/ca.pem")
                ca = authority
            }
            egress = EgressProxy(policy: options.egress, ca: ca)
        }
        if options.mounts.contains(where: { $0.hasSuffix(":overlay") }) { trace.mark("overlay") }

        // What every process in the sandbox starts from: the image's env,
        // user and working directory with the run's env on top. Exec'd
        // processes (the API's Exec, SandboxService) get it too —
        // Containerization would otherwise start them bare (root, `/`, PATH
        // only), without the run's env or proxy settings.
        var template = imageConfig.map { LinuxProcessConfiguration(from: $0) } ?? LinuxProcessConfiguration()
        template.environmentVariables = mergeEnv(mergeEnv(template.environmentVariables, egressEnv), options.env)
        if let workdir = options.workdir { template.workingDirectory = workdir }
        let process = template
        template.arguments = []

        let container = try LinuxContainer(id, rootfs: rootfs, vmm: manager) { cfg in
            cfg.process = process
            cfg.cpus = options.cpus
            cfg.memoryInBytes = options.memoryMiB * 1024 * 1024
            cfg.hostname = options.hostname
            if let path = ProcessInfo.processInfo.environment["MICROPOD_SANDBOX_BOOTLOG"] {
                cfg.bootLog = .file(path: URL(fileURLWithPath: path), append: false)
            }
            if let entrypoint = options.entrypoint {
                cfg.process.arguments = entrypoint + options.arguments
            } else if !options.arguments.isEmpty {
                // Explicit command replaces CMD but keeps the entrypoint,
                // matching `docker run image cmd…`.
                cfg.process.arguments =
                    (imageConfig?.entrypoint ?? []) + options.arguments
            }
            guard !cfg.process.arguments.isEmpty else {
                throw MicropodError.message("invalidArgument: image \(imageRef) has no default command")
            }
            if let terminal {
                cfg.process.setTerminalIO(terminal: terminal)
            } else {
                cfg.process.stdout = stdout
                cfg.process.stderr = stderr
                cfg.process.stdin = stdin
            }
            if options.tmpfsTmp {
                var opts = ["nosuid", "nodev", "mode=1777"]
                if let size = options.tmpSizeMiB { opts.append("size=\(size)m") }
                cfg.mounts.append(
                    .any(type: "tmpfs", source: "tmpfs", destination: "/tmp", options: opts))
            }
            cfg.mounts.append(contentsOf: shares)
            if let network {
                cfg.interfaces = [network.interface]
                cfg.dns = DNS(
                    nameservers: options.dnsResolvers.isEmpty ? [network.gateway] : options.dnsResolvers)
                if !options.exposeHost.isEmpty {
                    var hosts = Hosts.default
                    hosts.entries.append(
                        .init(ipAddress: network.gateway, hostnames: [SandboxForwarding.hostAlias]))
                    cfg.hosts = hosts
                }
            }
        }
        return Prepared(
            id: id, container: container, rootfsPath: rootfsPath, imageRef: imageRef,
            diskBytes: diskBytes, network: vmnet,
            guestIP: network.map { $0.interface.ipv4Address.address.description },
            gateway: network?.gateway, ports: options.ports, exposeHost: options.exposeHost, egress: egress,
            processTemplate: template, hasGuestTool: options.guestTool != nil)
    }

    /// Open the sandbox's relays: needs the VM's network up (after
    /// `create()`) and must precede `start()`, so the workload never sees a
    /// port that isn't forwarded yet.
    static func openForwards(_ prepared: Prepared) async throws {
        guard let guestIP = prepared.guestIP, let gateway = prepared.gateway else { return }
        for port in prepared.ports {
            try prepared.forwarding.listen(on: port.hostIP, port.hostPort, to: guestIP, port.guestPort)
        }
        // Gateway listeners: the address appears on the host bridge as the
        // guest's interface comes up — retry briefly rather than racing it.
        func onGateway(_ bind: () throws -> Void) async throws {
            var attempt = 0
            while true {
                do {
                    return try bind()
                } catch  where attempt < 20 {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        for port in prepared.exposeHost {
            try await onGateway { try prepared.forwarding.listen(on: gateway, port, to: "127.0.0.1", port) }
        }
        if let egress = prepared.egress {
            try await onGateway { prepared.forwarding.track(try egress.start(on: gateway)) }
        }
    }

    /// prepare() + create(), once more if the VM is lost before the workload
    /// starts. Virtualization's VM process can die just after launch (an MTE
    /// fault in vmnet, seen seven times on one host on 2026-09-30); nothing
    /// has run in the guest yet, so a fresh VM is safe. Each attempt gets
    /// half of `bootTimeout`: a VM that dies mid-setup can leave create()
    /// waiting forever, and that attempt is abandoned (and stopped, should it
    /// ever finish) rather than failing the run. Request errors aren't
    /// retried.
    static func prepareAndCreate(
        _ options: Options,
        id: String,
        runDir: URL,
        stdout: any Writer,
        stderr: any Writer,
        stdin: (any ReaderStream)? = nil,
        terminal: Terminal? = nil,
        trace: Trace = Trace(),
        progress: @Sendable (String) -> Void
    ) async throws -> Prepared {
        var attempt = 1
        while true {
            let prepared = try await prepare(
                options, id: id, runDir: runDir, stdout: stdout, stderr: stderr, stdin: stdin,
                terminal: terminal, trace: trace, progress: progress)
            let container = prepared.container
            do {
                try await withTimeout(
                    options.bootTimeout / 2, "guest did not boot",
                    abandoned: { try? await container.stop() },
                    { try await container.create() })
                return prepared
            } catch  where attempt == 1 && isLostVM(error) {
                attempt += 1
                progress("VM lost while booting (\(error)); retrying once")
                prepared.forwarding.stop()
                for leftover in ["rootfs.ext4", "mounts", "ca"] {
                    try? FileManager.default.removeItem(at: runDir.appendingPathComponent(leftover))
                }
            }
        }
    }

    /// Whether a create() failure means the VM went away rather than the
    /// request being wrong: Virtualization's internal error ("failed to
    /// start", "stopped unexpectedly"), the agent never answering, or its
    /// connection dropping mid-setup.
    static func isLostVM(_ error: any Error) -> Bool {
        if error is BootTimeout { return true }
        if error is MicropodError { return false }  // ours: a bad spec
        let ns = error as NSError
        if ns.domain == VZErrorDomain { return ns.code == VZError.Code.internalError.rawValue }
        if let error = error as? ContainerizationError {
            switch error.code {
            case .timeout, .internalError, .interrupted, .unknown:
                return error.cause.map(isLostVM) ?? true
            default:
                return false
            }
        }
        return true  // the agent's RPC channel closing under it
    }

    /// Start a created sandbox's workload: relays first, so the workload
    /// never sees a port that isn't forwarded yet.
    static func launch(_ prepared: Prepared) async throws {
        try await openForwards(prepared)
        try await prepared.container.start()
    }

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

        let terminal: Terminal? = options.tty ? try Terminal.current : nil
        defer { terminal?.tryReset() }
        let prepared = try await prepareAndCreate(
            options, id: id, runDir: runDir,
            stdout: FileHandleWriter(.standardOutput), stderr: FileHandleWriter(.standardError),
            stdin: options.interactive && terminal == nil ? StandardInputReader() : nil,
            terminal: terminal, trace: trace, progress: progress)
        defer {
            prepared.forwarding.stop()
            withExtendedLifetime(prepared.network) {}
        }
        let container = prepared.container
        trace.mark("create")
        var status: ExitStatus
        var resizer: Task<Void, Never>?
        defer { resizer?.cancel() }
        do {
            try await openForwards(prepared)
            // Raw mode only now: progress lines printed while preparing
            // keep their carriage returns.
            try terminal?.setraw()
            try await container.start()
            trace.mark("start")
            if let terminal {
                if let size = try? terminal.size { try? await container.resize(to: size) }
                let winch = AsyncSignalHandler.create(notify: [SIGWINCH])
                resizer = Task {
                    defer { winch.cancel() }
                    for await _ in winch.signals {
                        if let size = try? terminal.size { try? await container.resize(to: size) }
                    }
                }
            }
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
        // stop() unmounts the rootfs in-guest, so a kept disk is clean. With
        // no checkpoint to save, a teardown error (the VM process already
        // gone) must not replace the finished command's exit code.
        do {
            try await container.stop()
        } catch  where options.saveAs == nil {
            progress("teardown: \(error)")
        }
        trace.mark("stop")

        if let name = options.saveAs, status.exitCode == 0 {
            try saveCheckpoint(
                name: name, disk: prepared.rootfsPath, image: prepared.imageRef,
                diskBytes: prepared.diskBytes)
            progress("checkpoint '\(name)' saved")
        }
        trace.report()
        return status.exitCode
    }

    /// `body` bounded by `limit`. On timeout the error comes back at once
    /// and `body` is left running: a VM that died mid-boot can leave a
    /// Virtualization callback that never fires, and awaiting that task —
    /// as a task group does — would hang the caller with it. `abandoned`
    /// runs if an abandoned `body` succeeds after all.
    static func withTimeout(
        _ limit: Duration, _ message: String,
        abandoned: @escaping @Sendable () async -> Void = {},
        _ body: @escaping @Sendable () async throws -> Void
    ) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let timer = Task {
                try await Task.sleep(for: limit)
                if once.claim() { continuation.resume(throwing: BootTimeout(message: message, limit: limit)) }
            }
            Task {
                do {
                    try await body()
                    if once.claim() { continuation.resume() } else { await abandoned() }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
                timer.cancel()
            }
        }
    }

    struct BootTimeout: LocalizedError, CustomStringConvertible {
        let message: String
        let limit: Duration
        var description: String { "\(message) within \(limit)" }
        var errorDescription: String? { description }
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
            // Keyed by exact size: a cached disk of another size is a different base.
            let size =
                options.diskBytes % (1 << 30) == 0 ? "\(options.diskBytes >> 30)g" : "\(options.diskBytes >> 20)m"
            let base = imagesDir.appendingPathComponent("\(key)-\(size).ext4")
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

    /// The Containerization release micropod links (Package.swift pins it
    /// exactly; `SandboxVMInitTests` keeps the two in step).
    static let linkedContainerizationVersion = "0.42.0"

    /// The `vminit` image the sandbox boots, from the references in the
    /// store. The store holds the `vminit` of every `container` release that
    /// ran `system start` here: an upgrade to 1.5.0 adds `vminit:0.47.0`
    /// beside `0.42.0`. Prefer the one matching the linked library, so the
    /// guest agent and its host-side client stay one release: from 0.47,
    /// `vminitd` refuses copy and stat requests without the `root` field a
    /// 0.42 client never sends. Otherwise the first `vminit`, as before.
    static func pickVMInit(_ references: [String]) -> String? {
        let vminits = references.filter { $0.contains("containerization/vminit") }
        return vminits.first { $0.hasSuffix(":" + linkedContainerizationVersion) } ?? vminits.first
    }

    /// vminitd initfs, unpacked once from the store's `vminit` image.
    static func initfs(store: ImageStore, progress: @Sendable (String) -> Void) async throws -> Containerization.Mount {
        let images = try await store.list()
        guard let reference = pickVMInit(images.map(\.reference)),
            let vminit = images.first(where: { $0.reference == reference })
        else {
            throw MicropodError.message("no vminit image — run `container system start` once")
        }
        if !reference.hasSuffix(":" + linkedContainerizationVersion) {
            progress("using \(reference); micropod's sandbox is built for vminit \(linkedContainerizationVersion)")
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

    /// Appended to Containerization's defaults. Expedited RCU: vminitd's
    /// cgroup setup and every container spawn otherwise wait out
    /// jiffy-scale grace periods — ~30 ms of each boot; in a few-vCPU guest
    /// the IPIs that expedite them cost nothing. `MICROPOD_SANDBOX_KERNEL_ARGS`
    /// appends more (e.g. `initcall_debug ignore_loglevel` with
    /// `MICROPOD_SANDBOX_BOOTLOG`).
    static let kernelArgs = ["rcupdate.rcu_expedited=1"]

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

    static func shareMount(_ spec: String, runDir: URL, index: Int) throws -> Containerization.Mount {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || (parts.count == 3 && ["ro", "rw", "overlay"].contains(parts[2])),
            !parts[0].isEmpty, parts[1].hasPrefix("/")
        else { throw MicropodError.message("mount '\(spec)' — want host:/guest[:ro|rw|overlay]") }
        let host = URL(fileURLWithPath: parts[0]).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: host) else {
            throw MicropodError.message("mount source \(host) does not exist")
        }
        let mode = parts.count == 3 ? parts[2] : "rw"
        guard mode == "overlay" else {
            return .share(source: host, destination: parts[1], options: mode == "ro" ? ["ro"] : [])
        }
        guard host != "/" else {
            throw MicropodError.message("invalidArgument: refusing to overlay-mount /")
        }
        let clone = runDir.appendingPathComponent("mounts/\(index)-\(URL(fileURLWithPath: host).lastPathComponent)")
        try FileManager.default.createDirectory(
            at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cloneTree(host, to: clone.path)
        return .share(source: clone.path, destination: parts[1], options: [])
    }

    /// APFS clone of a file or a whole directory tree: one syscall, CoW, so
    /// it costs metadata only. Another volume can't clone — fall back to a
    /// recursive copy that still clones file by file where it can.
    static func cloneTree(_ source: String, to destination: String) throws {
        if clonefile(source, destination, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        let err = errno
        guard err == EXDEV || err == ENOTSUP else {
            throw MicropodError.message("clonefile \(source): \(String(cString: strerror(err)))")
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        guard copyfile(source, destination, nil, flags) == 0 else {
            throw MicropodError.message("copying \(source): \(String(cString: strerror(errno)))")
        }
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

/// Host stdin as the guest's stdin (`-i` without a pty); EOF closes it.
final class StandardInputReader: ReaderStream {
    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let handle = FileHandle.standardInput
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
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

/// True for the first caller only — settles a race between two completions.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
