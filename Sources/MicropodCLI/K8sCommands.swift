import Foundation
import MicropodCore

/// `micropod k8s` — the opt-in lightweight Kubernetes engine: one micro-VM
/// running k3s, MetalLB on the vmnet subnet for real LoadBalancer IPs, and a
/// host kubeconfig written under ~/.micropod/k8s/.
enum K8sCommands {
    static func run(_ args: [String], _ services: Services) async throws {
        let service = K8sService(client: services.client)
        let sub = args.first ?? "status"

        switch sub {
        case "enable":
            var config = service.loadConfig() ?? .defaults
            config.enabled = true
            try applyFlags(Array(args.dropFirst()), to: &config)
            try service.saveConfig(config)
            print(
                "k8s engine enabled — \(config.image), \(config.cpus.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(config.cpus))" : "\(config.cpus)") cpu / \(config.memory)"
            )
            print("run `micropod k8s up` to create the cluster")

        case "disable":
            var config = service.loadConfig() ?? .defaults
            config.enabled = false
            try service.saveConfig(config)
            print("k8s engine disabled (existing cluster left running — `micropod k8s down` to remove it)")

        case "up":
            try requireEnabled(service)
            var config = service.loadConfig() ?? .defaults
            try applyFlags(Array(args.dropFirst()), to: &config)
            let status = try await service.up(config) { print("  ▸ \($0)") }
            printSummary(config, status)

        case "down":
            try requireEnabled(service)
            let config = service.loadConfig() ?? .defaults
            try await service.down(config)
            print("cluster \(config.clusterName) removed")
            print("kubeconfig kept at \(service.kubeconfigURL.path) — delete it manually if unwanted")

        case "status":
            let config = service.loadConfig() ?? .defaults
            if !service.isEnabled {
                print("k8s engine disabled — `micropod k8s enable` to opt in")
            }
            let status = try await service.status(name: config.clusterName)
            if !status.exists {
                print("no cluster — `micropod k8s up` to create one")
            } else {
                print("cluster:  \(config.clusterName)")
                print("state:    \(status.running ? "running" : "stopped")")
                if let ip = status.address { print("api:      https://\(ip):6443") }
                print("node:     \(status.nodeReady ? "ready" : "not ready")")
                print("config:   \(service.kubeconfigURL.path)")
            }

        case "kubeconfig":
            print(service.kubeconfigURL.path)

        default:
            throw UsageError(
                message: "unknown k8s command '\(sub)' — expected enable|disable|up|down|status|kubeconfig")
        }
    }

    private static func requireEnabled(_ service: K8sService) throws {
        guard service.isEnabled else {
            throw UsageError(message: "k8s engine is not enabled — run `micropod k8s enable` (or MICROPOD_K8S=1)")
        }
    }

    private static func applyFlags(_ args: [String], to config: inout K8sConfig) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            func value() throws -> String {
                i += 1
                guard i < args.count else { throw UsageError(message: "\(arg) needs a value") }
                return args[i]
            }
            switch arg {
            case "--image": config.image = try value()
            case "--memory", "-m": config.memory = try value()
            case "--cpus", "-c":
                guard let n = Double(try value()) else {
                    throw UsageError(message: "--cpus expects a number")
                }
                config.cpus = n
            case "--metallb": config.metalLB = true
            case "--no-metallb": config.metalLB = false
            case "--ingress": config.ingress = true
            case "--no-ingress": config.ingress = false
            case "--lb-pool": config.lbPool = try value()
            case "--name": config.clusterName = try value()
            default:
                throw UsageError(message: "unknown k8s flag '\(arg)'")
            }
            i += 1
        }
    }

    private static func printSummary(_ config: K8sConfig, _ status: K8sStatus) {
        print()
        print("✓ kubernetes cluster ready")
        if let ip = status.address {
            print("  api:        https://\(ip):6443")
        }
        print("  kubeconfig: \(status.kubeconfigPath)")
        print("  ingress:    \(config.ingress ? "traefik (on the node address)" : "disabled")")
        if config.metalLB {
            let pool = config.lbPool ?? K8sService.defaultLBPool(ipv4CIDR: "\(status.address ?? "")/24") ?? "?"
            print("  metallb:    \(pool) — `kubectl expose --type=LoadBalancer` gets a real IP")
        }
        print()
        print("  export KUBECONFIG=\(status.kubeconfigPath)")
    }
}
