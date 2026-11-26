import Foundation
import MicropodCore

/// The tools answered by the Micropod API daemon over binary Connect: every
/// container, image, volume, network, machine and stats tool on every
/// engine (Apple's included), the caches and the rig, telemetry, and the
/// sandbox micro-VMs, which boot in the daemon's process. Nothing here
/// starts a process: when no daemon takes the connection the call throws
/// `LocalAPI.Unreachable`, and the server answers the tools that can work
/// without it from the `container` CLI instead (`MCPServer.cliFallback`).
struct APITools {
    let api: LocalAPI
    /// The MCP server's own environment, for sandbox secrets (`NAME=ENV@host`
    /// takes the value from here, as `micropod sandbox run --secret` does).
    var environment: [String: String] = ProcessInfo.processInfo.environment

    struct Reply {
        var text: String
        var isError = false
    }

    /// The tool's reply, or nil when the API does not answer this tool.
    func call(_ name: String, _ args: MCPArguments) async throws -> Reply? {
        switch name {
        // MARK: Apple's runtime and the host
        case "status":
            let dependency = try await api.unary(
                "SystemService", "GetRuntimeDependency", Micropod_V1_Empty(), as: Micropod_V1_RuntimeDependency.self)
            guard dependency.hasStatus else { return Reply(text: "\(dependency.state) | \(dependency.message)") }
            let status = dependency.status
            return Reply(text: "\(status.status) | cli \(status.cliVersion) | apiserver \(status.apiServerVersion)")

        case "runtime_status":
            let dependency = try await api.unary(
                "SystemService", "GetRuntimeDependency", Micropod_V1_Empty(), as: Micropod_V1_RuntimeDependency.self)
            return Reply(text: ControlPlaneJSON.text(ControlPlaneJSON.runtimeDependency(dependency)))

        case "df":
            let usage = try await api.unary(
                "SystemService", "GetDiskUsage", Micropod_V1_Empty(), as: Micropod_V1_DiskUsage.self)
            return Reply(
                text: """
                    Containers: \(ByteFormat.string(usage.containers.sizeBytes)) [\(ByteFormat.string(usage.containers.reclaimableBytes)) reclaimable]
                    Images: \(ByteFormat.string(usage.images.sizeBytes)) [\(ByteFormat.string(usage.images.reclaimableBytes)) reclaimable]
                    Volumes: \(ByteFormat.string(usage.volumes.sizeBytes)) [\(ByteFormat.string(usage.volumes.reclaimableBytes)) reclaimable]
                    """)

        case "metrics_history":
            let target = args.string("id")
            let kind = args.optionalString("kind") ?? (target.isEmpty ? "system" : "container")
            guard let parsedKind = MetricsStore.Kind(rawValue: kind) else {
                return Reply(text: "kind must be system, container or machine", isError: true)
            }
            guard let range = MetricsStore.parseRange(args.optionalString("range") ?? "1h") else {
                return Reply(text: "range: want e.g. 15m, 1h, 24h, 7d", isError: true)
            }
            let history = try await api.unary(
                "SystemService", "GetMetricsHistory",
                Micropod_V1_GetMetricsHistoryRequest.with {
                    $0.kind = kind
                    $0.id = target
                    $0.rangeSeconds = UInt32(min(range, 30 * 86400))
                }, as: Micropod_V1_MetricsHistory.self)
            let title = parsedKind == .system ? "all containers" : "\(kind) \(target)"
            return Reply(text: MetricsStore.summary(Self.points(history), title: title, range: range))

        // MARK: Containers, on every engine
        case "list_containers":
            let containers = try await listContainers()
            let lines = containers.map { c -> String in
                let runtime = Self.nonApple(c.runtime)
                guard let runtime else {
                    return "\(c.id)\t\(c.state)\t\(c.image)\(c.ipv4Address.isEmpty ? "" : "\t\(c.ipv4Address)")"
                }
                return "\(c.id)\t\(c.state)\t\(c.image)\t[\(runtime)]"
            }
            return Reply(text: lines.isEmpty ? "No containers" : lines.joined(separator: "\n"))

        case "compose_ps":
            let lines = try await listContainers()
                .filter { $0.labels["com.skunkworq.micropod.compose"] == args.string("name") }
                .map { "\($0.id)\t\($0.state)\t\($0.image)" }
            return Reply(
                text: lines.isEmpty ? "No containers for stack \(args.string("name"))" : lines.joined(separator: "\n"))

        case "start", "stop", "restart", "kill", "delete":
            let target = args.string("id")
            let verb = [
                "start": "Started", "stop": "Stopped", "restart": "Restarted", "kill": "Killed", "delete": "Deleted",
            ][name]!
            let ref = Micropod_V1_ContainerRef.with { $0.id = target }
            switch name {
            case "start": try await api.call("ContainerService", "StartContainer", ref)
            case "stop": try await api.call("ContainerService", "StopContainer", ref)
            case "restart": try await api.call("ContainerService", "RestartContainer", ref)
            case "kill": try await api.call("ContainerService", "KillContainer", ref)
            default:
                try await api.call(
                    "ContainerService", "DeleteContainer",
                    Micropod_V1_DeleteContainerRequest.with {
                        $0.id = target
                        $0.force = true
                    })
            }
            return Reply(text: "\(verb) \(target)")

        case "run":
            // No runtime: Apple's, as this tool has always run.
            let runtime = args.optionalString("runtime") ?? "apple"
            let reply = try await api.unary(
                "ContainerService", "RunContainer",
                Micropod_V1_RunContainerRequest.with {
                    $0.image = args.string("image")
                    $0.detach = true
                    $0.runtime = runtime
                    if let name = args.optionalString("name") { $0.name = name }
                    if let memory = args.optionalString("memory") { $0.memory = memory }
                    if let command = args.optionalString("command") { $0.arguments = ["/bin/sh", "-c", command] }
                }, as: Micropod_V1_ContainerRef.self, timeout: api.longCallSeconds)
            return Reply(text: runtime == "apple" ? "Started \(reply.id)" : "Started \(reply.id) on \(runtime)")

        case "exec":
            let reply = try await api.unary(
                "ContainerService", "Exec",
                Micropod_V1_ExecRequest.with {
                    $0.id = args.string("id")
                    $0.arguments = ["/bin/sh", "-c", args.string("command")]
                }, as: Micropod_V1_ExecResponse.self, timeout: api.longCallSeconds)
            let output = reply.output + reply.error
            return Reply(
                text: (output.isEmpty ? "No output" : output)
                    + (reply.exitCode == 0 ? "" : "\n(exit \(reply.exitCode))"),
                isError: reply.exitCode != 0)

        case "inspect":
            let container = try await api.unary(
                "ContainerService", "GetContainer", Micropod_V1_ContainerRef.with { $0.id = args.string("id") },
                as: Micropod_V1_Container.self)
            let json = try container.jsonUTF8Data()
            let object = try JSONSerialization.jsonObject(with: json)
            return Reply(text: ControlPlaneJSON.prettyText(object))

        case "logs":
            let count = args.integer("lines").map { Int($0) } ?? 100
            let lines = try await tailLogs(args.string("id"), lines: count)
            return Reply(text: lines.isEmpty ? "No logs" : lines.joined(separator: "\n"))

        case "stats":
            let stats = try await api.unary(
                "ContainerService", "GetStats", Micropod_V1_GetStatsRequest(), as: Micropod_V1_GetStatsResponse.self)
            guard !stats.snapshot.containers.isEmpty else { return Reply(text: "No running containers") }
            return Reply(
                text: stats.snapshot.containers.map { s in
                    "\(s.id)\tmem \(ByteFormat.string(s.memoryUsedBytes))/\(ByteFormat.string(s.memoryLimitBytes))\tnet ↓\(ByteFormat.string(s.networkRxBytes)) ↑\(ByteFormat.string(s.networkTxBytes))\t\(s.pids) pids"
                }.joined(separator: "\n"))

        // MARK: Images, volumes, networks
        case "list_images":
            let images = try await api.unary(
                "ImageService", "ListImages", Micropod_V1_Empty(), as: Micropod_V1_ListImagesResponse.self)
            let lines = images.images.map { image -> String in
                let line =
                    "\(image.names.first ?? image.id)\t\(ByteFormat.string(image.sizeBytes))\t\(image.id.prefix(19))"
                return Self.nonApple(image.runtime).map { "\(line)\t[\($0)]" } ?? line
            }
            return Reply(text: lines.isEmpty ? "No images" : lines.joined(separator: "\n"))

        case "pull":
            let runtime = args.optionalString("runtime") ?? "apple"
            try await api.stream(
                "ImageService", "PullImage",
                Micropod_V1_PullImageRequest.with {
                    $0.reference = args.string("reference")
                    $0.runtime = runtime
                }, as: Micropod_V1_ProgressLine.self, deadline: .seconds(api.longCallSeconds)
            ) { _ in true }
            return Reply(
                text: runtime == "apple"
                    ? "Pulled \(args.string("reference"))" : "Pulled \(args.string("reference")) on \(runtime)")

        case "list_volumes":
            let volumes = try await api.unary(
                "VolumeService", "ListVolumes", Micropod_V1_Empty(), as: Micropod_V1_ListVolumesResponse.self)
            let lines = volumes.volumes.map { volume -> String in
                let line = "\(volume.id)\t\(ByteFormat.string(volume.sizeBytes))\t\(volume.driver)"
                return Self.nonApple(volume.labels["com.micropod.runtime"] ?? "").map { "\(line)\t[\($0)]" } ?? line
            }
            return Reply(text: lines.isEmpty ? "No volumes" : lines.joined(separator: "\n"))

        case "list_networks":
            let networks = try await api.unary(
                "NetworkService", "ListNetworks", Micropod_V1_Empty(), as: Micropod_V1_ListNetworksResponse.self)
            let lines = networks.networks.map { n in
                "\(n.id)\t\(n.mode)\(n.builtin ? " (builtin)" : "")\t\(n.ipv4Subnet)"
            }
            return Reply(text: lines.isEmpty ? "No networks" : lines.joined(separator: "\n"))

        // MARK: Machines
        case "list_machines":
            let machines = try await api.unary(
                "MachineService", "ListMachines", Micropod_V1_Empty(), as: Micropod_V1_ListMachinesResponse.self)
            let lines = machines.machines.map { m -> String in
                [
                    m.id + (m.default ? " (default)" : ""), m.state.isEmpty ? "unknown" : m.state, m.ipAddress,
                    m.cpus > 0 ? "\(m.cpus) cpu" : "", m.memoryBytes > 0 ? ByteFormat.string(m.memoryBytes) : "",
                ].filter { !$0.isEmpty }.joined(separator: "\t")
            }
            return Reply(text: lines.isEmpty ? "No machines" : lines.joined(separator: "\n"))

        case "machine_stats":
            let snapshot = try await api.unary(
                "MachineService", "GetMachineStats",
                Micropod_V1_GetMachineStatsRequest.with { $0.id = args.optionalString("id") ?? "" },
                as: Micropod_V1_MachineStatsSnapshot.self)
            guard !snapshot.machines.isEmpty else { return Reply(text: "No running machines") }
            return Reply(
                text: snapshot.machines.map { m -> String in
                    [
                        "\(m.id) (\(m.containerID))",
                        String(format: "cpu %.1f%% of %d vCPU", m.cpuPercent, m.cpus),
                        "mem \(ByteFormat.string(m.memoryUsedBytes))/\(ByteFormat.string(m.memoryLimitBytes))",
                        "net ↓\(ByteFormat.string(m.networkRxBytes)) ↑\(ByteFormat.string(m.networkTxBytes))",
                        "block r \(ByteFormat.string(m.blockReadBytes)) w \(ByteFormat.string(m.blockWriteBytes))",
                        "\(m.pids) pids",
                    ].joined(separator: "\t")
                }.joined(separator: "\n"))

        case "machine_logs":
            let lines = LineCollector()
            try await api.stream(
                "MachineService", "StreamMachineLogs",
                Micropod_V1_StreamMachineLogsRequest.with {
                    $0.id = args.string("id")
                    $0.tail = Int32(clamping: args.integer("lines") ?? 100)
                    $0.boot = args.flag("boot")
                }, as: Micropod_V1_LogChunk.self, deadline: .seconds(api.socketTimeoutSeconds)
            ) { chunk in
                lines.append(chunk.text)
                return true
            }
            return Reply(text: lines.lines.isEmpty ? "No logs" : lines.lines.joined(separator: "\n"))

        // MARK: Kubernetes (the engine's own config decides; the API drives the VM)
        case "k8s_status":
            let status = try await api.unary(
                "K8sService", "GetK8sStatus", Micropod_V1_Empty(), as: Micropod_V1_K8sStatus.self)
            var lines = [
                "enabled=\(status.enabled)",
                "exists=\(status.exists) running=\(status.running) nodeReady=\(status.nodeReady)",
            ]
            if !status.address.isEmpty { lines.append("api=https://\(status.address):6443") }
            lines.append("kubeconfig=\(status.kubeconfigPath)")
            return Reply(text: lines.joined(separator: "\n"))

        // MARK: Engines and modes
        case "runtimes":
            let runtimes = try await api.unary(
                "SystemService", "ListRuntimes", Micropod_V1_Empty(), as: Micropod_V1_ListRuntimesResponse.self)
            return Reply(text: LocalAPI.describe(runtimes))

        case "runtime_set_default":
            let runtimes = try await api.unary(
                "SystemService", "SetDefaultRuntime",
                Micropod_V1_SetDefaultRuntimeRequest.with { $0.name = args.string("name") },
                as: Micropod_V1_ListRuntimesResponse.self)
            return Reply(text: "Default runtime → \(runtimes.default)")

        case "runtime_update":
            let runtimes = try await api.unary(
                "SystemService", "UpdateRuntime",
                Micropod_V1_UpdateRuntimeRequest.with {
                    $0.name = args.string("name")
                    if let enabled = args.bool("enabled") { $0.enabled = enabled }
                    if let endpoint = args.optionalString("endpoint") { $0.endpoint = endpoint }
                }, as: Micropod_V1_ListRuntimesResponse.self)
            return Reply(text: LocalAPI.describe(runtimes))

        case _ where CacheTools.names.contains(name):
            return Reply(text: try await CacheTools.call(name, args, api: api))

        case _ where SandboxTools.names.contains(name):
            return try await SandboxTools(api: api, environment: environment).call(name, args)

        default:
            return nil
        }
    }

    /// Every engine's containers, as the daemon lists them.
    private func listContainers() async throws -> [Micropod_V1_Container] {
        try await api.unary(
            "ContainerService", "ListContainers", Micropod_V1_Empty(), as: Micropod_V1_ListContainersResponse.self
        ).containers
    }

    /// The engine's name when it is not Apple's.
    static func nonApple(_ runtime: String) -> String? {
        runtime.isEmpty || runtime == "apple" ? nil : runtime
    }

    /// The last `lines` log lines: the tail and the end of the stream
    /// (`no_follow`), read to the end so the connection is kept. A daemon
    /// that predates `no_follow` follows instead; then reading stops at
    /// `lines` or a quiet second, and the connection is closed.
    func tailLogs(_ id: String, lines: Int) async throws -> [String] {
        let collected = LineCollector()
        try await api.stream(
            "ContainerService", "StreamContainerLogs",
            Micropod_V1_StreamLogsRequest.with {
                $0.id = id
                $0.tail = Int32(clamping: lines)
                $0.noFollow = true
            }, as: Micropod_V1_LogChunk.self, deadline: .seconds(api.socketTimeoutSeconds), quiet: .seconds(1)
        ) { chunk in
            collected.append(chunk.text)
            return collected.count <= lines
        }
        return Array(collected.lines.suffix(lines))
    }

    static func points(_ history: Micropod_V1_MetricsHistory) -> (resolution: Int64, points: [MetricsStore.Point]) {
        let formatter = ISO8601DateFormatter()
        return (
            Int64(history.resolutionSeconds),
            history.points.map { p in
                MetricsStore.Point(
                    timestamp: formatter.date(from: p.timestamp) ?? Date(timeIntervalSince1970: 0),
                    average: MetricsStore.Sample(
                        cpuPercent: p.cpuPercent, memoryUsedBytes: p.memoryUsedBytes,
                        memoryLimitBytes: p.memoryLimitBytes, networkRxRate: p.networkRxBytesPerSecond,
                        networkTxRate: p.networkTxBytesPerSecond, blockReadRate: p.blockReadBytesPerSecond,
                        blockWriteRate: p.blockWriteBytesPerSecond),
                    peak: MetricsStore.Sample(
                        cpuPercent: p.cpuPercentMax, memoryUsedBytes: p.memoryUsedBytesMax,
                        memoryLimitBytes: p.memoryLimitBytes, networkRxRate: p.networkRxBytesPerSecondMax,
                        networkTxRate: p.networkTxBytesPerSecondMax, blockReadRate: p.blockReadBytesPerSecondMax,
                        blockWriteRate: p.blockWriteBytesPerSecondMax))
            }
        )
    }
}

/// Lines collected by a stream reader.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var count: Int { lock.withLock { storage.count } }
    var lines: [String] { lock.withLock { storage } }
}
