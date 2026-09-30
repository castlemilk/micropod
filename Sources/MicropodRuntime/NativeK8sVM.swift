import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import MicropodCore

#if canImport(Virtualization)
    import Virtualization
#endif

/// Proof-of-concept for a Micropod-owned VM: the cluster VM is created
/// directly via `LinuxContainer` on `VZVirtualMachineManager` instead of
/// `container run`. Owning the `VZVirtualMachineInstance` unlocks the
/// vsock device — `container.exec` / `dialVsock` become in-process gRPC
/// calls (~2-5ms) instead of an ~80ms subprocess+XPC roundtrip per exec.
///
/// Kernel, initfs (vminitd), and the OCI image store are borrowed from
/// the `container` install so we don't ship duplicate artifacts.
public actor NativeK8sVM {
    private let container: LinuxContainer
    public let id: String

    static let appSupport =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.container")
    static let nativeDir =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".micropod/native")

    /// The installed `container` CLI's kernel (e.g. vmlinux-6.18.x).
    static func kernelURL() throws -> URL {
        let dir = appSupport.appendingPathComponent("kernels")
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
        guard
            let kernel = urls.first(where: { $0.lastPathComponent.hasPrefix("vmlinux") })
                ?? urls.first
        else {
            throw MicropodError.message("no kernel under \(dir.path)")
        }
        return kernel
    }

    /// vminitd initfs — every `container` VM carries a copy; borrow the
    /// smallest one on disk (identical content across containers).
    static func initfsURL() throws -> URL {
        let containers = appSupport.appendingPathComponent("containers")
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: containers, includingPropertiesForKeys: nil)) ?? []
        let candidates = urls.map { $0.appendingPathComponent("initfs.ext4") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard
            let initfs = candidates.min(by: {
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max)
                    < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max)
            })
        else {
            throw MicropodError.message("no initfs.ext4 — run `container` once to provision one")
        }
        return initfs
    }

    /// Ext4 rootfs unpacked from the local image store (container's own
    /// `state.json` + `content/` layout).
    static func rootfsMount(id: String, reference: String) async throws -> Containerization.Mount {
        let storeDir = nativeDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = try ImageStore(
            path: appSupport,
            contentStore: try LocalContentStore(
                path: appSupport.appendingPathComponent("content")))
        let image = try await store.get(reference: reference, pull: true)
        let rootfsPath = storeDir.appendingPathComponent("rootfs.ext4")
        let unpacker = EXT4Unpacker(capacityInBytes: 8_000_000_000)
        do {
            return try await unpacker.unpack(
                image, for: Platform.current,
                at: rootfsPath)
        } catch let err as ContainerizationError where err.code == .exists {
            return .block(
                format: "ext4", source: rootfsPath.path, destination: "/", options: [])
        }
    }

    /// Create a k3s cluster VM the same way `container run` does — same
    /// kernel, same initfs, same image — but owned by this process.
    public static func create(config: K8sConfig, progress: @Sendable (String) -> Void)
        async throws -> NativeK8sVM
    {
        progress("kernel: \(try kernelURL().lastPathComponent)")
        progress("initfs: \(try initfsURL().lastPathComponent)")

        let kernel = Kernel(path: try kernelURL(), platform: .linuxArm)
        let initfs = Containerization.Mount.block(
            format: "ext4", source: try initfsURL().path, destination: "/", options: ["ro"])

        progress("unpacking \(config.image) rootfs")
        let rootfs = try await rootfsMount(id: config.clusterName, reference: config.image)

        let manager = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)

        // OCI args = entrypoint + cmd: `/bin/k3s server …` — plus the env
        // the container CLI stamps on the init process.
        var args = ["/bin/k3s", "server", "--disable=servicelb"]
        if !config.ingress { args.append("--disable=traefik") }

        // vmnet needs the com.apple.vm.networking entitlement (unsigned
        // binaries can't create it — VMNET_UNEXPECTED_ERROR). NAT works
        // without entitlements; the PoC measures exec latency, so NAT is
        // enough — a shipped version would route through the container
        // daemon's network instead.
        let iface = NATInterface(
            ipv4Address: try CIDRv4("192.168.99.2/24"),
            ipv4Gateway: try IPv4Address("192.168.99.1"))

        let container = try LinuxContainer(
            config.clusterName,
            rootfs: rootfs,
            vmm: manager
        ) { cfg in
            cfg.cpus = Int(config.cpus)
            cfg.memoryInBytes = UInt64(1) * 1024 * 1024 * 1024
            cfg.interfaces = [iface]
            cfg.useInit = false
            // `--cap-add ALL --read-only-path NONE --masked-path NONE`
            cfg.maskedPaths = []
            cfg.readonlyPaths = []
            cfg.process.arguments = args
            cfg.process.environmentVariables = [
                "PATH=/var/lib/rancher/k3s/data/cni:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/bin/aux",
                "CRI_CONFIG_FILE=/var/lib/rancher/k3s/agent/etc/crictl.yaml",
            ]
            cfg.process.capabilities = .allCapabilities
            if config.registryMirror != nil {
                cfg.mounts.append(
                    .share(
                        source: K8sService.etcDir.path,
                        destination: "/etc/rancher/k3s"))
            }
        }
        return NativeK8sVM(container: container, id: config.clusterName)
    }

    private init(container: LinuxContainer, id: String) {
        self.container = container
        self.id = id
    }

    public func boot() async throws {
        try await container.create()
        try await container.start()
    }

    /// Direct exec through the owned VM — no CLI spawn, no apiserver
    /// middleman. Returns (stdout, exitCode).
    public func exec(_ arguments: [String]) async throws -> (String, Int32) {
        let writer = CollectWriter()
        let proc = try await container.exec(UUID().uuidString.lowercased()) { cfg in
            cfg.arguments = arguments
            cfg.stdout = writer
        }
        try await proc.start()
        let status = try await proc.wait()
        return (String(decoding: writer.data, as: UTF8.self), status.exitCode)
    }

    /// Timed exec loop — apples-to-apples with `container exec` cost.
    public func benchExec(_ arguments: [String], iterations: Int = 10)
        async throws -> (times: [Double], sampleOut: String)
    {
        var times: [Double] = []
        var lastOut = ""
        for _ in 0..<iterations {
            let t0 = ContinuousClock.now
            let (out, _) = try await exec(arguments)
            let d = t0.duration(to: .now).components
            times.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
            lastOut = out
        }
        return (times, lastOut)
    }

    /// The floor: hold ONE persistent vminitd gRPC channel and drive
    /// createProcess/startProcess/waitProcess directly (no stdio — exit
    /// code only). This is the amortized-per-op cost for scripted flows
    /// like `k8s load`, which today pays ~80ms × N CLI spawns.
    public func benchAgentExec(iterations: Int = 10) async throws -> [Double] {
        let vm: any VirtualMachineInstance = try await container.withVirtualMachineInstance { $0 }
        let agent = try await vm.dialAgent()
        var times: [Double] = []
        for _ in 0..<iterations {
            let t0 = ContinuousClock.now
            let procID = UUID().uuidString.lowercased()
            var spec = ContainerizationOCI.Spec()
            spec.root = .init(path: "/run/container/\(id)/rootfs", readonly: false)
            spec.process = .init(
                args: ["true"],
                cwd: "/",
                user: .init(),
                terminal: false
            )
            try await agent.createProcess(
                id: procID, containerID: id,
                stdinPort: nil, stdoutPort: nil, stderrPort: nil,
                ociRuntimePath: nil,
                configuration: spec,
                options: nil)
            _ = try await agent.startProcess(id: procID, containerID: id)
            _ = try await agent.waitProcess(id: procID, containerID: id, timeoutInSeconds: 30)
            let d = t0.duration(to: .now).components
            times.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
        }
        return times
    }
}

/// Accumulates process stdout in memory.
final class CollectWriter: Writer {
    nonisolated(unsafe) var data = Data()
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        self.data.append(data)
    }
    func close() throws {}
}
