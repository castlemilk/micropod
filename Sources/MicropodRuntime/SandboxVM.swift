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
/// The kernel is Micropod's own (its HVF kernel, staged into
/// `~/.micropod/sandbox` by `sandbox setup`); the vminit image is Apple's,
/// pulled by a pinned digest into the same store. The `container` install's
/// kernel is used only with `MICROPOD_LEGACY_APPLE=1`.
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
        var ciKernel: URL?
        var ciWorkspace: String?
        var ciPublishedMTU: UInt32?
        var ciPublishedGSOBytes: UInt32?
        var ciOCITools: URL?
        var ciKataTools: URL?
        var isolatedCIJob = false
        var ciExt4MaxBatchUS: Int?
        public var rootlessDocker = false
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

    public static let appSupport =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.container")

    /// Standalone Micropod sandbox root (`MICROPOD_SANDBOX_ROOT` overrides `~/.micropod/sandbox`).
    public static var root: URL {
        if let configured = ProcessInfo.processInfo.environment["MICROPOD_SANDBOX_ROOT"], !configured.isEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".micropod/sandbox")
    }
    static var kernelsDir: URL { root.appendingPathComponent("kernels") }
    static var defaultKernelLink: URL { kernelsDir.appendingPathComponent("default.kernel-arm64") }
    static var contentDir: URL { root.appendingPathComponent("content") }
    static var imagesDir: URL { root.appendingPathComponent("images") }
    static var checkpointsDir: URL { root.appendingPathComponent("checkpoints") }
    static var runsDir: URL { root.appendingPathComponent("runs") }

    /// Where a sandbox asset was resolved from (`standalone` needs zero Apple `container` install).
    public enum AssetOrigin: String, Codable, Sendable, Equatable {
        case envOverride = "env"
        case standalone
        case hvfFallback = "hvf"
        case legacyApple = "apple_container"
        case missing
    }

    public struct AssetStatus: Codable, Sendable, Equatable {
        public var root: String
        public var kernelOrigin: AssetOrigin
        public var kernelPath: String?
        /// What `sandbox setup` staged the standalone kernel from.
        public var kernelSource: KernelSource?
        /// The digest-pinned vminit sandboxes boot (`repository:tag@sha256:…`).
        public var vminit: String
        public var contentOrigin: AssetOrigin
        public var contentPath: String
        public var initfsPaths: [String]
        public var standaloneReady: Bool
    }

    /// Base disk + the image whose config (env, cwd, entrypoint) applies.
    struct Checkpoint: Codable {
        var image: String
        var diskBytes: UInt64
        var created: Date
    }

    static func resolveCIImage(
        _ ref: String, progress: @Sendable (String) -> Void
    ) async throws -> Containerization.Image {
        let store = try imageStore()
        let imageRef = try normalize(ref)
        do {
            return try await store.get(reference: imageRef)
        } catch let error as ContainerizationError where error.code == .notFound {
            progress("Pulling the Linux ARM64 CI worker image")
            return try await store.pull(reference: imageRef, platform: .current)
        }
    }

    static func validateRootlessDocker(_ options: Options) throws {
        guard options.rootlessDocker else { return }
        guard options.mounts.isEmpty, options.ports.isEmpty, options.exposeHost.isEmpty,
            options.egress.isEmpty, options.saveAs == nil
        else {
            throw MicropodError.message(
                "invalidArgument: rootless Docker sandboxes cannot expose host resources or save checkpoints")
        }
        if case .checkpoint = options.base {
            throw MicropodError.message("invalidArgument: rootless Docker sandboxes cannot use checkpoints")
        }
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
        let publishedNetwork: SandboxNetwork?
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
        private let stopper = SandboxVMStop()

        func stop() async throws {
            try await stopper.run {
                try await container.stop()
            }
            // A late vmnet callback may settle an earlier ambiguous result.
            // Recheck it without replaying the VM stop mutation.
            try network?.stop()
            try publishedNetwork?.stop()
            forwarding.stop()
        }

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
        progress: @Sendable (String) -> Void,
        didOwnNetwork: @Sendable (any SandboxNetworkCleanup) async -> Void = { _ in },
        ciWorker: CIWorker? = nil
    ) async throws -> Prepared {
        try validateRootlessDocker(options)
        let store = try imageStore()
        let imageRef: String
        let diskBytes: UInt64
        let image: Containerization.Image
        let rootfsPath: URL
        if let ciWorker {
            guard case .image(let ref) = options.base else {
                throw MicropodError.message("CI worker requires an image")
            }
            imageRef = try normalize(ref)
            diskBytes = options.diskBytes
            do {
                image = try await store.get(reference: imageRef)
            } catch let error as ContainerizationError where error.code == .notFound {
                progress("Pulling the Linux ARM64 CI worker image")
                image = try await store.pull(reference: imageRef, platform: .current)
            }
            rootfsPath = try await ciWorker.openDisk(image: image, bytes: diskBytes, progress: progress)
        } else {
            let baseDisk: URL
            (baseDisk, imageRef, diskBytes) = try await resolveBase(options, store: store, progress: progress)
            image = try await store.get(reference: imageRef)
            trace.mark("resolve")
            rootfsPath = runDir.appendingPathComponent("rootfs.ext4")
            try clone(baseDisk, to: rootfsPath)
        }
        let imageConfig = try await image.config(for: .current).config
        // Adaptive batching is the mixed CI default. Dedicated workers can tune the fsync wait
        // while retaining ext4 write barriers and ordered journaling on their journaled disks.
        let rootfs = Containerization.Mount.block(
            format: "ext4", source: rootfsPath.path, destination: "/",
            options: options.ciExt4MaxBatchUS.map { ["max_batch_time=\($0)"] } ?? [])
        trace.mark("clone")

        let bootKernel = try options.ciKernel ?? kernelURL()
        if options.ciKernel != nil {
            guard (try bootKernel.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw MicropodError.message("Worker kernel must be a regular Linux ARM64 Image")
            }
            progress("Worker kernel: " + bootKernel.path)
        }
        var kernel = Kernel(path: bootKernel, platform: .linuxArm)
        kernel.commandLine.kernelArgs += kernelArgs
        // The Apple guest kernel builds PSI with CONFIG_PSI_DEFAULT_DISABLED.
        if ciWorker != nil {
            kernel.commandLine.kernelArgs += [
                "psi=1",
                "cgroup.memory=nokmem,nosocket",
                "slab_min_order=2",
                "swiotlb=noforce",
                "workqueue.power_efficient=1",
                "micropod.ci_sysctls=perf",
            ]
        }
        if let extra = ProcessInfo.processInfo.environment["MICROPOD_SANDBOX_KERNEL_ARGS"] {
            kernel.commandLine.kernelArgs += extra.split(separator: " ").map(String.init)
        }
        let manager = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: try await initfs(store: store, pin: try vminitPin(), progress: progress))
        trace.mark("initfs")

        // One vmnet network per sandbox. Host mode (published ports or
        // exposed host ports without --allow-net) reaches the host and
        // nothing else.
        let vmnet: SandboxNetwork?
        if ciWorker != nil, let mode = options.networkMode {
            vmnet = try await SandboxNetwork.workerNetwork(mode: mode)
        } else {
            vmnet = try options.networkMode.map { try SandboxNetwork(mode: $0, pinBridge: options.rootlessDocker) }
            if let vmnet {
                await didOwnNetwork(vmnet)
                try vmnet.waitUntilReady()
            }
        }
        // A host-only second interface keeps Mac listeners connected while the
        // egress bridge is recovering. Older runner bundles use the primary link.
        let publishedNetwork: SandboxNetwork?
        if ciWorker?.isNativeRunner == true, let tools = options.ciOCITools,
            FileManager.default.fileExists(atPath: tools.appendingPathComponent("runner/published-ports.sh").path)
        {
            publishedNetwork = try await SandboxNetwork.workerNetwork(
                mode: .VMNET_HOST_MODE, publicationMTU: options.ciPublishedMTU,
                publicationGSOBytes: options.ciPublishedGSOBytes)
        } else {
            if options.ciPublishedMTU != nil || options.ciPublishedGSOBytes != nil {
                throw MicropodError.message(
                    "The selected runner bundle cannot provision a private publication interface")
            }
            publishedNetwork = nil
        }
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
        if let publishedNetwork {
            template.environmentVariables += [
                "MICROPOD_CI_PUBLISH_IPV4=" + publishedNetwork.interface.ipv4Address.address.description,
                "MICROPOD_CI_PUBLISH_GATEWAY=" + publishedNetwork.gateway.description,
            ]
        }
        if let workdir = options.workdir { template.workingDirectory = workdir }
        if options.isolatedCIJob {
            template.noNewPrivileges = true
            template.capabilities = .init(capabilities: [])
        }
        let process = template
        template.arguments = []

        let container = try LinuxContainer(id, rootfs: rootfs, vmm: manager) { cfg in
            cfg.process = process
            cfg.cpus = options.cpus
            cfg.memoryInBytes = options.memoryMiB * 1024 * 1024
            cfg.hostname = options.hostname
            if options.rootlessDocker {
                // This VM is the Linux host for rootless Docker. OCI proc
                // submount locks prevent its child user namespaces from
                // mounting proc at all. The VM remains the isolation boundary;
                // no host mounts, sockets, exposed ports or checkpoints are
                // permitted, and no extra process capability is granted.
                cfg.readonlyPaths = []
                cfg.maskedPaths = []
            }
            if let ciWorker {
                // The upstream engine administers its own dedicated Linux VM. Its only integration
                // with macOS by default is this outbound socket. A configured checkout is shared at its Mac path.
                // The configured resources are the whole VM's budget, including the guest agent.
                if let path = options.ciWorkspace {
                    cfg.mounts.append(.share(source: path, destination: path))
                }
                if let tools = options.ciOCITools {
                    cfg.mounts.append(.share(source: tools.path, destination: "/opt/micropod-oci", options: ["ro"]))
                    cfg.sockets.append(
                        UnixSocketConfiguration(
                            source: URL(fileURLWithPath: CIWorker.guestOCI),
                            destination: ciWorker.ociSocket, permissions: [.ownerRead, .ownerWrite], direction: .outOf))
                }
                if let kata = options.ciKataTools {
                    cfg.virtualization = true
                    cfg.mounts.append(.share(source: kata.path, destination: "/opt/kata", options: ["ro"]))
                }
                cfg.cpuOverhead = 0
                cfg.memoryOverhead = 0
                cfg.process.capabilities = .allCapabilities
                // Retain images and volumes on ext4. Recreate daemon PID and runtime files on every boot.
                cfg.mounts.append(
                    .any(
                        type: "tmpfs", source: "tmpfs", destination: "/run", options: ["nosuid", "nodev", "mode=0755"]))
                cfg.maskedPaths = []
                cfg.readonlyPaths = []
                cfg.sockets.append(
                    UnixSocketConfiguration(
                        source: URL(fileURLWithPath: CIWorker.guestSocket), destination: ciWorker.dockerSocket,
                        permissions: [.ownerRead, .ownerWrite], direction: .outOf))
                if ciWorker.isNativeRunner {
                    cfg.sockets.append(
                        UnixSocketConfiguration(
                            source: URL(fileURLWithPath: "/var/lib/micropod/buildkit.sock"),
                            destination: ciWorker.buildkitSocket, permissions: [.ownerRead, .ownerWrite],
                            direction: .outOf))
                    cfg.sockets.append(
                        UnixSocketConfiguration(
                            source: ciWorker.portSocket,
                            destination: URL(fileURLWithPath: "/var/lib/micropod/ports.sock"),
                            permissions: [.ownerRead, .ownerWrite], direction: .into))
                }
            }
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
                if let publishedNetwork { cfg.interfaces.append(publishedNetwork.interface) }
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
            diskBytes: diskBytes, network: vmnet, publishedNetwork: publishedNetwork,
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
        progress: @Sendable (String) -> Void,
        didOwnNetwork: @Sendable (any SandboxNetworkCleanup) async -> Void = { _ in },
        didPrepare: @Sendable (Prepared) async -> Void = { _ in }
    ) async throws -> Prepared {
        var attempt = 1
        while true {
            let prepared = try await prepare(
                options, id: id, runDir: runDir, stdout: stdout, stderr: stderr, stdin: stdin,
                terminal: terminal, trace: trace, progress: progress, didOwnNetwork: didOwnNetwork)
            await didPrepare(prepared)
            let container = prepared.container
            // An allocation owns one VM, including an uncertain create. Do
            // not detach/retry a boot underneath its durable reservation.
            if options.rootlessDocker {
                try await container.create()
                return prepared
            }
            do {
                try await withTimeout(
                    options.bootTimeout / 2, "guest did not boot",
                    abandoned: { try? await container.stop() },
                    { try await container.create() })
                return prepared
            } catch  where !options.rootlessDocker && attempt == 1 && isLostVM(error) {
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

    /// One disposable Apple VM per allocation, with a cloned root disk and no workload NIC or host shares.
    public static func isolatedCIJob(image: String, arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first, !command.isEmpty else {
            throw MicropodError.message("Missing job command")
        }
        var options = Options(base: .image(image))
        options.isolatedCIJob = true
        options.entrypoint = [command]
        options.arguments = Array(arguments.dropFirst())
        options.cpus = 1
        options.memoryMiB = 1024
        options.diskBytes = 4 << 30
        options.timeoutSeconds = 6 * 60 * 60
        return try await run(options) { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
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

    /// A `vminit` image named by its tag and pinned by its digest. vminitd is
    /// the init of every sandbox VM, untrusted workloads included, and a tag
    /// can be moved: only the digest names the bytes.
    public struct VMInitPin: Sendable, Equatable, CustomStringConvertible {
        /// `registry/path`, without tag or digest.
        public let repository: String
        public let tag: String?
        /// `sha256:<64 lowercase hex>`, the image index's digest.
        public let digest: String

        public init(repository: String, tag: String?, digest: String) {
            self.repository = repository
            self.tag = tag
            self.digest = digest
        }

        /// Parses `repository[:tag]@sha256:<digest>`. A reference without a
        /// digest is refused: it would boot whatever the tag names today.
        public init(parsing raw: String) throws {
            let parts = raw.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, Self.isDigest(parts[1]), !parts[0].isEmpty else {
                throw MicropodError.message(
                    "invalidArgument: vminit '\(raw)' must be pinned by digest (repository[:tag]@sha256:<digest>)")
            }
            let name = try SandboxVM.normalize(parts[0])
            let reference = try Reference.parse(name)
            // `normalize` adds `latest` to an untagged name; keep the tag only if one was given.
            let tagged = parts[0].split(separator: "/").last?.contains(":") == true
            self.init(repository: reference.name, tag: tagged ? reference.tag : nil, digest: parts[1])
        }

        static func isDigest(_ text: String) -> Bool {
            text.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
        }

        /// `repository[:tag]@digest`: the tag says which release, the digest which bytes.
        public var reference: String { repository + (tag.map { ":" + $0 } ?? "") + "@" + digest }
        public var description: String { reference }
        /// What is pulled: the digest alone, so the registry resolves no tag.
        public var pullReference: String { repository + "@" + digest }
    }

    /// Apple's `vminit` for the linked Containerization release, pinned to the
    /// index digest its tag named when the pin was recorded (2026-11-26, from
    /// the registry: `HEAD /v2/apple/containerization/vminit/manifests/0.42.0`
    /// answered `Docker-Content-Digest: sha256:cde8a93f…`, the SHA-256 of the
    /// index it served). Moving the Containerization pin in Package.swift
    /// means resolving and recording both again.
    public static let pinnedVMInit = VMInitPin(
        repository: "ghcr.io/apple/containerization/vminit", tag: linkedContainerizationVersion,
        digest: "sha256:cde8a93f9861c664bf2b74b4e2893cf877680806f12e7e989eb9c51b2f2e93bf")

    /// The pinned vminit as `micropod sandbox setup --vminit` takes it (tag and digest).
    public static let defaultVMInitReference = pinnedVMInit.reference

    /// The vminit sandbox runs boot: `MICROPOD_SANDBOX_VMINIT`, which must
    /// itself be digest-pinned, or ``pinnedVMInit``.
    static func vminitPin(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> VMInitPin {
        guard let configured = environment["MICROPOD_SANDBOX_VMINIT"], !configured.isEmpty else { return pinnedVMInit }
        return try VMInitPin(parsing: configured)
    }

    /// The stored image `pin` names, matched by digest: an image stored under
    /// the pinned tag but with another digest is not it, and neither is any
    /// other vminit release in the store.
    static func storedVMInit(_ images: [(reference: String, digest: String)], pin: VMInitPin) -> String? {
        images.first { $0.digest == pin.digest }?.reference
    }

    /// The vminit image to boot, verified against `pin`: a stored image with
    /// the pinned digest, or one pulled by that digest. The pull's result must
    /// carry the digest too: the registry chooses the descriptor a pull
    /// resolves to, so one answering with another image is refused and what
    /// it sent is removed from the store.
    static func verifiedVMInit(
        pin: VMInitPin,
        list: () async throws -> [Containerization.Image],
        pull: (String) async throws -> Containerization.Image,
        remove: (String) async throws -> Void,
        progress: @Sendable (String) -> Void
    ) async throws -> Containerization.Image {
        let images = try await list()
        if let reference = storedVMInit(images.map { ($0.reference, $0.digest) }, pin: pin),
            let stored = images.first(where: { $0.reference == reference && $0.digest == pin.digest })
        {
            return stored
        }
        for image in images where image.reference.contains("containerization/vminit") {
            progress("ignoring \(image.reference) (\(image.digest)): the sandbox boots only \(pin)")
        }
        progress("pulling \(pin) into the sandbox store")
        let pulled = try await pull(pin.pullReference)
        guard pulled.digest == pin.digest else {
            try? await remove(pulled.reference)
            throw MicropodError.message(
                "vminit digest mismatch: the registry served \(pulled.digest) for \(pin); refusing to boot it")
        }
        return pulled
    }

    /// The store operations a vminit pin resolves through: the sandbox's
    /// `ImageStore`, or a test's registry fake.
    struct VMInitSource: Sendable {
        var list: @Sendable () async throws -> [Containerization.Image]
        var pull: @Sendable (String) async throws -> Containerization.Image
        var remove: @Sendable (String) async throws -> Void
        /// Unpacks the verified image's initfs to a path.
        var unpack: @Sendable (Containerization.Image, URL) async throws -> Void

        static func store(_ store: ImageStore) -> VMInitSource {
            VMInitSource(
                list: { try await store.list() },
                pull: { try await store.pull(reference: $0, platform: .current) },
                remove: { try await store.delete(reference: $0, performCleanup: true) },
                unpack: { image, path in _ = try await InitImage(image: image).initBlock(at: path, for: .linuxArm) })
        }
    }

    /// The vminitd initfs for `pin`, unpacked once from the verified vminit
    /// image (pulled by digest on first use — no Apple `container` CLI or
    /// daemon required) and cached under `directory` by that digest.
    static func preparedInitfs(
        pin: VMInitPin, source: VMInitSource, directory: URL, progress: @Sendable (String) -> Void
    ) async throws -> URL {
        let vminit = try await verifiedVMInit(
            pin: pin, list: source.list, pull: source.pull, remove: source.remove, progress: progress)
        let tag = vminit.digest.replacingOccurrences(of: ":", with: "-")
        let path = directory.appendingPathComponent("initfs-\(tag).ext4")
        if !FileManager.default.fileExists(atPath: path.path) {
            progress("preparing initfs from \(pin)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tmp = directory.appendingPathComponent(".initfs-\(UUID().uuidString).ext4")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await source.unpack(vminit, tmp)
            guard rename(tmp.path, path.path) == 0 else {
                throw MicropodError.message("caching initfs: \(String(cString: strerror(errno)))")
            }
        }
        return path
    }

    static func initfs(
        store: ImageStore, pin: VMInitPin, directory: URL = root, progress: @Sendable (String) -> Void
    ) async throws -> Containerization.Mount {
        let path = try await preparedInitfs(pin: pin, source: .store(store), directory: directory, progress: progress)
        return .block(format: "ext4", source: path.path, destination: "/", options: ["ro"])
    }

    /// Appended to Containerization's defaults. Expedited RCU: vminitd's
    /// cgroup setup and every container spawn otherwise wait out
    /// jiffy-scale grace periods — ~30 ms of each boot; in a few-vCPU guest
    /// the IPIs that expedite them cost nothing. `MICROPOD_SANDBOX_KERNEL_ARGS`
    /// appends more (e.g. `initcall_debug ignore_loglevel` with
    /// `MICROPOD_SANDBOX_BOOTLOG`).
    static let kernelArgs = ["rcupdate.rcu_expedited=1"]

    /// Whether sandboxes may boot the kernel of Apple's `container` install
    /// (`MICROPOD_LEGACY_APPLE=1`). Off by default: a standalone sandbox boots
    /// Micropod's own kernel, and `sandbox setup` never copies Apple's.
    static func legacyAppleAllowed(_ environment: [String: String]) -> Bool {
        environment["MICROPOD_LEGACY_APPLE"] == "1"
    }

    /// Micropod's own ARM64 kernel, the one its HVF machine boots (it carries
    /// the virtio-pci, vsock, blk and fs drivers a Virtualization.framework
    /// VM and vminitd need): the installed machine's (`~/.micropod/hvf`, or
    /// `MICROPOD_HVF_ROOT`), else the `vmlinux-hvf` this Micropod ships in
    /// the app's Resources or beside a standalone CLI.
    static func micropodKernel(
        environment: [String: String], hvfLayout: HVFMachineLayout?, packagedExecutable: URL?
    ) -> URL? {
        let fm = FileManager.default
        let installed = (hvfLayout ?? HVFMachineLayout(environment: environment)).kernel
        if fm.fileExists(atPath: installed.path) { return installed.resolvingSymlinksInPath() }
        guard let directory = packagedExecutable?.resolvingSymlinksInPath().deletingLastPathComponent() else {
            return nil
        }
        var candidates = [directory.appendingPathComponent("vmlinux-hvf")]
        if directory.lastPathComponent == "MacOS" {
            candidates.insert(
                directory.deletingLastPathComponent().appendingPathComponent("Resources/vmlinux-hvf"), at: 0)
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }?.resolvingSymlinksInPath()
    }

    /// Whether `kernel` is the com.apple.container kernel: inside its install,
    /// or a byte copy of one of its kernels (what `sandbox setup` copied into
    /// the standalone store before it stopped). Contents are compared only
    /// for a file the size of one of Apple's.
    static func isLegacyAppleKernel(_ kernel: URL, legacyAppSupport: URL) -> Bool {
        let fm = FileManager.default
        let candidate = kernel.resolvingSymlinksInPath()
        if candidate.path.hasPrefix(legacyAppSupport.resolvingSymlinksInPath().path + "/") { return true }
        guard let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        let entries =
            (try? fm.contentsOfDirectory(
                at: legacyAppSupport.appendingPathComponent("kernels"), includingPropertiesForKeys: Array(keys)))
            ?? []
        return entries.contains { entry in
            guard let values = try? entry.resourceValues(forKeys: keys), values.isRegularFile == true,
                values.fileSize == size
            else { return false }
            return fm.contentsEqual(atPath: entry.path, andPath: candidate.path)
        }
    }

    /// Where the standalone store's kernel was staged from, recorded by
    /// `sandbox setup` beside it.
    public struct KernelSource: Codable, Sendable, Equatable {
        /// `hvf` (Micropod's own kernel) or `explicit` (`sandbox setup --kernel`).
        public var origin: String
        public var path: String
        public var sha256: String
        /// The staged file as setup left it, so a resolve can tell it is
        /// unchanged without hashing it; nil in records from before them.
        public var size: UInt64?
        public var inode: UInt64?
        public var modifiedNanoseconds: Int64?

        /// The record and `file` agree: the same inode, size and mtime as
        /// staged, else (an older record, or a file replaced since) the
        /// same SHA-256.
        func describes(_ file: URL) -> Bool {
            var info = stat()
            guard stat(file.path, &info) == 0 else { return false }
            if let size, let inode, let modifiedNanoseconds, size == UInt64(info.st_size),
                inode == UInt64(info.st_ino), modifiedNanoseconds == Self.nanoseconds(info.st_mtimespec)
            {
                return true
            }
            return (try? HVFPayloadStore.sha256File(file)) == sha256
        }

        /// `sha256` with the stat fields of `file` as it is now.
        static func record(origin: String, path: String, sha256: String, file: URL) -> KernelSource {
            var info = stat()
            let known = stat(file.path, &info) == 0
            return KernelSource(
                origin: origin, path: path, sha256: sha256, size: known ? UInt64(info.st_size) : nil,
                inode: known ? UInt64(info.st_ino) : nil,
                modifiedNanoseconds: known ? nanoseconds(info.st_mtimespec) : nil)
        }

        private static func nanoseconds(_ time: timespec) -> Int64 {
            Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
        }
    }

    static func kernelSourceURL(sandboxRoot: URL) -> URL {
        sandboxRoot.appendingPathComponent("kernels/default.kernel-arm64.source.json")
    }

    static func kernelSource(sandboxRoot: URL) -> KernelSource? {
        guard let data = try? Data(contentsOf: kernelSourceURL(sandboxRoot: sandboxRoot)) else { return nil }
        return try? JSONDecoder().decode(KernelSource.self, from: data)
    }

    /// The standalone store's kernel is one `sandbox setup` staged and
    /// recorded, and has not been replaced since. A kernel with no record
    /// (an earlier setup copied Apple's there, and Apple's install may since
    /// have changed or gone, so a byte compare proves nothing) or one that
    /// no longer matches its record (an older CLI copied over it) is not.
    static func standaloneKernelIsRecorded(_ standalone: URL, sandboxRoot: URL) -> Bool {
        guard let record = kernelSource(sandboxRoot: sandboxRoot) else { return false }
        return record.describes(standalone.resolvingSymlinksInPath())
    }

    /// Resolves the ARM64 Linux kernel a sandbox boots, Micropod's own first:
    ///   1. `MICROPOD_SANDBOX_KERNEL` env override
    ///   2. `~/.micropod/sandbox/kernels/default.kernel-arm64`, when `micropod
    ///      sandbox setup` staged and recorded it and it still matches the
    ///      record. Anything else there (a com.apple.container kernel an
    ///      earlier setup copied, a file replaced since) is not booted ahead
    ///      of Micropod's kernel, and only with `MICROPOD_LEGACY_APPLE=1`
    ///      without one.
    ///   3. Micropod's HVF kernel (``micropodKernel(environment:hvfLayout:packagedExecutable:)``)
    ///   4. `~/Library/Application Support/com.apple.container/kernels/default.kernel-arm64`,
    ///      only with `MICROPOD_LEGACY_APPLE=1`
    public static func resolveKernel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sandboxRoot: URL = root,
        legacyAppSupport: URL = appSupport,
        hvfLayout: HVFMachineLayout? = nil,
        packagedExecutable: URL? = Bundle.main.executableURL
    ) -> (url: URL, origin: AssetOrigin)? {
        let fm = FileManager.default
        let legacyAllowed = legacyAppleAllowed(environment)
        if let override = environment["MICROPOD_SANDBOX_KERNEL"], !override.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) {
                return (url.resolvingSymlinksInPath(), .envOverride)
            }
        }
        let standalone = sandboxRoot.appendingPathComponent("kernels/default.kernel-arm64")
        let hasStandalone = fm.fileExists(atPath: standalone.path)
        if hasStandalone, standaloneKernelIsRecorded(standalone, sandboxRoot: sandboxRoot) {
            return (standalone.resolvingSymlinksInPath(), .standalone)
        }
        if let micropod = micropodKernel(
            environment: environment, hvfLayout: hvfLayout, packagedExecutable: packagedExecutable)
        {
            return (micropod, .hvfFallback)
        }
        // Unrecorded, with no Micropod kernel to prefer: it may be Apple's.
        if hasStandalone, legacyAllowed { return (standalone.resolvingSymlinksInPath(), .legacyApple) }
        let legacy = legacyAppSupport.appendingPathComponent("kernels/default.kernel-arm64")
        if legacyAllowed, fm.fileExists(atPath: legacy.path) {
            return (legacy.resolvingSymlinksInPath(), .legacyApple)
        }
        return nil
    }

    /// Why no sandbox kernel resolved, and what to do about it.
    static func missingKernelMessage(environment: [String: String], hvfLayout: HVFMachineLayout?) -> String {
        let installed = (hvfLayout ?? HVFMachineLayout(environment: environment)).kernel.path
        return "no sandbox kernel: sandboxes boot Micropod's own HVF kernel (\(installed), or the vmlinux-hvf "
            + "shipped with Micropod), and none is installed. Run `micropod machine install`, or "
            + "`micropod sandbox setup --kernel <ARM64 Image>` (or set MICROPOD_SANDBOX_KERNEL). The "
            + "com.apple.container kernel is never copied into the standalone store; MICROPOD_LEGACY_APPLE=1 "
            + "boots it in place. A kernel an earlier setup left in the standalone store without a record of "
            + "where it came from is not booted: run `micropod sandbox setup` again."
    }

    static func kernelURL(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard let resolved = resolveKernel(environment: environment) else {
            throw MicropodError.message(missingKernelMessage(environment: environment, hvfLayout: nil))
        }
        return resolved.url
    }

    /// Standalone OCI image store under `~/.micropod/sandbox` (never depends on
    /// `~/Library/Application Support/com.apple.container` unless opted in via
    /// `MICROPOD_SANDBOX_LEGACY_STORE=1`).
    public static func imageStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sandboxRoot: URL = root,
        legacyAppSupport: URL = appSupport
    ) throws -> ImageStore {
        let useLegacy = environment["MICROPOD_SANDBOX_LEGACY_STORE"] == "1"
        let base = useLegacy ? legacyAppSupport : sandboxRoot
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try ImageStore(
            path: base,
            contentStore: try LocalContentStore(path: base.appendingPathComponent("content")))
    }

    /// Reports whether the sandbox engine is self-contained under `~/.micropod/sandbox`.
    public static func assetStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sandboxRoot: URL = root,
        legacyAppSupport: URL = appSupport,
        hvfLayout: HVFMachineLayout? = nil,
        packagedExecutable: URL? = Bundle.main.executableURL
    ) -> AssetStatus {
        let fm = FileManager.default
        let kernel = resolveKernel(
            environment: environment, sandboxRoot: sandboxRoot, legacyAppSupport: legacyAppSupport,
            hvfLayout: hvfLayout, packagedExecutable: packagedExecutable)
        let useLegacyStore = environment["MICROPOD_SANDBOX_LEGACY_STORE"] == "1"
        let storeBase = useLegacyStore ? legacyAppSupport : sandboxRoot
        let contentPath = storeBase.appendingPathComponent("content").path
        let contentOrigin: AssetOrigin = useLegacyStore ? .legacyApple : .standalone
        let initfs =
            ((try? fm.contentsOfDirectory(atPath: sandboxRoot.path)) ?? [])
            .filter { $0.hasPrefix("initfs-") && $0.hasSuffix(".ext4") }
            .sorted()
            .map { sandboxRoot.appendingPathComponent($0).path }
        let standaloneReady =
            (kernel?.origin == .standalone || kernel?.origin == .envOverride || kernel?.origin == .hvfFallback)
            && contentOrigin == .standalone
        return AssetStatus(
            root: sandboxRoot.path,
            kernelOrigin: kernel?.origin ?? .missing,
            kernelPath: kernel?.url.path,
            kernelSource: kernel?.origin == .standalone ? kernelSource(sandboxRoot: sandboxRoot) : nil,
            vminit: (try? vminitPin(environment: environment).reference) ?? "invalid MICROPOD_SANDBOX_VMINIT",
            contentOrigin: contentOrigin,
            contentPath: contentPath,
            initfsPaths: initfs,
            standaloneReady: standaloneReady)
    }

    /// Bootstraps `~/.micropod/sandbox` so isolated sandboxes run with zero
    /// dependency on `com.apple.container`. It stages Micropod's own ARM64
    /// kernel (or `--kernel`) as `kernels/default.kernel-arm64`, recording
    /// its source beside it, then pulls the digest-pinned `vminit` into the
    /// store and unpacks its initfs. It never copies the com.apple.container
    /// kernel, replaces one an earlier setup copied there, and fails, saying
    /// so, when Micropod has no kernel to stage.
    public static func setupStandalone(
        kernelSource: URL? = nil,
        vminitReference: String? = nil,
        sandboxRoot: URL = root,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacyAppSupport: URL = appSupport,
        hvfLayout: HVFMachineLayout? = nil,
        packagedExecutable: URL? = Bundle.main.executableURL,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> AssetStatus {
        let store = try imageStore(
            environment: environment, sandboxRoot: sandboxRoot, legacyAppSupport: legacyAppSupport)
        return try await setupStandalone(
            kernelSource: kernelSource, vminitReference: vminitReference, sandboxRoot: sandboxRoot,
            environment: environment, legacyAppSupport: legacyAppSupport, hvfLayout: hvfLayout,
            packagedExecutable: packagedExecutable, vminitSource: .store(store), progress: progress)
    }

    static func setupStandalone(
        kernelSource: URL?,
        vminitReference: String?,
        sandboxRoot: URL,
        environment: [String: String],
        legacyAppSupport: URL,
        hvfLayout: HVFMachineLayout?,
        packagedExecutable: URL?,
        vminitSource: VMInitSource,
        progress: @Sendable (String) -> Void
    ) async throws -> AssetStatus {
        // An unpinned vminit is refused before anything is staged.
        let runs = try vminitPin(environment: environment)
        let pin = try vminitReference.map(VMInitPin.init(parsing:)) ?? runs
        try stageStandaloneKernel(
            explicit: kernelSource, sandboxRoot: sandboxRoot, environment: environment,
            legacyAppSupport: legacyAppSupport, hvfLayout: hvfLayout, packagedExecutable: packagedExecutable,
            progress: progress)

        _ = try await preparedInitfs(pin: pin, source: vminitSource, directory: sandboxRoot, progress: progress)
        if pin != runs {
            progress("sandbox runs boot \(runs) unless MICROPOD_SANDBOX_VMINIT=\(pin)")
        }
        return assetStatus(
            environment: environment, sandboxRoot: sandboxRoot, legacyAppSupport: legacyAppSupport,
            hvfLayout: hvfLayout, packagedExecutable: packagedExecutable)
    }

    /// Installs `kernels/default.kernel-arm64` for the standalone store: from
    /// `explicit`, else keeps the kernel Micropod staged there, else stages
    /// Micropod's own (``micropodKernel(environment:hvfLayout:packagedExecutable:)``).
    static func stageStandaloneKernel(
        explicit: URL?,
        sandboxRoot: URL,
        environment: [String: String],
        legacyAppSupport: URL,
        hvfLayout: HVFMachineLayout?,
        packagedExecutable: URL?,
        progress: @Sendable (String) -> Void
    ) throws {
        let fm = FileManager.default
        let kernels = sandboxRoot.appendingPathComponent("kernels")
        try fm.createDirectory(at: kernels, withIntermediateDirectories: true)
        let targetKernel = kernels.appendingPathComponent("default.kernel-arm64")

        let source: (url: URL, origin: String)
        if let explicit {
            guard fm.fileExists(atPath: explicit.path) else {
                throw MicropodError.message("invalidArgument: kernel not found at \(explicit.path)")
            }
            guard !isLegacyAppleKernel(explicit, legacyAppSupport: legacyAppSupport) else {
                throw MicropodError.message(
                    "invalidArgument: \(explicit.path) is the com.apple.container kernel, which is never copied "
                        + "into the standalone sandbox store (MICROPOD_LEGACY_APPLE=1 boots it in place)")
            }
            source = (explicit.resolvingSymlinksInPath(), "explicit")
        } else {
            let micropod = micropodKernel(
                environment: environment, hvfLayout: hvfLayout, packagedExecutable: packagedExecutable)
            if fm.fileExists(atPath: targetKernel.path) {
                if standaloneKernelIsRecorded(targetKernel, sandboxRoot: sandboxRoot) {
                    progress("keeping \(targetKernel.path)")
                    return
                }
                // No record, or one that no longer matches: an earlier setup
                // copied Apple's kernel here (whether or not Apple's install
                // still has the same bytes), or something replaced the staged
                // file. Replace it with Micropod's; an Apple copy goes even
                // with nothing to replace it.
                let apple = isLegacyAppleKernel(targetKernel, legacyAppSupport: legacyAppSupport)
                guard micropod != nil || apple else {
                    throw MicropodError.message(
                        "failedPrecondition: \(targetKernel.path) has no record of where it was staged from and "
                            + "Micropod has no kernel to replace it with; run `micropod sandbox setup --kernel "
                            + "<ARM64 Image>` to stage and record one")
                }
                progress(
                    "replacing \(targetKernel.path): "
                        + (apple ? "it is the com.apple.container kernel an earlier setup copied" : "it is unrecorded"))
                let copied = targetKernel.resolvingSymlinksInPath()
                try fm.removeItem(at: targetKernel)
                if copied.deletingLastPathComponent().standardizedFileURL == kernels.standardizedFileURL {
                    try? fm.removeItem(at: copied)
                }
                try? fm.removeItem(at: kernelSourceURL(sandboxRoot: sandboxRoot))
            }
            guard let micropod else {
                throw MicropodError.message(missingKernelMessage(environment: environment, hvfLayout: hvfLayout))
            }
            source = (micropod, "hvf")
        }

        let dstFile = kernels.appendingPathComponent("vmlinux-arm64")
        let tmp = kernels.appendingPathComponent(".vmlinux-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        progress("staging the standalone sandbox kernel from \(source.url.path) (\(source.origin))")
        if clonefile(source.url.path, tmp.path, 0) != 0 {
            try fm.copyItem(at: source.url, to: tmp)
        }
        let digest = try HVFPayloadStore.sha256File(tmp)
        guard rename(tmp.path, dstFile.path) == 0 else {
            throw MicropodError.message("installing sandbox kernel: \(String(cString: strerror(errno)))")
        }
        let record = KernelSource.record(origin: source.origin, path: source.url.path, sha256: digest, file: dstFile)
        try HVFPayloadStore.atomicSymlink(destination: dstFile.lastPathComponent, at: targetKernel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: kernelSourceURL(sandboxRoot: sandboxRoot), options: .atomic)
        progress("installed \(targetKernel.path)")
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
