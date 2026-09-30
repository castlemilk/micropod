import Foundation
import MicropodCore
import MicropodRuntime

/// `SandboxService` and `RunContainerRequest.sandbox` ↔ the sandbox
/// engine's model. The RPCs themselves are dispatched in ConnectMount.
extension APIHandlers {
    /// The sandbox engine: sandboxes live in this process whichever apple
    /// backend is current.
    var sandboxEngine: SandboxEngine { EngineRegistry.shared.sandbox }

    /// StartSandbox → a `runtime: sandbox` run request. No command idles the
    /// sandbox until it is stopped.
    func sandboxRunRequest(from req: Micropod_V1_StartSandboxRequest) throws -> ContainerRunRequest {
        guard req.image.isEmpty || req.fromCheckpoint.isEmpty else {
            throw ConnectDecodeError(code: .invalidArgument, message: "set image or from_checkpoint, not both")
        }
        for mount in req.mounts {
            guard mount.hostPath.hasPrefix("/"), mount.guestPath.hasPrefix("/"),
                ["", "overlay", "ro", "rw"].contains(mount.mode)
            else {
                throw ConnectDecodeError(
                    code: .invalidArgument,
                    message: "mount \(mount.hostPath):\(mount.guestPath) — want absolute paths, mode overlay|ro|rw")
            }
        }
        let command = req.command.isEmpty ? SandboxEngine.idleCommand : req.command
        var options = try sandboxOptions(from: req.options, network: req.allowNet)
        if !req.fromCheckpoint.isEmpty { options.fromCheckpoint = req.fromCheckpoint }
        return ContainerRunRequest(
            image: req.fromCheckpoint.isEmpty
                ? (req.image.isEmpty ? "alpine:latest" : req.image)
                : "checkpoint:\(req.fromCheckpoint)",
            name: req.name.isEmpty ? nil : req.name,
            cpus: req.cpus > 0 ? Double(req.cpus) : nil,
            memory: req.memoryMib > 0 ? "\(req.memoryMib)m" : nil,
            env: req.env,
            // Loopback unless asked: SDK sandboxes are local development.
            publishedPorts: req.ports.map {
                PortSpec(
                    hostPort: Int($0.hostPort), containerPort: Int($0.containerPort),
                    transportProtocol: $0.protocol.isEmpty ? "tcp" : $0.protocol,
                    hostIP: $0.hostIp.isEmpty ? "127.0.0.1" : $0.hostIp)
            },
            volumes: req.mounts.map { "\($0.hostPath):\($0.guestPath):\($0.mode.isEmpty ? "overlay" : $0.mode)" },
            labels: req.labels.sorted { $0.key < $1.key }.map { LabelSpec(key: $0.key, value: $0.value) },
            workdir: req.workdir.isEmpty ? nil : req.workdir,
            entrypoint: command[0],
            arguments: Array(command.dropFirst()),
            runtime: "sandbox",
            sandbox: options)
    }

    /// `SandboxOptions` → the engine's options. `network` overrides the
    /// engine default (StartSandbox is offline unless `allow_net`).
    func sandboxOptions(from proto: Micropod_V1_SandboxOptions, network: Bool?) throws -> SandboxRunOptions {
        let secrets = try proto.secrets.sorted { $0.key < $1.key }.map { name, secret in
            var ttl: Duration?
            if !secret.ttl.isEmpty {
                guard let parsed = SandboxSecretSpec.parseTTL(secret.ttl) else {
                    throw ConnectDecodeError(
                        code: .invalidArgument, message: "secret \(name): ttl '\(secret.ttl)' — want e.g. 90s, 15m, 1h")
                }
                ttl = parsed
            }
            guard secret.value.isEmpty != secret.command.isEmpty else {
                throw ConnectDecodeError(
                    code: .invalidArgument, message: "secret \(name): set exactly one of value or command")
            }
            guard !secret.hosts.isEmpty else {
                throw ConnectDecodeError(code: .invalidArgument, message: "secret \(name): hosts is required")
            }
            return SandboxSecretSpec(
                name: name, value: secret.value.isEmpty ? nil : secret.value, command: secret.command,
                commandDirectory: secret.commandDir.isEmpty ? nil : secret.commandDir, ttl: ttl,
                hosts: secret.hosts)
        }
        let ports = try proto.exposeHost.map { port -> UInt16 in
            guard let port = UInt16(exactly: port), port > 0 else {
                throw ConnectDecodeError(code: .invalidArgument, message: "expose_host port \(port) is out of range")
            }
            return port
        }
        return SandboxRunOptions(
            exposeHost: ports, allowHosts: proto.allowHosts, secrets: secrets, dnsResolvers: proto.dnsResolvers,
            diskSizeMiB: proto.diskSizeMib > 0 ? proto.diskSizeMib : nil, network: network)
    }

    static func processEvent(_ event: ProcessOutput.Event) -> Micropod_V1_ProcessEvent {
        Micropod_V1_ProcessEvent.with {
            switch event {
            case .stdout(let data): $0.stdout = data
            case .stderr(let data): $0.stderr = data
            case .exit(let code): $0.exitCode = code
            }
        }
    }

    static func fileStat(_ stat: SandboxFileStat) -> Micropod_V1_FileStat {
        Micropod_V1_FileStat.with {
            $0.path = stat.path
            $0.type = stat.type
            $0.size = stat.size
            $0.mode = stat.mode
            $0.mtime = stat.mtime
        }
    }

    static func dirEntry(_ stat: SandboxFileStat) -> Micropod_V1_DirEntry {
        Micropod_V1_DirEntry.with {
            $0.name = stat.path
            $0.type = stat.type
            $0.size = stat.size
            $0.mode = stat.mode
            $0.mtime = stat.mtime
        }
    }

    static func checkpoints() -> Micropod_V1_ListCheckpointsResponse {
        let formatter = ISO8601DateFormatter()
        return .with {
            $0.checkpoints = SandboxVM.listCheckpoints().map { checkpoint in
                .with {
                    $0.name = checkpoint.name
                    $0.image = checkpoint.image
                    $0.sizeBytes = UInt64(max(0, checkpoint.sizeBytes))
                    $0.created = formatter.string(from: checkpoint.created)
                }
            }
        }
    }
}
