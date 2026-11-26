import Darwin
import Foundation
import MicropodBuildInfo
import MicropodCore
import MicropodSharedFS

// MCP (Model Context Protocol) STDIO server for Micropod.
// JSON-RPC 2.0 over stdin/stdout.

// MARK: - Wire types

private struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: [String: JSONValue]?
}

private struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: Int?
    let result: JSONValue?
    let error: JSONRPCError?
}

private struct JSONRPCError: Codable {
    let code: Int
    let message: String
}

private struct MCPToolCall: Codable {
    let name: String
    let arguments: [String: JSONValue]?
}

// MARK: - Server entry

// The target has several files, so the entry point is this file's top-level
// code rather than `@main`.
await MicropodMCP.main()

enum MicropodMCP {
    static func main() async {
        let client = ContainerCLIClient()
        let server = MCPServer(
            client: client,
            system: SystemService(client: client),
            containers: ContainerService(client: client),
            images: ImageService(client: client),
            volumes: VolumeService(client: client),
            networks: NetworkService(client: client),
            statsSampler: StatsSampler(client: client),
            logStreamer: LogStreamer(client: client),
            compose: ComposeService(client: client),
            sharedFS: MicropodMCP.sharedFSSocketClient())
        await server.run()
    }

    /// Best-effort synchronized file shares: connect when the daemon socket
    /// exists, otherwise nil (the share_* tools report a clean error).
    private static func sharedFSSocketClient() -> (any SharedFSClient)? {
        let socket =
            ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_SOCKET"]
            ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: socket) else { return nil }
        return UnixSocketClient(socketPath: socket)
    }
}

actor MCPServer {
    private let client: ContainerCLIClient
    private let system: SystemService
    private let containers: ContainerService
    private let images: ImageService
    private let volumes: VolumeService
    private let networks: NetworkService
    private let statsSampler: StatsSampler
    private let logStreamer: LogStreamer
    private let compose: ComposeService
    /// Best-effort synchronized file shares (nil when the daemon socket is
    /// absent — the tools then report a clean error instead of failing).
    private let sharedFS: (any SharedFSClient)?
    /// The Micropod API daemon (engines, sandbox VMs, the HVF machine).
    private let api: LocalAPI
    /// App control socket — reaches Sparkle in the app process.
    private let appControl = AppControlClient()
    private var machines: MachineService { MachineService(client: client) }
    /// Held for the session so repeat machine_stats calls report CPU deltas
    /// without re-priming.
    private lazy var machineStats = MachineStatsSampler(client: client)

    init(
        client: ContainerCLIClient,
        system: SystemService,
        containers: ContainerService,
        images: ImageService,
        volumes: VolumeService,
        networks: NetworkService,
        statsSampler: StatsSampler,
        logStreamer: LogStreamer,
        compose: ComposeService,
        sharedFS: (any SharedFSClient)?,
        api: LocalAPI = .live()
    ) {
        self.client = client
        self.system = system
        self.containers = containers
        self.images = images
        self.volumes = volumes
        self.networks = networks
        self.statsSampler = statsSampler
        self.logStreamer = logStreamer
        self.compose = compose
        self.sharedFS = sharedFS
        self.api = api
    }

    private static func sharedFSSocketClient() -> (any SharedFSClient)? {
        let socket =
            ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_SOCKET"]
            ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: socket) else { return nil }
        return UnixSocketClient(socketPath: socket)
    }

    private static var noDaemonMessage: String {
        "shared-fs daemon is not running (no socket at ~/micropod/share-cache/socket or $MICROPOD_SHAREDFS_SOCKET)"
    }

    /// Human-readable rendering of an update check/status report.
    private func describeUpdate(_ report: [String: Any]) -> String {
        var line = "update: \(report["state"] as? String ?? "unknown")"
        if let current = report["currentVersion"] as? String, !current.isEmpty { line += " | running \(current)" }
        if let version = report["availableVersion"] as? String {
            line += " | \(version) available"
            if report["downloaded"] as? Bool == true { line += ", downloaded" }
            if report["readyToInstall"] as? Bool == true {
                line += ", staged"
            }
        }
        if let checked = report["checkedAt"] as? String { line += " | checked \(checked)" }
        if let error = report["error"] as? String {
            line += " — \(error)"
        }
        if let reason = report["restartBlockedReason"] as? String { line += " | installation blocked: \(reason)" }
        return line
    }

    // MARK: - Main loop

    func run() async {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        var buffer = Data()

        while true {
            let data = stdin.availableData
            if data.isEmpty { break }
            buffer.append(data)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                let response = await handle(line: line)
                if let response {
                    try? stdout.write(contentsOf: response)
                    try? stdout.write(contentsOf: Data("\n".utf8))
                }
            }
        }

        // EOF with a partial line: a client that flushes its final
        // message without a trailing newline still deserves a response.
        if let line = String(data: buffer, encoding: .utf8),
            !line.trimmingCharacters(in: .whitespaces).isEmpty,
            let response = await handle(line: line)
        {
            try? stdout.write(contentsOf: response)
            try? stdout.write(contentsOf: Data("\n".utf8))
        }
    }

    func handle(line: String) async -> Data? {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: Data(line.utf8)) else {
            return nil
        }
        let id = request.id

        switch request.method {
        case "initialize":
            return respond(
                id: id,
                result: .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object([
                        "tools": .object([:])
                    ]),
                    "serverInfo": .object([
                        "name": .string("micropod"),
                        "version": .string(MicropodBuildInfo.version),
                    ]),
                ]))

        case "notifications/initialized":
            return nil

        case "tools/list":
            return respond(id: id, result: .object(["tools": .array(MCPToolCatalog.tools.map(\.listing))]))

        case "tools/call":
            guard let params = request.params,
                let paramsData = try? JSONEncoder().encode(params),
                let toolCall = try? JSONDecoder().decode(MCPToolCall.self, from: paramsData)
            else {
                return respondError(id: id, code: -32602, message: "Invalid tool call payload")
            }
            return await callTool(id: id, toolCall)

        default:
            return respondError(id: id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Responses

    private func respond(id: Int?, result: JSONValue) -> Data? {
        let response = JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
        return try? JSONEncoder().encode(response)
    }

    private func respondError(id: Int?, code: Int, message: String) -> Data? {
        let response = JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message))
        return try? JSONEncoder().encode(response)
    }

    private func toolResult(_ id: Int?, _ text: String, isError: Bool = false) -> Data? {
        respond(
            id: id,
            result: .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(text)])
                ]),
                "isError": .bool(isError),
            ]))
    }

    // MARK: - Tools

    /// Sandboxes boot in-process in whoever launches them, which needs the
    /// virtualization entitlement the `micropod` CLI carries and this
    /// server doesn't — so sandbox tools run the CLI. Output is combined
    /// stdout+stderr, capped at the last 64 KiB.
    private static func runMicropod(_ arguments: [String]) async throws -> (Int32, String) {
        let env = ProcessInfo.processInfo.environment
        // From the app bundle, the CLI beside this binary is the same release.
        let sibling = CLIInstall.currentExecutable().deletingLastPathComponent().appendingPathComponent("micropod-cli")
            .path
        let candidates = [
            env["MICROPOD_CLI"], sibling, "\(NSHomeDirectory())/.local/bin/micropod", "/usr/local/bin/micropod",
        ]
        guard let cli = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw MicropodError.message("micropod CLI not found (set MICROPOD_CLI)")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let collected = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (process.terminationStatus, collected.text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func callTool(id: Int?, _ call: MCPToolCall) async -> Data? {
        guard let tool = MCPToolCatalog.tool(named: call.name) else {
            return respondError(id: id, code: -32601, message: "Unknown tool: \(call.name)")
        }
        let args: MCPArguments
        do {
            args = try MCPArguments(call.arguments ?? [:], for: tool)
        } catch {
            return toolResult(id, error.localizedDescription, isError: true)
        }
        func applyK8sArgs(config: inout K8sConfig) throws {
            if let image = args.optionalString("image") { config.image = image }
            if let memory = args.optionalString("memory") { config.memory = memory }
            if let cpus = args.number("cpus") {
                guard cpus > 0 else { throw MCPArgumentError(message: "\(call.name): cpus must be positive") }
                config.cpus = cpus
            }
            if let metalLB = args.bool("metallb") { config.metalLB = metalLB }
            if let ingress = args.bool("ingress") { config.ingress = ingress }
            if let pool = args.optionalString("lb_pool") { config.lbPool = pool }
            if let name = args.optionalString("name") { config.clusterName = name }
        }

        do {
            switch call.name {
            case "runtime_manage":
                let report = try await ManagedRuntimeControl.request(args.string("action"))
                return toolResult(
                    id,
                    String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            case "runtime_status":
                let report = await system.dependencyStatus()
                return toolResult(id, String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            case "status":
                let status = try await system.status()
                return toolResult(
                    id, "\(status.status) | cli \(status.cliVersion) | apiserver \(status.apiServerVersion)")

            case "list_containers":
                // Apple's containers from the runtime; sandbox and Docker ones
                // from the API daemon that owns them.
                let local: [Micropod_V1_Container]
                do {
                    local = try await self.containers.list()
                } catch {
                    let remote = await api.nonAppleContainers()
                    guard !remote.isEmpty else { throw error }
                    local = []
                }
                var lines = local.map { c -> String in
                    "\(c.id)\t\(c.state)\t\(c.image)\(c.ipv4Address.isEmpty ? "" : "\t\(c.ipv4Address)")"
                }
                lines += await api.nonAppleContainers().map { c in
                    "\(c["id"] as? String ?? "?")\t\(c["state"] as? String ?? "?")\t\(c["image"] as? String ?? "")\t[\(c["runtime"] as? String ?? "")]"
                }
                return toolResult(id, lines.isEmpty ? "No containers" : lines.joined(separator: "\n"))

            case "start", "stop", "restart", "kill", "delete":
                let target = args.string("id")
                let verb = [
                    "start": "Started", "stop": "Stopped", "restart": "Restarted", "kill": "Killed",
                    "delete": "Deleted",
                ][call.name]!
                if let engine = await api.nonAppleEngine(for: target) {
                    let method = call.name.prefix(1).uppercased() + call.name.dropFirst() + "Container"
                    var body: [String: Any] = ["id": target]
                    if call.name == "delete" { body["force"] = true }
                    _ = try await api.connect("ContainerService", method, body)
                    return toolResult(id, "\(verb) \(target) [\(engine)]")
                }
                switch call.name {
                case "start": try await containers.start(target)
                case "stop": try await containers.stop(target)
                case "restart": try await containers.restart(target)
                case "kill": try await containers.kill(target)
                default: try await containers.delete(target, force: true)
                }
                return toolResult(id, "\(verb) \(target)")

            case "run" where !args.string("runtime").isEmpty && args.string("runtime") != "apple":
                // Non-apple engines are owned by the API daemon (sandbox VMs
                // live in its process), so route the run through it.
                var body: [String: Any] = ["image": args.string("image"), "runtime": args.string("runtime")]
                if let name = args.optionalString("name") { body["name"] = name }
                if let memory = args.optionalString("memory") { body["memory"] = memory }
                if let command = args.optionalString("command") { body["arguments"] = ["/bin/sh", "-c", command] }
                // Replies once the image is pulled and the container started.
                let reply = try await api.call("POST", "/v1/containers", body, timeout: api.longCallSeconds)
                return toolResult(id, "Started \(reply["id"] as? String ?? "?") on \(args.string("runtime"))")

            case "runtimes":
                return toolResult(id, LocalAPI.describe(try await api.call("GET", "/v1/runtimes")))

            case "runtime_set_default":
                let reply = try await api.call("PUT", "/v1/runtimes/default", ["name": args.string("name")])
                return toolResult(id, "Default runtime → \(reply["default"] as? String ?? "?")")

            case "runtime_update":
                var body: [String: Any] = [:]
                if let enabled = args.bool("enabled") { body["enabled"] = enabled }
                if let endpoint = args.optionalString("endpoint") { body["endpoint"] = endpoint }
                let name = try LocalAPI.pathSegment(args.string("name"), name: "name")
                let reply = try await api.call("PATCH", "/v1/runtimes/\(name)", body)
                return toolResult(id, LocalAPI.describe(reply))

            case "run":
                var request = ContainerRunRequest(
                    image: args.string("image"), name: args.optionalString("name"), detach: true)
                if let memory = args.optionalString("memory") { request.memory = memory }
                if let command = args.optionalString("command") { request.arguments = ["/bin/sh", "-c", command] }
                let containerID = try await containers.run(request)
                return toolResult(id, "Started \(containerID)")

            case "exec":
                if await api.nonAppleEngine(for: args.string("id")) != nil {
                    let reply = try await api.connect(
                        "ContainerService", "Exec",
                        ["id": args.string("id"), "arguments": ["/bin/sh", "-c", args.string("command")]],
                        timeout: api.longCallSeconds)
                    let output = (reply["output"] as? String ?? "") + (reply["error"] as? String ?? "")
                    let code = (reply["exitCode"] as? Int) ?? Int(reply["exitCode"] as? String ?? "0") ?? 0
                    return toolResult(
                        id, (output.isEmpty ? "No output" : output) + (code == 0 ? "" : "\n(exit \(code))"),
                        isError: code != 0)
                }
                let output = try await containers.exec(
                    ContainerExecRequest(containerID: args.string("id"), arguments: [args.string("command")]))
                return toolResult(id, output.isEmpty ? "No output" : output)

            case "stats":
                let snapshot = try await statsSampler.snapshot()
                guard !snapshot.containers.isEmpty else { return toolResult(id, "No running containers") }
                let lines = snapshot.containers.map { stats -> String in
                    "\(stats.id)\tmem \(ByteFormat.string(stats.memoryUsedBytes))/\(ByteFormat.string(stats.memoryLimitBytes))\tnet ↓\(ByteFormat.string(stats.networkRxBytes)) ↑\(ByteFormat.string(stats.networkTxBytes))\t\(stats.pids) pids"
                }
                return toolResult(id, lines.joined(separator: "\n"))

            case "sandbox_run", "sandbox_checkpoint_create":
                var argv = ["sandbox"]
                if call.name == "sandbox_checkpoint_create" {
                    argv += ["checkpoint", "create", args.string("name")]
                } else {
                    argv.append("run")
                }
                if let cpus = args.integer("cpus") { argv += ["--cpus", String(cpus)] }
                if let memory = args.integer("memory") { argv += ["--memory", String(memory)] }
                if let timeout = args.integer("timeout") { argv += ["--timeout", String(timeout)] }
                if let workdir = args.optionalString("workdir") { argv += ["--workdir", workdir] }
                if args.flag("allow_net") { argv.append("--allow-net") }
                if args.flag("allow_host_writes") { argv.append("--allow-host-writes") }
                for mount in args.list("mounts") { argv += ["--mount", mount] }
                for host in args.list("allow_hosts") { argv += ["--allow-host", host] }
                for port in args.list("expose_host") { argv += ["--expose-host", port] }
                for port in args.list("ports") { argv += ["--publish", port] }
                for secret in args.list("secrets") { argv += ["--secret", secret] }
                for env in args.list("env") { argv += ["--env", env] }
                if let from = args.optionalString("from") {
                    argv += ["--from", from]
                } else if let image = args.optionalString("image") {
                    argv.append(image)
                }
                argv += ["--", "/bin/sh", "-c", args.string("command")]
                let (code, output) = try await Self.runMicropod(argv)
                return toolResult(id, "exit \(code)\n\(output)", isError: code != 0)

            case "sandbox_checkpoints", "sandbox_checkpoint_delete":
                var argv = ["sandbox", "checkpoint"]
                if call.name == "sandbox_checkpoint_delete" {
                    argv += ["rm", args.string("name")]
                } else {
                    argv.append("ls")
                }
                let (code, output) = try await Self.runMicropod(argv)
                return toolResult(id, output, isError: code != 0)

            case "list_machines":
                let list = try await machines.list()
                let lines = list.map { m -> String in
                    [
                        m.name + (m.defaultMachine == true ? " (default)" : ""),
                        m.state ?? "unknown",
                        m.ip ?? "",
                        m.cpus.map { "\($0) cpu" } ?? "",
                        m.memory ?? "",
                    ].filter { !$0.isEmpty }.joined(separator: "\t")
                }
                return toolResult(id, lines.isEmpty ? "No machines" : lines.joined(separator: "\n"))

            case "metrics_history":
                let target = args.string("id")
                guard
                    let kind = MetricsStore.Kind(
                        rawValue: args.optionalString("kind") ?? (target.isEmpty ? "system" : "container"))
                else {
                    return toolResult(id, "kind must be system, container or machine", isError: true)
                }
                guard let range = MetricsStore.parseRange(args.optionalString("range") ?? "1h") else {
                    return toolResult(id, "range: want e.g. 15m, 1h, 24h, 7d", isError: true)
                }
                guard let store = MetricsStore.shared else {
                    return toolResult(id, "the metrics store can't be opened", isError: true)
                }
                let key = kind == .system ? "all" : target
                let title = kind == .system ? "all containers" : "\(kind.rawValue) \(target)"
                return toolResult(
                    id,
                    MetricsStore.summary(
                        store.history(kind, key, range: min(range, 30 * 86400)), title: title, range: range))

            case "machine_stats":
                let snapshot = try await machineStats.snapshot(id: args.optionalString("id"))
                guard !snapshot.machines.isEmpty else { return toolResult(id, "No running machines") }
                let lines = snapshot.machines.map { m -> String in
                    [
                        "\(m.id) (\(m.containerID))",
                        String(format: "cpu %.1f%% of %d vCPU", m.cpuPercent, m.cpus),
                        "mem \(ByteFormat.string(m.memoryUsedBytes))/\(ByteFormat.string(m.memoryLimitBytes))",
                        "net ↓\(ByteFormat.string(m.networkRxBytes)) ↑\(ByteFormat.string(m.networkTxBytes))",
                        "block r \(ByteFormat.string(m.blockReadBytes)) w \(ByteFormat.string(m.blockWriteBytes))",
                        "\(m.pids) pids",
                    ].joined(separator: "\t")
                }
                return toolResult(id, lines.joined(separator: "\n"))

            case "machine_logs":
                let count = args.integer("lines").map { Int($0) } ?? 100
                let lines = try await machines.logs(args.string("id"), tail: count, boot: args.flag("boot"))
                return toolResult(id, lines.isEmpty ? "No logs" : lines.map(\.text).joined(separator: "\n"))

            case "list_images":
                // Apple's from the runtime; other engines' from the API daemon.
                let remote = await api.nonAppleResources("/v1/images", key: "images")
                let local: [Micropod_V1_Image]
                do {
                    local = try await images.list()
                } catch {
                    guard !remote.isEmpty else { throw error }
                    local = []
                }
                var lines = local.map { image -> String in
                    "\(image.names.first ?? image.id)\t\(ByteFormat.string(image.sizeBytes))\t\(image.id.prefix(19))"
                }
                lines += remote.map { image in
                    let id = image["id"] as? String ?? ""
                    let name = (image["names"] as? [String])?.first ?? id
                    let size = ByteFormat.string((image["sizeBytes"] as? NSNumber)?.uint64Value ?? 0)
                    return "\(name)\t\(size)\t\(id.prefix(19))\t[\(image["runtime"] as? String ?? "")]"
                }
                return toolResult(id, lines.isEmpty ? "No images" : lines.joined(separator: "\n"))

            case "list_volumes":
                let remote = await api.nonAppleResources("/v1/volumes", key: "volumes")
                let local: [Micropod_V1_Volume]
                do {
                    local = try await volumes.list()
                } catch {
                    guard !remote.isEmpty else { throw error }
                    local = []
                }
                var lines = local.map { volume in
                    "\(volume.id)\t\(ByteFormat.string(volume.sizeBytes))\t\(volume.driver)"
                }
                lines += remote.map { volume in
                    let size = ByteFormat.string((volume["sizeBytes"] as? NSNumber)?.uint64Value ?? 0)
                    let (name, driver) = (volume["id"] as? String ?? "?", volume["driver"] as? String ?? "")
                    return "\(name)\t\(size)\t\(driver)\t[\(volume["runtime"] as? String ?? "")]"
                }
                return toolResult(id, lines.isEmpty ? "No volumes" : lines.joined(separator: "\n"))

            case "volume_policy":
                let policy = VolumePolicyStore.load()
                var lines = [
                    "cloneMode: \(policy.cloneMode.rawValue)",
                    "goldenVolumes: "
                        + (policy.goldenVolumes.isEmpty ? "—" : policy.goldenVolumes.joined(separator: ", ")),
                    "jobsOnly: \(policy.jobsOnly)",
                    "sync: \(policy.sync?.rawValue ?? "default (fsync; nosync for clones)")",
                    "cache: \(policy.cache.rawValue)",
                ]
                lines.append("labels override: com.micropod.cache.clone / .volume.sync / .volume.cache")
                return toolResult(id, lines.joined(separator: "\n"))

            case "volume_policy_set":
                var policy = VolumePolicyStore.load()
                if let mode = args.optionalString("mode") {
                    guard let parsed = VolumePolicy.CloneMode(rawValue: mode) else {
                        return toolResult(id, "invalid mode '\(mode)' — labels|goldens|all", isError: true)
                    }
                    policy.cloneMode = parsed
                }
                if args.has("goldens") { policy.goldenVolumes = args.list("goldens") }
                if let jobsOnly = args.bool("jobsOnly") { policy.jobsOnly = jobsOnly }
                if let sync = args.optionalString("sync") {
                    if sync == "default" {
                        policy.sync = nil
                    } else if let parsed = VolumePolicy.SyncMode(rawValue: sync) {
                        policy.sync = parsed
                    } else {
                        return toolResult(id, "invalid sync '\(sync)' — full|fsync|nosync|default", isError: true)
                    }
                }
                if let cache = args.optionalString("cache") {
                    guard let parsed = VolumePolicy.CacheMode(rawValue: cache) else {
                        return toolResult(id, "invalid cache '\(cache)' — on|off|auto", isError: true)
                    }
                    policy.cache = parsed
                }
                try VolumePolicyStore.save(policy)
                return toolResult(
                    id,
                    "Saved: cloneMode=\(policy.cloneMode.rawValue) goldens=\(policy.goldenVolumes.joined(separator: ",")) "
                        + "jobsOnly=\(policy.jobsOnly) sync=\(policy.sync?.rawValue ?? "default") cache=\(policy.cache.rawValue)"
                )

            case "list_networks":
                let networks = try await networks.list()
                let lines = networks.map { network in
                    "\(network.id)\t\(network.mode)\(network.builtin ? " (builtin)" : "")\t\(network.ipv4Subnet)"
                }
                return toolResult(id, lines.isEmpty ? "No networks" : lines.joined(separator: "\n"))

            case "pull" where !args.string("runtime").isEmpty && args.string("runtime") != "apple":
                // Other engines' stores are routed by the API daemon.
                _ = try await api.call(
                    "POST", "/v1/images/pull",
                    ["reference": args.string("reference"), "runtime": args.string("runtime")],
                    timeout: api.longCallSeconds)
                return toolResult(id, "Pulled \(args.string("reference")) on \(args.string("runtime"))")

            case "pull":
                for try await _ in images.pull(args.string("reference"), platform: nil) {}
                return toolResult(id, "Pulled \(args.string("reference"))")

            case "push":
                for try await _ in images.push(args.string("reference"), platform: nil) {}
                return toolResult(id, "Pushed \(args.string("reference"))")

            case "inspect":
                if await api.nonAppleEngine(for: args.string("id")) != nil {
                    let reply = try await api.connect("ContainerService", "GetContainer", ["id": args.string("id")])
                    let pretty = try JSONSerialization.data(
                        withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
                    return toolResult(id, String(data: pretty, encoding: .utf8) ?? "")
                }
                let data = try await containers.inspect(args.string("id"))
                let object = try JSONSerialization.jsonObject(with: data)
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
                return toolResult(id, String(data: pretty, encoding: .utf8) ?? "")

            case "logs":
                let count = args.integer("lines").map { Int($0) } ?? 100
                if await api.nonAppleEngine(for: args.string("id")) != nil {
                    let lines = try await api.tailLogs(args.string("id"), lines: count)
                    return toolResult(id, lines.isEmpty ? "No logs" : lines.joined(separator: "\n"))
                }
                let lines = try await logStreamer.tail(id: args.string("id"), lines: count, boot: false)
                return toolResult(id, lines.isEmpty ? "No logs" : lines.map(\.text).joined(separator: "\n"))

            case "df":
                let usage = try await system.diskUsage()
                return toolResult(
                    id,
                    """
                    Containers: \(ByteFormat.string(usage.containers.sizeBytes)) [\(ByteFormat.string(usage.containers.reclaimableBytes)) reclaimable]
                    Images: \(ByteFormat.string(usage.images.sizeBytes)) [\(ByteFormat.string(usage.images.reclaimableBytes)) reclaimable]
                    Volumes: \(ByteFormat.string(usage.volumes.sizeBytes)) [\(ByteFormat.string(usage.volumes.reclaimableBytes)) reclaimable]
                    """)

            case "compose_up":
                let url = URL(fileURLWithPath: args.string("path"))
                let spec = try await compose.parse(url: url)
                let plan = try compose.plan(spec: spec, enabledProfiles: Set(args.list("profiles")))
                var lastLine = ""
                for try await line in await compose.up(plan: plan) {
                    lastLine = line
                }
                return toolResult(id, lastLine.isEmpty ? "Compose up complete" : "Compose up complete — \(lastLine)")

            case "compose_down":
                try await compose.down(composeName: args.string("name"))
                return toolResult(id, "Tore down \(args.string("name"))")

            case "compose_ps":
                let containers = try await self.containers.list()
                let lines =
                    containers
                    .filter { $0.labels["com.skunkworq.micropod.compose"] == args.string("name") }
                    .map { "\($0.id)\t\($0.state)\t\($0.image)" }
                return toolResult(
                    id,
                    lines.isEmpty ? "No containers for stack \(args.string("name"))" : lines.joined(separator: "\n"))

            case "share_mount":
                guard let sharedFS else {
                    return toolResult(id, Self.noDaemonMessage, isError: true)
                }
                let source = URL(fileURLWithPath: args.string("src"))
                let readonly = args.flag("readonly") || args.flag("ro")
                let info: MountInfo
                if args.flag("shared") {
                    info = try await sharedFS.mountShared(src: source, readonly: readonly)
                } else {
                    info = try await sharedFS.mount(src: source, readonly: readonly)
                }
                return toolResult(
                    id, "\(info.id.value)\t\(info.src) -> \(info.viewPath) (\(info.sizeBytes) bytes)")

            case "share_unmount":
                guard let sharedFS else {
                    return toolResult(id, Self.noDaemonMessage, isError: true)
                }
                try await sharedFS.unmount(id: ViewID(args.string("id")))
                return toolResult(id, "Unmounted \(args.string("id"))")

            case "share_list":
                guard let sharedFS else {
                    return toolResult(id, Self.noDaemonMessage, isError: true)
                }
                let mounts = try await sharedFS.list()
                if mounts.isEmpty { return toolResult(id, "no shared views") }
                return toolResult(
                    id,
                    mounts.map {
                        "\($0.id.value)\t\($0.src) -> \($0.viewPath)  \($0.sizeBytes)B"
                    }.joined(separator: "\n"))

            case "share_sync":
                guard let sharedFS else {
                    return toolResult(id, Self.noDaemonMessage, isError: true)
                }
                let result = try await sharedFS.sync(id: ViewID(args.string("id")))
                return toolResult(
                    id,
                    "Synced \(result.synced.count) files (\(result.bytesWritten) bytes) for \(args.string("id"))")

            case "share_gc":
                guard let sharedFS else {
                    return toolResult(id, Self.noDaemonMessage, isError: true)
                }
                let result = try await sharedFS.gc()
                return toolResult(
                    id,
                    "Removed \(result.chunksRemoved) chunks, reclaimed \(result.bytesReclaimed) bytes")

            case "build_cache_stats":
                // Read-only directory scan — needs no daemon and no shim.
                let root =
                    args.optionalString("path").map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? BuildCacheStore.standardRoot()
                let (_, stats) = BuildCacheStore.scan(root: root)
                return toolResult(
                    id,
                    """
                    entries: \(stats.entries)
                    content-bytes: \(stats.contentBytes)
                    content-bytes-complete: \(stats.contentAccountingComplete)
                    content-bytes-unknown-entries: \(stats.unknownContentEntries)
                    shared-bytes: \(stats.sharedBytes)
                    shared-bytes-complete: \(stats.contentAccountingComplete)
                    cap-bytes: \(stats.capBytes)
                    """)

            case "update_check":
                guard appControl.isReachable else {
                    return toolResult(
                        id, "Micropod app is not running (no control socket)", isError: true)
                }
                let report = try await appControl.checkForUpdates()
                return toolResult(id, describeUpdate(report))

            case "update_status":
                guard appControl.isReachable else {
                    return toolResult(
                        id, "Micropod app is not running (no control socket)", isError: true)
                }
                let report = try await appControl.updateStatus()
                return toolResult(id, describeUpdate(report))

            case "update_apply":
                guard appControl.isReachable else {
                    return toolResult(
                        id, "Micropod app is not running (no control socket)", isError: true)
                }
                let report = try await appControl.applyUpdate()
                return toolResult(
                    id, "\(describeUpdate(report)) — app is quitting to install; it will relaunch")

            case "k8s_status":
                let k8s = K8sService(client: client)
                let config = k8s.loadConfig() ?? .defaults
                let s = try await k8s.status(name: config.clusterName)
                var lines = [
                    "enabled=\(k8s.isEnabled)",
                    "exists=\(s.exists) running=\(s.running) nodeReady=\(s.nodeReady)",
                ]
                if let ip = s.address { lines.append("api=https://\(ip):6443") }
                lines.append("kubeconfig=\(s.kubeconfigPath)")
                return toolResult(id, lines.joined(separator: "\n"))

            case "k8s_enable", "k8s_disable":
                let k8s = K8sService(client: client)
                var config = k8s.loadConfig() ?? .defaults
                config.enabled = call.name == "k8s_enable"
                if config.enabled { try applyK8sArgs(config: &config) }
                try k8s.saveConfig(config)
                return toolResult(
                    id, config.enabled ? "k8s engine enabled — k8s_up creates the cluster" : "k8s engine disabled")

            case "k8s_up":
                let k8s = K8sService(client: client)
                guard k8s.isEnabled else {
                    return toolResult(id, "k8s engine disabled — call k8s_enable first", isError: true)
                }
                var config = k8s.loadConfig() ?? .defaults
                try applyK8sArgs(config: &config)
                final class Lines: @unchecked Sendable {
                    var items: [String] = []
                }
                let progress = Lines()
                let s = try await k8s.up(config) { progress.items.append($0) }
                var out = progress.items.joined(separator: "\n")
                if let ip = s.address { out += "\napi=https://\(ip):6443" }
                out += "\nkubeconfig=\(s.kubeconfigPath)"
                return toolResult(id, out)

            case "k8s_down":
                let k8s = K8sService(client: client)
                guard k8s.isEnabled else {
                    return toolResult(id, "k8s engine disabled", isError: true)
                }
                let config = k8s.loadConfig() ?? .defaults
                try await k8s.down(config)
                return toolResult(id, "removed \(config.clusterName)")

            case "k8s_kubeconfig":
                let k8s = K8sService(client: client)
                guard let contents = try? String(contentsOf: k8s.kubeconfigURL, encoding: .utf8) else {
                    return toolResult(id, "no kubeconfig — run k8s_up first", isError: true)
                }
                return toolResult(id, contents)

            case "k8s_load_image":
                let k8s = K8sService(client: client)
                guard k8s.isEnabled else {
                    return toolResult(id, "k8s engine disabled — call k8s_enable first", isError: true)
                }
                let ref = args.optionalString("ref")
                let path = args.optionalString("path")
                guard ref != nil || path != nil else {
                    return toolResult(id, "k8s_load_image needs `ref` or `path`", isError: true)
                }
                final class LoadLines: @unchecked Sendable {
                    var items: [String] = []
                }
                let progress = LoadLines()
                let loaded = try await k8s.loadImage(
                    ref: ref,
                    archivePath: path.map { URL(fileURLWithPath: $0) }
                ) { progress.items.append($0) }
                progress.items.append("loaded \(loaded.ref) (\(loaded.bytes) bytes)")
                return toolResult(id, progress.items.joined(separator: "\n"))

            case "k8s_images":
                let k8s = K8sService(client: client)
                guard k8s.isEnabled else {
                    return toolResult(id, "k8s engine disabled", isError: true)
                }
                let refs = try await k8s.listImages()
                return toolResult(id, refs.isEmpty ? "(no images)" : refs.joined(separator: "\n"))

            case _ where CacheTools.names.contains(call.name):
                return toolResult(id, try await CacheTools.call(call.name, args, api: api))

            case "sandbox_status":
                let (code, output) = try await Self.runMicropod(["sandbox", "status", "--json"])
                return toolResult(id, output.isEmpty ? "No output" : output, isError: code != 0)

            default:
                return respondError(id: id, code: -32601, message: "Unknown tool: \(call.name)")
            }
        } catch {
            return toolResult(id, error.localizedDescription, isError: true)
        }
    }
}

/// Thread-safe tail buffer for a child process's output.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap = 64 * 1024

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > cap { data.removeFirst(data.count - cap) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
