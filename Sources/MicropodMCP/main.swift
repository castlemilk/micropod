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

@main
struct MicropodMCP {
    static func main() async {
        // Env override so the server can be validated against a mock CLI.
        let cliPath =
            ProcessInfo.processInfo.environment["MICROPOD_CONTAINER_CLI_PATH"]
            ?? "/usr/local/bin/container"
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: cliPath))
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

private actor MCPServer {
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
        sharedFS: (any SharedFSClient)?
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
                line += ", ready to install (update_apply restarts into it)"
            }
        }
        if let checked = report["checkedAt"] as? String { line += " | checked \(checked)" }
        if let error = report["error"] as? String {
            line += " — \(error)"
        }
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

    private func handle(line: String) async -> Data? {
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
            let toolArray: [JSONValue] = Self.toolDefinitions.map { name, description in
                .object([
                    "name": .string(name),
                    "description": .string(description),
                    "inputSchema": .object(["type": .string("object")]),
                ])
            }
            return respond(id: id, result: .object(["tools": .array(toolArray)]))

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

    private static let toolDefinitions: [(String, String)] = [
        ("status", "Runtime status: running/stopped + CLI + apiserver versions."),
        ("list_containers", "List all containers (id, state, image, IP) as tab-separated lines."),
        ("start", "Start a container. Arguments: id."),
        ("stop", "Stop a container. Arguments: id."),
        ("restart", "Restart a container (stop then start). Arguments: id."),
        ("kill", "Kill a container. Arguments: id."),
        ("delete", "Force-delete a container. Arguments: id."),
        (
            "run",
            "Run a container. Arguments: image (required), name (optional), memory (optional), "
                + "command (optional, run by /bin/sh -c instead of the image's default command — e.g. "
                + "`sleep infinity` keeps a sandbox up for exec), "
                + "runtime (optional: apple | docker | sandbox; default is the configured engine)."
        ),
        (
            "runtimes",
            "Execution engines micropod can drive (apple VMs, docker, sandbox micro-VMs): availability, "
                + "enabled, default, capabilities. Needs the Micropod API daemon."
        ),
        ("runtime_set_default", "Set the default engine for new containers. Arguments: name (apple|docker|sandbox)."),
        (
            "runtime_update",
            "Enable/disable an engine or change its endpoint. Arguments: name (required), "
                + "enabled (optional bool), endpoint (optional, docker only: unix:///path or tcp://host:port)."
        ),
        ("exec", "Run a command in a running container. Arguments: id (required), command (required)."),
        ("logs", "Last 100 log lines of a container. Arguments: id."),
        ("stats", "Resource usage for all running containers (memory/CPU/net)."),
        ("inspect", "Pretty-printed container inspect JSON. Arguments: id."),
        (
            "list_machines",
            "List container machines — persistent VMs (e.g. keep-alive CI): id, state, IP, CPUs, memory."
        ),
        (
            "metrics_history",
            """
            Resource usage over time, as recorded by the Micropod app (10 s points for 3 h, 1 min for 48 h, \
            15 min for 30 days): per metric the peak, average and latest value plus a sparkline. \
            Arguments: id (container id or machine name; empty for all containers), kind (system|container|machine; \
            default container when id is set), range (e.g. 15m, 1h, 24h, 7d; default 1h).
            """
        ),
        (
            "machine_stats",
            """
            Resource usage for running machines (CPU % of one core, memory, net, block I/O, pids) from \
            each machine's backing container — never execs in the guest. Arguments: id (optional; default all running).
            """
        ),
        (
            "machine_logs",
            "Tail a machine's stdio log. Arguments: id (required), lines (optional, default 100), boot (true for the vminitd/kernel boot log)."
        ),
        (
            "sandbox_run",
            """
            Run a command in a fresh, disposable micro-VM (rootfs discarded on exit) and return its output \
            and exit code. Offline unless allow_net. Arguments: command (required, run by /bin/sh -c), \
            image (default alpine) or from (a checkpoint), cpus, memory (MiB), timeout (seconds), \
            mounts (comma list host:/guest — guest writes are discarded; host:/guest:rw needs \
            allow_host_writes), allow_net, allow_hosts (comma list; restricts egress), secrets (comma list \
            NAME=HOST_ENV@host — the guest sees a placeholder, the host proxy injects the real value on \
            HTTPS to host), env (comma list KEY=VAL), workdir, expose_host (comma list of host loopback ports the \
            guest reaches as host.micropod.internal:PORT), ports (comma list host:guest to publish).
            """
        ),
        ("sandbox_checkpoints", "List sandbox checkpoints (saved disks to boot from)."),
        (
            "sandbox_checkpoint_create",
            """
            Run a setup command in a sandbox and keep its disk as a named checkpoint (only if it exits 0). \
            Arguments: name (required), command (required), image or from, allow_net, timeout.
            """
        ),
        ("sandbox_checkpoint_delete", "Delete a sandbox checkpoint. Arguments: name."),
        ("list_images", "List local images (name, id, size, variants)."),
        ("list_volumes", "List volumes (name, size, driver)."),
        (
            "volume_policy",
            "Show the shared volume-mount policy (clone mode, golden volumes, sync/cache modes)."
        ),
        (
            "volume_policy_set",
            """
            Update the volume-mount policy. Arguments: mode (labels|goldens|all), \
            goldens (comma list), jobsOnly (true|false), sync (full|fsync|nosync|default), \
            cache (on|off|auto). Only provided fields change.
            """
        ),
        ("list_networks", "List networks (name, mode, subnet)."),
        ("pull", "Pull an image. Arguments: reference."),
        ("push", "Push an image. Arguments: reference."),
        ("df", "Disk usage: containers/images/volumes sizes + reclaimable bytes."),
        ("compose_up", "Parse + run a docker-compose.yml. Arguments: path, profiles (optional comma list)."),
        ("compose_down", "Tear down a compose stack by its compose name. Arguments: name."),
        ("compose_ps", "List containers belonging to a compose stack. Arguments: name."),
        (
            "share_mount",
            "Expose a host directory as a synchronized file share. Arguments: src (required), readonly (optional), shared (optional live view)."
        ),
        ("share_unmount", "Remove a shared view. Arguments: id."),
        ("share_list", "List active synchronized file shares."),
        ("share_sync", "Flush a shared view's writes back to its source. Arguments: id."),
        ("share_gc", "Remove unreferenced chunks from the shared cache."),
        (
            "build_cache_stats",
            "Content-addressed build contexts: entries, bytes, shared bytes, cap. Arguments: path (optional cache root)."
        ),
        ("update_check", "Trigger a background app update check (Sparkle) via the Micropod app."),
        ("update_status", "Last-known app update state (checking/upToDate/updateAvailable/installing)."),
        (
            "update_apply",
            "Install a downloaded app update: quits Micropod, Sparkle applies it, app relaunches."
        ),
        (
            "k8s_status",
            "Kubernetes engine state: enabled, cluster VM state, node Ready, kubeconfig path."
        ),
        (
            "k8s_enable",
            """
            Enable the lightweight Kubernetes engine (opt-in). Optional args: image, memory, cpus, \
            metallb (true|false), ingress (true|false), lb_pool (a.b.c.d-e.f.g.h), name.
            """
        ),
        ("k8s_disable", "Disable the Kubernetes engine (a running cluster is left up)."),
        (
            "k8s_up",
            """
            Create or resume the k3s cluster VM and wait for Ready. Streams progress; \
            writes ~/.micropod/k8s/kubeconfig. Accepts the same optional args as k8s_enable.
            """
        ),
        ("k8s_down", "Remove the cluster VM and its state."),
        ("k8s_kubeconfig", "Return the host kubeconfig contents for the cluster."),
        (
            "k8s_load_image",
            """
            Push an image into the cluster's containerd via the host puller — bypasses the \
            guest's slow NAT registry path. Args: `ref` (registry ref; uses the local image \
            store first, pulls on miss) or `path` (local image-save tarball, no registry at all).
            """
        ),
        ("k8s_images", "List image refs present in the cluster's containerd (k8s.io namespace)."),
    ]

    /// Sandboxes boot in-process in whoever launches them, which needs the
    /// virtualization entitlement the `micropod` CLI carries and this
    /// server doesn't — so sandbox tools run the CLI. Output is combined
    /// stdout+stderr, capped at the last 64 KiB.
    private static func runMicropod(_ arguments: [String]) async throws -> (Int32, String) {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["MICROPOD_CLI"], "\(NSHomeDirectory())/.local/bin/micropod", "/usr/local/bin/micropod"]
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
        let args = call.arguments ?? [:]
        func string(_ key: String) -> String {
            if case .string(let value) = args[key] { return value }
            return ""
        }
        func flag(_ key: String) -> Bool {
            ["true", "1", "yes"].contains(string(key).lowercased())
        }
        func applyK8sArgs(config: inout K8sConfig) throws {
            if !string("image").isEmpty { config.image = string("image") }
            if !string("memory").isEmpty { config.memory = string("memory") }
            if let c = Double(string("cpus")), c > 0 { config.cpus = c }
            if !string("metallb").isEmpty { config.metalLB = flag("metallb") }
            if !string("ingress").isEmpty { config.ingress = flag("ingress") }
            if !string("lb_pool").isEmpty { config.lbPool = string("lb_pool") }
            if !string("name").isEmpty { config.clusterName = string("name") }
        }

        do {
            switch call.name {
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
                    let remote = await LocalAPI.nonAppleContainers()
                    guard !remote.isEmpty else { throw error }
                    local = []
                }
                var lines = local.map { c -> String in
                    "\(c.id)\t\(c.state)\t\(c.image)\(c.ipv4Address.isEmpty ? "" : "\t\(c.ipv4Address)")"
                }
                lines += await LocalAPI.nonAppleContainers().map { c in
                    "\(c["id"] as? String ?? "?")\t\(c["state"] as? String ?? "?")\t\(c["image"] as? String ?? "")\t[\(c["runtime"] as? String ?? "")]"
                }
                return toolResult(id, lines.isEmpty ? "No containers" : lines.joined(separator: "\n"))

            case "start", "stop", "restart", "kill", "delete":
                let target = string("id")
                let verb = [
                    "start": "Started", "stop": "Stopped", "restart": "Restarted", "kill": "Killed",
                    "delete": "Deleted",
                ][call.name]!
                if let engine = await LocalAPI.nonAppleEngine(for: target) {
                    let method = call.name.prefix(1).uppercased() + call.name.dropFirst() + "Container"
                    var body: [String: Any] = ["id": target]
                    if call.name == "delete" { body["force"] = true }
                    _ = try await LocalAPI.connect("ContainerService", method, body)
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

            case "run" where !string("runtime").isEmpty && string("runtime") != "apple":
                // Non-apple engines are owned by the API daemon (sandbox VMs
                // live in its process), so route the run through it.
                var body: [String: Any] = ["image": string("image"), "runtime": string("runtime")]
                if !string("name").isEmpty { body["name"] = string("name") }
                if !string("memory").isEmpty { body["memory"] = string("memory") }
                if !string("command").isEmpty { body["arguments"] = ["/bin/sh", "-c", string("command")] }
                let reply = try await LocalAPI.call("POST", "/v1/containers", body)
                return toolResult(id, "Started \(reply["id"] as? String ?? "?") on \(string("runtime"))")

            case "runtimes":
                return toolResult(id, LocalAPI.describe(try await LocalAPI.call("GET", "/v1/runtimes")))

            case "runtime_set_default":
                let reply = try await LocalAPI.call("PUT", "/v1/runtimes/default", ["name": string("name")])
                return toolResult(id, "Default runtime → \(reply["default"] as? String ?? "?")")

            case "runtime_update":
                var body: [String: Any] = [:]
                switch args["enabled"] {
                case .bool(let enabled)?: body["enabled"] = enabled
                case .string?: body["enabled"] = flag("enabled")
                default: break
                }
                if case .string(let endpoint)? = args["endpoint"] { body["endpoint"] = endpoint }
                let reply = try await LocalAPI.call("PATCH", "/v1/runtimes/\(string("name"))", body)
                return toolResult(id, LocalAPI.describe(reply))

            case "run":
                var request = ContainerRunRequest(
                    image: string("image"),
                    name: string("name").isEmpty ? nil : string("name"),
                    detach: true)
                let memory = string("memory")
                if !memory.isEmpty { request.memory = memory }
                if !string("command").isEmpty { request.arguments = ["/bin/sh", "-c", string("command")] }
                let containerID = try await containers.run(request)
                return toolResult(id, "Started \(containerID)")

            case "exec":
                if await LocalAPI.nonAppleEngine(for: string("id")) != nil {
                    let reply = try await LocalAPI.connect(
                        "ContainerService", "Exec",
                        ["id": string("id"), "arguments": ["/bin/sh", "-c", string("command")]])
                    let output = (reply["output"] as? String ?? "") + (reply["error"] as? String ?? "")
                    let code = (reply["exitCode"] as? Int) ?? Int(reply["exitCode"] as? String ?? "0") ?? 0
                    return toolResult(
                        id, (output.isEmpty ? "No output" : output) + (code == 0 ? "" : "\n(exit \(code))"),
                        isError: code != 0)
                }
                let output = try await containers.exec(
                    ContainerExecRequest(containerID: string("id"), arguments: [string("command")]))
                return toolResult(id, output.isEmpty ? "No output" : output)

            case "stats":
                let snapshot = try await statsSampler.snapshot()
                guard !snapshot.containers.isEmpty else { return toolResult(id, "No running containers") }
                let lines = snapshot.containers.map { stats -> String in
                    "\(stats.id)\tmem \(ByteFormat.string(stats.memoryUsedBytes))/\(ByteFormat.string(stats.memoryLimitBytes))\tnet ↓\(ByteFormat.string(stats.networkRxBytes)) ↑\(ByteFormat.string(stats.networkTxBytes))\t\(stats.pids) pids"
                }
                return toolResult(id, lines.joined(separator: "\n"))

            case "sandbox_run", "sandbox_checkpoint_create":
                guard !string("command").isEmpty else {
                    return toolResult(id, "\(call.name) requires command", isError: true)
                }
                var argv = ["sandbox"]
                if call.name == "sandbox_checkpoint_create" {
                    guard !string("name").isEmpty else {
                        return toolResult(id, "sandbox_checkpoint_create requires name", isError: true)
                    }
                    argv += ["checkpoint", "create", string("name")]
                } else {
                    argv.append("run")
                }
                if !string("cpus").isEmpty { argv += ["--cpus", string("cpus")] }
                if !string("memory").isEmpty { argv += ["--memory", string("memory")] }
                if !string("timeout").isEmpty { argv += ["--timeout", string("timeout")] }
                if !string("workdir").isEmpty { argv += ["--workdir", string("workdir")] }
                if flag("allow_net") { argv.append("--allow-net") }
                if flag("allow_host_writes") { argv.append("--allow-host-writes") }
                func list(_ key: String) -> [String] {
                    string(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
                for mount in list("mounts") { argv += ["--mount", mount] }
                for host in list("allow_hosts") { argv += ["--allow-host", host] }
                for port in list("expose_host") { argv += ["--expose-host", port] }
                for port in list("ports") { argv += ["--publish", port] }
                for secret in list("secrets") { argv += ["--secret", secret] }
                for env in list("env") { argv += ["--env", env] }
                if !string("from").isEmpty {
                    argv += ["--from", string("from")]
                } else if !string("image").isEmpty {
                    argv.append(string("image"))
                }
                argv += ["--", "/bin/sh", "-c", string("command")]
                let (code, output) = try await Self.runMicropod(argv)
                return toolResult(id, "exit \(code)\n\(output)", isError: code != 0)

            case "sandbox_checkpoints", "sandbox_checkpoint_delete":
                var argv = ["sandbox", "checkpoint"]
                if call.name == "sandbox_checkpoint_delete" {
                    guard !string("name").isEmpty else {
                        return toolResult(id, "sandbox_checkpoint_delete requires name", isError: true)
                    }
                    argv += ["rm", string("name")]
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
                let target = string("id")
                guard
                    let kind = MetricsStore.Kind(
                        rawValue: string("kind").isEmpty ? (target.isEmpty ? "system" : "container") : string("kind"))
                else {
                    return toolResult(id, "kind must be system, container or machine", isError: true)
                }
                guard let range = MetricsStore.parseRange(string("range").isEmpty ? "1h" : string("range")) else {
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
                let snapshot = try await machineStats.snapshot(id: string("id").isEmpty ? nil : string("id"))
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
                guard !string("id").isEmpty else {
                    return toolResult(id, "machine_logs requires id", isError: true)
                }
                let count = Int(string("lines")).flatMap { $0 > 0 ? $0 : nil } ?? 100
                let lines = try await machines.logs(string("id"), tail: count, boot: flag("boot"))
                return toolResult(id, lines.isEmpty ? "No logs" : lines.map(\.text).joined(separator: "\n"))

            case "list_images":
                let images = try await images.list()
                let lines = images.map { image -> String in
                    "\(image.names.first ?? image.id)\t\(ByteFormat.string(image.sizeBytes))\t\(image.id.prefix(19))"
                }
                return toolResult(id, lines.isEmpty ? "No images" : lines.joined(separator: "\n"))

            case "list_volumes":
                let volumes = try await volumes.list()
                let lines = volumes.map { volume in
                    "\(volume.id)\t\(ByteFormat.string(volume.sizeBytes))\t\(volume.driver)"
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
                let mode = string("mode")
                if !mode.isEmpty {
                    guard let parsed = VolumePolicy.CloneMode(rawValue: mode) else {
                        return toolResult(id, "invalid mode '\(mode)' — labels|goldens|all", isError: true)
                    }
                    policy.cloneMode = parsed
                }
                let goldens = string("goldens")
                if !goldens.isEmpty {
                    policy.goldenVolumes = goldens.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                }
                if args["jobsOnly"] != nil {
                    policy.jobsOnly = flag("jobsOnly")
                }
                let sync = string("sync")
                if !sync.isEmpty {
                    if sync == "default" {
                        policy.sync = nil
                    } else if let parsed = VolumePolicy.SyncMode(rawValue: sync) {
                        policy.sync = parsed
                    } else {
                        return toolResult(id, "invalid sync '\(sync)' — full|fsync|nosync|default", isError: true)
                    }
                }
                let cache = string("cache")
                if !cache.isEmpty {
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

            case "pull":
                var lastLine = ""
                for try await event in images.pull(string("reference"), platform: nil) {
                    lastLine = event.line
                }
                return toolResult(
                    id, lastLine.isEmpty ? "Pulled \(string("reference"))" : "Pulled \(string("reference"))")

            case "push":
                var lastLine = ""
                for try await event in images.push(string("reference"), platform: nil) {
                    lastLine = event.line
                }
                return toolResult(
                    id, lastLine.isEmpty ? "Pushed \(string("reference"))" : "Pushed \(string("reference"))")

            case "inspect":
                if await LocalAPI.nonAppleEngine(for: string("id")) != nil {
                    let reply = try await LocalAPI.connect("ContainerService", "GetContainer", ["id": string("id")])
                    let pretty = try JSONSerialization.data(
                        withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
                    return toolResult(id, String(data: pretty, encoding: .utf8) ?? "")
                }
                let data = try await containers.inspect(string("id"))
                let object = try JSONSerialization.jsonObject(with: data)
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
                return toolResult(id, String(data: pretty, encoding: .utf8) ?? "")

            case "logs":
                if await LocalAPI.nonAppleEngine(for: string("id")) != nil {
                    let lines = try await LocalAPI.tailLogs(string("id"), lines: 100)
                    return toolResult(id, lines.isEmpty ? "No logs" : lines.joined(separator: "\n"))
                }
                let lines = try await logStreamer.tail(id: string("id"), lines: 100, boot: false)
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
                let url = URL(fileURLWithPath: string("path"))
                let spec = try await compose.parse(url: url)
                let profiles = Set(
                    string("profiles").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty })
                let plan = try compose.plan(spec: spec, enabledProfiles: profiles)
                var lastLine = ""
                for try await line in await compose.up(plan: plan) {
                    lastLine = line
                }
                return toolResult(id, lastLine.isEmpty ? "Compose up complete" : "Compose up complete — \(lastLine)")

            case "compose_down":
                try await compose.down(composeName: string("name"))
                return toolResult(id, "Tore down \(string("name"))")

            case "compose_ps":
                let containers = try await self.containers.list()
                let lines =
                    containers
                    .filter { $0.labels["com.skunkworq.micropod.compose"] == string("name") }
                    .map { "\($0.id)\t\($0.state)\t\($0.image)" }
                return toolResult(
                    id, lines.isEmpty ? "No containers for stack \(string("name"))" : lines.joined(separator: "\n"))

            case "share_mount":
                guard let sharedFS else {
                    return toolResult(id, Self.noDaemonMessage, isError: true)
                }
                guard !string("src").isEmpty else {
                    return toolResult(id, "share_mount requires src", isError: true)
                }
                let readonly = flag("readonly") || flag("ro")
                let info: MountInfo
                if flag("shared") {
                    info = try await sharedFS.mountShared(
                        src: URL(fileURLWithPath: string("src")), readonly: readonly)
                } else {
                    info = try await sharedFS.mount(
                        src: URL(fileURLWithPath: string("src")), readonly: readonly)
                }
                return toolResult(
                    id, "\(info.id.value)\t\(info.src) -> \(info.viewPath) (\(info.sizeBytes) bytes)")

            case "share_unmount":
                guard let sharedFS else {
                    return toolResult(id, Self.noDaemonMessage, isError: true)
                }
                try await sharedFS.unmount(id: ViewID(string("id")))
                return toolResult(id, "Unmounted \(string("id"))")

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
                let result = try await sharedFS.sync(id: ViewID(string("id")))
                return toolResult(
                    id,
                    "Synced \(result.synced.count) files (\(result.bytesWritten) bytes) for \(string("id"))")

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
                    string("path").isEmpty
                    ? BuildCacheStore.standardRoot()
                    : URL(fileURLWithPath: string("path"), isDirectory: true)
                let (_, stats) = BuildCacheStore.scan(root: root)
                return toolResult(
                    id,
                    """
                    entries: \(stats.entries)
                    content-bytes: \(stats.contentBytes)
                    shared-bytes: \(stats.sharedBytes)
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
                try applyK8sArgs(config: &config)
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
                let ref = string("ref")
                let path = string("path")
                guard !ref.isEmpty || !path.isEmpty else {
                    return toolResult(id, "k8s_load_image needs `ref` or `path`", isError: true)
                }
                final class LoadLines: @unchecked Sendable {
                    var items: [String] = []
                }
                let progress = LoadLines()
                let archivePath = path.isEmpty ? nil : URL(fileURLWithPath: path)
                let loaded = try await k8s.loadImage(
                    ref: ref.isEmpty ? nil : ref,
                    archivePath: archivePath
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

            default:
                return respondError(id: id, code: -32601, message: "Unknown tool: \(call.name)")
            }
        } catch {
            return toolResult(id, error.localizedDescription, isError: true)
        }
    }
}

/// The local Micropod API daemon — owner of engine config and sandbox VMs.
enum LocalAPI {
    static var baseURL: URL {
        let port = ProcessInfo.processInfo.environment["MICROPOD_API_PORT"] ?? "45454"
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    static func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MicropodError.message("Micropod API daemon not reachable at \(baseURL) — start the Micropod app")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MicropodError.message(json["error"] as? String ?? json["message"] as? String ?? "API error")
        }
        return json
    }

    /// A Connect unary call on the daemon (`/api/micropod.v1.<service>/<method>`).
    static func connect(_ service: String, _ method: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await call("POST", "/api/micropod.v1.\(service)/\(method)", body)
    }

    /// The engine owning `id` when it isn't Apple's — sandbox micro-VMs and
    /// Docker containers live in the API daemon (sandbox VMs in its very
    /// process), so tools must reach them through it. nil for Apple
    /// containers, unknown ids, or no daemon: the caller's usual path.
    static func nonAppleEngine(for id: String) async -> String? {
        guard !id.isEmpty, let reply = try? await connect("ContainerService", "GetContainer", ["id": id]),
            let runtime = reply["runtime"] as? String, !runtime.isEmpty, runtime != "apple"
        else { return nil }
        return runtime
    }

    /// The daemon's containers on engines other than Apple's.
    static func nonAppleContainers() async -> [[String: Any]] {
        guard let reply = try? await connect("ContainerService", "ListContainers", [:]) else { return [] }
        return (reply["containers"] as? [[String: Any]] ?? []).filter {
            let runtime = $0["runtime"] as? String ?? "apple"
            return !runtime.isEmpty && runtime != "apple"
        }
    }

    /// The last `lines` log lines. The daemon's log route follows the
    /// container, so read until `lines` arrive or it goes quiet.
    static func tailLogs(_ id: String, lines: Int) async throws -> [String] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/containers/\(id)/logs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "tail", value: String(lines))]
        let (bytes, response) = try await URLSession.shared.bytes(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MicropodError.message("logs for \(id) unavailable from the API daemon")
        }
        let collected = LineBox()
        let reader = Task {
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                collected.append(String(line.dropFirst(6)).replacingOccurrences(of: "\\n", with: "\n"))
                if collected.count >= lines { break }
            }
        }
        // The tail arrives at once; after that the stream only waits.
        var quietSince = ContinuousClock.now
        var seen = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while !reader.isCancelled, ContinuousClock.now < deadline, collected.count < lines {
            try? await Task.sleep(for: .milliseconds(100))
            if collected.count != seen {
                seen = collected.count
                quietSince = .now
            } else if ContinuousClock.now - quietSince > .milliseconds(700) {
                break
            }
        }
        reader.cancel()
        return collected.lines
    }

    /// `/v1/runtimes` → one line per engine.
    static func describe(_ json: [String: Any]) -> String {
        let runtimes = json["runtimes"] as? [[String: Any]] ?? []
        return runtimes.map { r in
            let name = r["name"] as? String ?? "?"
            let marker = (r["default"] as? Bool ?? false) ? "*" : " "
            let available =
                (r["available"] as? Bool ?? false) ? "available" : "unavailable: \(r["reason"] as? String ?? "")"
            let enabled = (r["enabled"] as? Bool ?? false) ? "enabled" : "disabled"
            return
                "\(marker) \(name)\t\(r["kind"] as? String ?? "")\t\(available)\t\(enabled)\t\(r["endpoint"] as? String ?? "")"
        }.joined(separator: "\n")
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

/// Lines collected by a background reader.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var count: Int { lock.withLock { storage.count } }
    var lines: [String] { lock.withLock { storage } }
}
