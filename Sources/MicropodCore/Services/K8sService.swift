import Foundation

/// Persisted opt-in config for the lightweight Kubernetes engine.
/// `~/Library/Application Support/micropod/k8s.json` — written by
/// `micropod k8s enable`, read by every `k8s` subcommand.
/// `MICROPOD_K8S_CONFIG` overrides the path (tests); `MICROPOD_K8S=1`
/// force-enables without a file (CI).
public struct K8sConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var image: String
    public var memory: String
    public var cpus: Double
    public var metalLB: Bool
    public var ingress: Bool
    public var lbPool: String?
    public var clusterName: String

    public static let defaults = K8sConfig(
        enabled: true,
        image: "docker.io/rancher/k3s:v1.34.1-k3s1",
        memory: "1G",
        cpus: 2,
        metalLB: true,
        ingress: true,
        lbPool: nil,
        clusterName: "micropod-k3s")

    public init(
        enabled: Bool, image: String, memory: String, cpus: Double, metalLB: Bool, ingress: Bool, lbPool: String?,
        clusterName: String
    ) {
        self.enabled = enabled
        self.image = image
        self.memory = memory
        self.cpus = cpus
        self.metalLB = metalLB
        self.ingress = ingress
        self.lbPool = lbPool
        self.clusterName = clusterName
    }
}

public struct K8sStatus: Sendable {
    public var exists: Bool
    public var running: Bool
    public var address: String?
    public var nodeReady: Bool
    public var kubeconfigPath: String
}

public enum K8sError: Error, CustomStringConvertible, Sendable {
    case disabled
    case cliFailure(String)

    public var description: String {
        switch self {
        case .disabled:
            return "kubernetes engine is not enabled — run `micropod k8s enable` first"
        case .cliFailure(let msg): return msg
        }
    }
}

/// Lightweight Kubernetes on Micropod: a single micro-VM running `k3s server`
/// as its workload (etcd + apiserver + kubelet + containerd inside one VM),
/// MetalLB on the vmnet subnet for real LoadBalancer IPs, and the cluster's
/// kubeconfig rewritten to the VM address for host `kubectl`.
///
/// The VM needs more privilege than a normal container workload:
/// `--cap-add ALL` plus clearing the runtime's default read-only/masked
/// procfs paths (kubelet writes /proc/sys/kernel/panic on boot).
public struct K8sService: Sendable {
    private let client: ContainerCLIClient
    private let configURL: URL

    public init(client: ContainerCLIClient, configURL: URL? = nil) {
        self.client = client
        self.configURL = configURL ?? Self.defaultConfigURL()
    }

    static func defaultConfigURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["MICROPOD_K8S_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("micropod/k8s.json")
    }

    public var kubeconfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".micropod/k8s/kubeconfig")
    }

    public func loadConfig() -> K8sConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? MicropodJSON.decoder.decode(K8sConfig.self, from: data)
    }

    public func saveConfig(_ config: K8sConfig) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: configURL)
    }

    /// Enabled iff the config file says so or MICROPOD_K8S is truthy.
    public var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["MICROPOD_K8S"],
            ["1", "true", "yes", "on"].contains(env.lowercased())
        {
            return true
        }
        return loadConfig()?.enabled == true
    }

    // MARK: - Lifecycle

    /// Create or reuse the k3s VM, wait for the API, write the host kubeconfig,
    /// then layer MetalLB + pool when enabled.
    /// `progress` is invoked with human-readable stage lines (CLI prints them).
    @discardableResult
    public func up(_ config: K8sConfig, progress: @Sendable (String) -> Void) async throws -> K8sStatus {
        let name = config.clusterName
        let exists = await containerExists(name)
        if !exists {
            progress("creating \(name) from \(config.image)")
            _ = try await client.run(
                ContainerCommand(arguments: Self.runArgs(config)), timeout: .seconds(600))
        } else {
            progress("reusing existing \(name) VM")
            _ = try? await client.run(
                ContainerCommand(arguments: ["start", name]), timeout: .seconds(60))
        }

        progress("waiting for the API (k3s boot ~30–60s)")
        try await waitForAPI(name, timeout: 180)

        guard let address = try await containerIPv4(name) else {
            throw K8sError.cliFailure("k3s VM has no vmnet address")
        }
        try await writeHostKubeconfig(name: name, address: address)
        progress("kubeconfig written to \(kubeconfigURL.path) (server https://\(address):6443)")

        if config.metalLB {
            progress("installing MetalLB")
            do {
                try await installMetalLB(name: name, address: address, lbPool: config.lbPool, progress: progress)
            } catch {
                // The cluster is usable without the LB layer — report rather
                // than fail, since registry pulls into the guest can be slow.
                progress("MetalLB install incomplete: \(error.localizedDescription)")
            }
        }
        return try await status(name: name)
    }

    public func down(_ config: K8sConfig) async throws {
        let name = config.clusterName
        guard await containerExists(name) else { return }
        _ = try await client.run(
            ContainerCommand(arguments: ["rm", "-f", name]), timeout: .seconds(120))
    }

    public func status(name: String) async throws -> K8sStatus {
        guard await containerExists(name) else {
            return K8sStatus(
                exists: false, running: false, address: nil, nodeReady: false, kubeconfigPath: kubeconfigURL.path)
        }
        let address = try await containerIPv4(name)
        let ready =
            (try? await kubectl(name, ["get", "nodes", "--no-headers"]))?
            .contains("Ready") == true
        return K8sStatus(
            exists: true, running: address != nil, address: address,
            nodeReady: ready, kubeconfigPath: kubeconfigURL.path)
    }

    // MARK: - Internals (pure-ish, unit-tested)

    /// argv for the cluster VM — the flags that make k3s viable as a
    /// single-process VM workload. `servicelb` is disabled whenever MetalLB
    /// owns LoadBalancer type.
    static func runArgs(_ config: K8sConfig) -> [String] {
        var args = [
            "run", "-d",
            "--name", config.clusterName,
            "--memory", config.memory,
            "--cpus", ContainerCommandFactory.cpuCountString(config.cpus),
            "--cap-add", "ALL",
            "--read-only-path", "NONE",
            "--masked-path", "NONE",
            "--label", "com.micropod.k8s=node",
            config.image,
            "server",
            "--disable=servicelb",
        ]
        if !config.ingress { args.append("--disable=traefik") }
        return args
    }

    /// kubeconfig served inside the VM points at 127.0.0.1 — the apiserver
    /// cert SANs cover the vmnet address, so host access is a server swap.
    static func rewriteKubeconfig(_ raw: String, address: String) -> String {
        raw.replacingOccurrences(of: "127.0.0.1:6443", with: "\(address):6443")
    }

    /// Default MetalLB pool: the tail of the VM's own vmnet subnet
    /// (x.x.x.240–250), well clear of the DHCP leases VMs take low.
    public static func defaultLBPool(ipv4CIDR: String) -> String? {
        let ip = ipv4CIDR.split(separator: "/").first.map(String.init) ?? ipv4CIDR
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let base = parts.prefix(3).map(String.init).joined(separator: ".")
        return "\(base).240-\(base).250"
    }

    static func metalLBManifestURL(_ version: String) -> String {
        "https://raw.githubusercontent.com/metallb/metallb/\(version)/config/manifests/metallb-native.yaml"
    }

    static func poolManifest(_ range: String) -> String {
        """
        apiVersion: metallb.io/v1beta1
        kind: IPAddressPool
        metadata:
          name: micropod-vmnet
          namespace: metallb-system
        spec:
          addresses:
          - \(range)
        ---
        apiVersion: metallb.io/v1beta1
        kind: L2Advertisement
        metadata:
          name: micropod-vmnet
          namespace: metallb-system
        spec:
          ipAddressPools:
          - micropod-vmnet
        """
    }

    // MARK: - Runtime plumbing

    private func containerExists(_ name: String) async -> Bool {
        (try? await client.run(
            ContainerCommand(arguments: ["inspect", name]), timeout: .seconds(15))) != nil
    }

    /// `container inspect` emits a top-level array; `status.networks[].ipv4Address`
    /// carries the vmnet address as `a.b.c.d/prefix`.
    private func containerIPv4(_ name: String) async throws -> String? {
        guard
            let out = try? await client.run(
                ContainerCommand(arguments: ["inspect", name]), timeout: .seconds(15)),
            let data = out.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        let root: [String: Any]
        if let arr = json as? [[String: Any]] {
            root = arr.first ?? [:]
        } else if let dict = json as? [String: Any] {
            root = (dict["containers"] as? [[String: Any]])?.first ?? dict
        } else {
            return nil
        }
        let status = root["status"] as? [String: Any] ?? root
        let networks = status["networks"] as? [[String: Any]] ?? []
        let cidr = networks.first?["ipv4Address"] as? String
        return cidr?.split(separator: "/").first.map(String.init)
    }

    private func writeHostKubeconfig(name: String, address: String) async throws {
        let raw = try await kubectl(name, ["config", "view", "--raw"])
        guard !raw.isEmpty else {
            throw K8sError.cliFailure("could not read k3s kubeconfig from \(name)")
        }
        let rewritten = Self.rewriteKubeconfig(raw, address: address)
        try FileManager.default.createDirectory(
            at: kubeconfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rewritten.write(to: kubeconfigURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: kubeconfigURL.path)
    }

    private func installMetalLB(
        name: String, address: String, lbPool: String?,
        progress: @Sendable (String) -> Void
    ) async throws {
        let pool = lbPool ?? Self.defaultLBPool(ipv4CIDR: "\(address)/24")
        guard let pool else {
            throw K8sError.cliFailure("could not derive a MetalLB pool — pass --lb-pool explicitly")
        }
        _ = try await kubectl(
            name,
            [
                "apply", "-f", Self.metalLBManifestURL("v0.14.9"),
            ])
        progress("waiting for MetalLB pods (first install pulls ~60MB from quay.io — can take several minutes)")
        try await waitForNamespace(name, namespace: "metallb-system", timeout: 900, progress: progress)
        _ = try await kubectl(name, ["apply", "-f", "-"], stdin: Self.poolManifest(pool))
        progress("MetalLB pool \(pool) (L2 on the VM subnet)")
    }

    private func waitForAPI(_ name: String, timeout: Int) async throws {
        for _ in 0..<timeout {
            if let out = try? await kubectl(name, ["get", "--raw=/readyz"]), out.contains("ok") {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw K8sError.cliFailure("k3s API did not become ready in \(timeout)s — check `micropod logs \(name)`")
    }

    private func waitForNamespace(
        _ name: String, namespace: String, timeout: Int,
        progress: @Sendable (String) -> Void
    ) async throws {
        var retriedStall = false
        for tick in 0..<timeout / 5 {
            if let out = try? await kubectl(
                name,
                [
                    "get", "pods", "-n", namespace, "--no-headers",
                ]), !out.isEmpty
            {
                let lines = out.split(separator: "\n")
                if lines.allSatisfy({ $0.contains("Running") }) { return }
                // Registry pulls inside the VM occasionally stall; one pod
                // restart unsticks containerd more often than not.
                if !retriedStall, tick > 24,
                    lines.contains(where: { $0.contains("ContainerCreating") })
                {
                    retriedStall = true
                    progress("a metallb image pull stalled — restarting the pod")
                    _ = try? await kubectl(
                        name,
                        [
                            "delete", "pod", "-n", namespace, "--all",
                        ])
                }
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw K8sError.cliFailure(
            "metallb pods not running after \(timeout)s — check `kubectl --kubeconfig \(kubeconfigURL.path) -n metallb-system describe pods`"
        )
    }

    private func kubectl(_ name: String, _ args: [String], stdin: String? = nil) async throws -> String {
        var argv = ["exec"]
        if stdin != nil { argv.append("--interactive") }
        argv.append(name)
        argv += ["kubectl"] + args
        return try await client.run(
            ContainerCommand(
                arguments: argv,
                stdinData: stdin.map { Data($0.utf8) }),
            timeout: .seconds(120))
    }
}
