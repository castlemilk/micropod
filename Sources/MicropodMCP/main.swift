import Foundation
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
        if let version = report["availableVersion"] as? String {
            line += " (\(version) available"
            if report["downloaded"] as? Bool == true { line += ", downloaded" }
            if report["readyToInstall"] as? Bool == true { line += ", ready to install" }
            line += ")"
        }
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
        ("run", "Run a container. Arguments: image (required), name (optional), memory (optional)."),
        ("exec", "Run a command in a running container. Arguments: id (required), command (required)."),
        ("logs", "Last 100 log lines of a container. Arguments: id."),
        ("stats", "Resource usage for all running containers (memory/CPU/net)."),
        ("inspect", "Pretty-printed container inspect JSON. Arguments: id."),
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
    ]

    private func callTool(id: Int?, _ call: MCPToolCall) async -> Data? {
        let args = call.arguments ?? [:]
        func string(_ key: String) -> String {
            if case .string(let value) = args[key] { return value }
            return ""
        }
        func flag(_ key: String) -> Bool {
            ["true", "1", "yes"].contains(string(key).lowercased())
        }

        do {
            switch call.name {
            case "status":
                let status = try await system.status()
                return toolResult(
                    id, "\(status.status) | cli \(status.cliVersion) | apiserver \(status.apiServerVersion)")

            case "list_containers":
                let containers = try await self.containers.list()
                let lines = containers.map { c -> String in
                    "\(c.id)\t\(c.state)\t\(c.image)\(c.ipv4Address.isEmpty ? "" : "\t\(c.ipv4Address)")"
                }.joined(separator: "\n")
                return toolResult(id, lines.isEmpty ? "No containers" : lines)

            case "start":
                try await containers.start(string("id"))
                return toolResult(id, "Started \(string("id"))")

            case "stop":
                try await containers.stop(string("id"))
                return toolResult(id, "Stopped \(string("id"))")

            case "restart":
                try await containers.restart(string("id"))
                return toolResult(id, "Restarted \(string("id"))")

            case "kill":
                try await containers.kill(string("id"))
                return toolResult(id, "Killed \(string("id"))")

            case "delete":
                try await containers.delete(string("id"), force: true)
                return toolResult(id, "Deleted \(string("id"))")

            case "run":
                var request = ContainerRunRequest(
                    image: string("image"),
                    name: string("name").isEmpty ? nil : string("name"),
                    detach: true)
                let memory = string("memory")
                if !memory.isEmpty { request.memory = memory }
                let containerID = try await containers.run(request)
                return toolResult(id, "Started \(containerID)")

            case "exec":
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
                let data = try await containers.inspect(string("id"))
                let object = try JSONSerialization.jsonObject(with: data)
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
                return toolResult(id, String(data: pretty, encoding: .utf8) ?? "")

            case "logs":
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

            default:
                return respondError(id: id, code: -32601, message: "Unknown tool: \(call.name)")
            }
        } catch {
            return toolResult(id, error.localizedDescription, isError: true)
        }
    }
}
