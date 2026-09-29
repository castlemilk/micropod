import Foundation
import MicropodCore

/// A Docker Engine (Docker Desktop, OrbStack, colima, a remote dockerd) as a
/// micropod runtime. Container ids are Docker container names.
public struct DockerEngine: RuntimeEngine, ContainerServing, LogStreaming, StatsSampling {
    public let client: DockerClient?
    /// Why `client` is nil (unparseable endpoint).
    let configError: String?
    let endpointString: String

    public var name: String { "docker" }
    public var kind: String { "container" }
    public var summary: String { "Docker Engine — shared-kernel containers in one VM" }
    public var capabilities: [String] {
        ["run", "create", "start", "stop", "restart", "kill", "delete", "exec", "logs", "stats", "ports", "volumes"]
    }
    public var containers: any ContainerServing { self }
    public var logs: any LogStreaming { self }
    public var stats: (any StatsSampling)? { self }

    public init(endpoint: String?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let raw = endpoint ?? DockerClient.defaultEndpoint(environment: environment)
        endpointString = raw
        do {
            client = DockerClient(endpoint: try DockerClient.Endpoint.parse(raw))
            configError = nil
        } catch {
            client = nil
            configError = error.localizedDescription
        }
    }

    func api() throws -> DockerClient {
        guard let client else {
            throw MicropodError.message("failedPrecondition: docker endpoint: \(configError ?? endpointString)")
        }
        return client
    }

    public func probe() async -> EngineProbe {
        guard let client else {
            return EngineProbe(available: false, reason: configError ?? "bad endpoint", endpoint: endpointString)
        }
        let endpoint = client.endpoint.description
        guard client.reachable else {
            return EngineProbe(available: false, reason: "Docker socket not found", endpoint: endpoint)
        }
        do {
            let response = try await client.request("GET", "/version", timeout: .seconds(3))
            let version = ((try? response.json()) as? [String: Any])?["Version"] as? String ?? ""
            return EngineProbe(available: response.status == 200, version: version, endpoint: endpoint)
        } catch {
            return EngineProbe(available: false, reason: error.localizedDescription, endpoint: endpoint)
        }
    }

    public func owns(_ id: String) async -> Bool {
        guard let client, client.reachable,
            let response = try? await client.request("GET", "/containers/\(Self.escape(id))/json", timeout: .seconds(3))
        else { return false }
        return response.status == 200
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id
    }

    // MARK: ContainerServing

    public func list() async throws -> [Micropod_V1_Container] {
        let response = try api().check(
            try await api().request("GET", "/containers/json", query: ["all": "1"]))
        let entries = try response.json() as? [[String: Any]] ?? []
        return entries.map(Self.container(from:))
    }

    static func container(from entry: [String: Any]) -> Micropod_V1_Container {
        Micropod_V1_Container.with { c in
            let names = entry["Names"] as? [String] ?? []
            c.id = names.first.map { String($0.drop { $0 == "/" }) } ?? (entry["Id"] as? String ?? "")
            c.image = entry["Image"] as? String ?? ""
            c.state = entry["State"] as? String ?? ""
            if let created = entry["Created"] as? Double {
                c.createdAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: created))
            }
            c.labels = entry["Labels"] as? [String: String] ?? [:]
            c.publishedPorts = (entry["Ports"] as? [[String: Any]] ?? []).compactMap { port in
                guard let publicPort = port["PublicPort"] as? Int else { return nil }
                return Micropod_V1_PortMapping.with {
                    $0.hostPort = UInt32(publicPort)
                    $0.containerPort = UInt32(port["PrivatePort"] as? Int ?? 0)
                    $0.protocol = port["Type"] as? String ?? "tcp"
                    $0.hostIp = port["IP"] as? String ?? ""
                }
            }
            c.mounts = (entry["Mounts"] as? [[String: Any]] ?? []).map { mount in
                Micropod_V1_Mount.with {
                    $0.type = mount["Type"] as? String ?? ""
                    $0.source = (mount["Name"] as? String) ?? (mount["Source"] as? String ?? "")
                    $0.destination = mount["Destination"] as? String ?? ""
                    $0.readOnly = !(mount["RW"] as? Bool ?? true)
                }
            }
            c.runtime = "docker"
        }
    }

    public func inspect(_ id: String) async throws -> Data {
        try api().check(try await api().request("GET", "/containers/\(Self.escape(id))/json")).body
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        let docker = try api()
        var query: [String: String] = [:]
        if let name = request.name { query["name"] = name }
        if let platform = request.platform { query["platform"] = platform }
        let body = try Self.createBody(request)
        var response = try await docker.request("POST", "/containers/create", query: query, json: body)
        if response.status == 404, !request.noPull {
            try await pull(request.image, platform: request.platform)
            response = try await docker.request("POST", "/containers/create", query: query, json: body)
        }
        try docker.check(response)
        let id = (try response.json() as? [String: Any])?["Id"] as? String ?? ""
        return request.name ?? String(id.prefix(12))
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        let id = try await create(request)
        try await start(id)
        return id
    }

    func pull(_ image: String, platform: String?) async throws {
        var query = ["fromImage": image]
        if let platform { query["platform"] = platform }
        // The pull runs as long as the body streams; drain it.
        for try await _ in try api().stream("POST", "/images/create", query: query) {}
    }

    static func createBody(_ request: ContainerRunRequest) throws -> [String: Any] {
        var body: [String: Any] = ["Image": request.image]
        if !request.arguments.isEmpty { body["Cmd"] = request.arguments }
        if let entrypoint = request.entrypoint { body["Entrypoint"] = [entrypoint] }
        if !request.env.isEmpty { body["Env"] = request.env }
        if let workdir = request.workdir { body["WorkingDir"] = workdir }
        if let user = request.user { body["User"] = user }
        if !request.labels.isEmpty {
            body["Labels"] = Dictionary(request.labels.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        }
        var host: [String: Any] = [:]
        if let cpus = request.cpus { host["NanoCpus"] = Int(cpus * 1_000_000_000) }
        if let memory = request.memory { host["Memory"] = try parseBytes(memory) }
        if !request.volumes.isEmpty { host["Binds"] = request.volumes }
        if request.useInit { host["Init"] = true }
        if request.privileged { host["Privileged"] = true }
        if !request.capAdd.isEmpty { host["CapAdd"] = request.capAdd }
        if !request.capDrop.isEmpty { host["CapDrop"] = request.capDrop }
        if request.readOnly { host["ReadonlyRootfs"] = true }
        if !request.dns.isEmpty { host["Dns"] = request.dns }
        if !request.tmpfs.isEmpty {
            host["Tmpfs"] = Dictionary(request.tmpfs.map { ($0, "") }, uniquingKeysWith: { $1 })
        }
        if let network = request.networks.first { host["NetworkMode"] = network }
        if !request.publishedPorts.isEmpty {
            var exposed: [String: Any] = [:]
            var bindings: [String: [[String: String]]] = [:]
            for port in request.publishedPorts {
                let key = "\(port.containerPort)/\(port.transportProtocol)"
                exposed[key] = [String: String]()
                bindings[key, default: []].append(
                    ["HostPort": String(port.hostPort), "HostIp": port.hostIP ?? ""])
            }
            body["ExposedPorts"] = exposed
            host["PortBindings"] = bindings
        }
        body["HostConfig"] = host
        return body
    }

    /// "512m", "4g", "1024" (bytes) → bytes.
    static func parseBytes(_ raw: String) throws -> Int {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let units: [(String, Int)] = [
            ("kb", 1 << 10), ("k", 1 << 10), ("mb", 1 << 20), ("m", 1 << 20),
            ("gb", 1 << 30), ("g", 1 << 30), ("b", 1),
        ]
        for (suffix, scale) in units where lower.hasSuffix(suffix) {
            if let n = Double(lower.dropLast(suffix.count)) { return Int(n * Double(scale)) }
        }
        guard let n = Int(lower) else {
            throw MicropodError.message("invalidArgument: memory '\(raw)' — want e.g. 512m or 4g")
        }
        return n
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        let result = try await execDetailed(request)
        guard result.exitCode == 0 else {
            throw MicropodError.cliFailure(
                command: "docker exec \(request.containerID)", exitCode: result.exitCode, stderr: result.error)
        }
        return result.output
    }

    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        let docker = try api()
        var body: [String: Any] = [
            "Cmd": request.arguments, "AttachStdout": true, "AttachStderr": true, "Tty": request.tty,
        ]
        if !request.env.isEmpty { body["Env"] = request.env }
        if let workdir = request.workdir { body["WorkingDir"] = workdir }
        if let user = request.user { body["User"] = user }
        let created = try docker.check(
            try await docker.request("POST", "/containers/\(Self.escape(request.containerID))/exec", json: body))
        guard let execID = (try created.json() as? [String: Any])?["Id"] as? String else {
            throw MicropodError.message("internal: docker exec: no id")
        }
        let started = try docker.check(
            try await docker.request(
                "POST", "/exec/\(execID)/start", json: ["Detach": request.detach, "Tty": request.tty],
                timeout: .seconds(3600)))
        let (stdout, stderr) = request.tty ? (started.body, Data()) : DockerClient.demux(started.body)
        let inspected = try docker.check(try await docker.request("GET", "/exec/\(execID)/json"))
        let code = (try inspected.json() as? [String: Any])?["ExitCode"] as? Int ?? 0
        return ContainerExecResult(
            output: String(decoding: stdout, as: UTF8.self), error: String(decoding: stderr, as: UTF8.self),
            exitCode: Int32(code))
    }

    private func post(_ path: String, query: [String: String] = [:]) async throws {
        // 304: already started/stopped — idempotent like the apple engine.
        try api().check(try await api().request("POST", path, query: query), also: [304])
    }

    public func start(_ id: String) async throws { try await post("/containers/\(Self.escape(id))/start") }

    public func stop(_ id: String, timeout: Int) async throws {
        try await post("/containers/\(Self.escape(id))/stop", query: ["t": String(timeout)])
    }

    public func restart(_ id: String) async throws { try await post("/containers/\(Self.escape(id))/restart") }

    public func kill(_ id: String, signal: String) async throws {
        try await post("/containers/\(Self.escape(id))/kill", query: ["signal": signal])
    }

    public func delete(_ id: String, force: Bool) async throws {
        try api().check(
            try await api().request(
                "DELETE", "/containers/\(Self.escape(id))", query: ["force": force ? "1" : "0"]))
    }

    public func stopAll() async throws {
        for c in try await list() where c.state == "running" { try await stop(c.id, timeout: 10) }
    }

    public func deleteAll(force: Bool) async throws {
        for c in try await list() where force || c.state != "running" { try await delete(c.id, force: force) }
    }

    public func prune() async throws -> String {
        let response = try api().check(try await api().request("POST", "/containers/prune"))
        let json = try response.json() as? [String: Any]
        let removed = (json?["ContainersDeleted"] as? [String])?.count ?? 0
        let bytes = json?["SpaceReclaimed"] as? Int ?? 0
        return "removed \(removed) containers, reclaimed \(bytes) bytes"
    }

    public func export(_ id: String, to outputPath: String) async throws {
        throw MicropodError.unsupported("runtime 'docker' does not support export")
    }

    public func copy(from: String, to: String) async throws {
        throw MicropodError.unsupported("runtime 'docker' does not support copy")
    }

    // MARK: LogStreaming

    public func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        logLines(id: id, tail: tail, follow: true)
    }

    public func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine] {
        var out: [LogLine] = []
        for try await line in logLines(id: id, tail: lines, follow: false) { out.append(line) }
        return out
    }

    func logLines(id: String, tail: Int?, follow: Bool) -> AsyncThrowingStream<LogLine, Error> {
        guard let client else {
            return AsyncThrowingStream {
                $0.finish(throwing: MicropodError.message("failedPrecondition: docker endpoint"))
            }
        }
        var query = ["stdout": "1", "stderr": "1", "follow": follow ? "1" : "0"]
        if let tail { query["tail"] = String(tail) }
        let chunks = client.stream("GET", "/containers/\(Self.escape(id))/logs", query: query)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = LogFrameSplitter()
                do {
                    for try await chunk in chunks {
                        for text in splitter.feed(chunk) { continuation.yield(LogLine(text: text)) }
                    }
                    for text in splitter.flush() { continuation.yield(LogLine(text: text)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: StatsSampling

    public func snapshot() async throws -> Micropod_V1_StatsSnapshot { try await snapshot(ids: []) }

    public func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot {
        let running = try await list().filter { $0.state == "running" && (ids.isEmpty || ids.contains($0.id)) }
        let docker = try api()
        let stats = await withTaskGroup(of: Micropod_V1_ContainerStats?.self) { group in
            for c in running {
                group.addTask {
                    guard
                        let r = try? await docker.request(
                            "GET", "/containers/\(Self.escape(c.id))/stats", query: ["stream": "false"],
                            timeout: .seconds(10)),
                        r.status == 200, let json = try? r.json() as? [String: Any]
                    else { return nil }
                    return Self.stats(id: c.id, json)
                }
            }
            var out: [Micropod_V1_ContainerStats] = []
            for await s in group { if let s { out.append(s) } }
            return out
        }
        return Micropod_V1_StatsSnapshot.with {
            $0.containers = stats.sorted { $0.id < $1.id }
            $0.sampledAt = ISO8601DateFormatter().string(from: Date())
        }
    }

    static func stats(id: String, _ json: [String: Any]) -> Micropod_V1_ContainerStats {
        func num(_ dict: Any?, _ path: String...) -> Double {
            var node = dict
            for key in path { node = (node as? [String: Any])?[key] }
            return (node as? NSNumber)?.doubleValue ?? 0
        }
        let cpuDelta =
            num(json, "cpu_stats", "cpu_usage", "total_usage") - num(json, "precpu_stats", "cpu_usage", "total_usage")
        let sysDelta = num(json, "cpu_stats", "system_cpu_usage") - num(json, "precpu_stats", "system_cpu_usage")
        let cpus = max(num(json, "cpu_stats", "online_cpus"), 1)
        let networks = json["networks"] as? [String: [String: Any]] ?? [:]
        return Micropod_V1_ContainerStats.with {
            $0.id = id
            $0.cpuPercent = sysDelta > 0 ? cpuDelta / sysDelta * cpus * 100 : 0
            $0.memoryUsedBytes = UInt64(num(json, "memory_stats", "usage"))
            $0.memoryLimitBytes = UInt64(num(json, "memory_stats", "limit"))
            $0.networkRxBytes = UInt64(networks.values.reduce(0) { $0 + num($1, "rx_bytes") })
            $0.networkTxBytes = UInt64(networks.values.reduce(0) { $0 + num($1, "tx_bytes") })
        }
    }
}

/// Incremental demux of Docker's framed log stream into text lines; frames
/// and lines may straddle chunk boundaries. Unframed (TTY) streams pass
/// through as plain text.
struct LogFrameSplitter {
    private var pending = Data()
    private var text = Data()
    private var framed: Bool?

    mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        if framed == nil, pending.count >= 8 {
            let b = [UInt8](pending.prefix(4))
            framed = b[0] <= 2 && b[1] == 0 && b[2] == 0 && b[3] == 0
        }
        guard let framed else { return [] }
        if !framed {
            text.append(pending)
            pending.removeAll()
            return lines()
        }
        while pending.count >= 8 {
            let h = [UInt8](pending.prefix(8))
            let length = Int(h[4]) << 24 | Int(h[5]) << 16 | Int(h[6]) << 8 | Int(h[7])
            guard pending.count >= 8 + length else { break }
            text.append(pending.subdata(in: pending.startIndex + 8..<pending.startIndex + 8 + length))
            pending.removeFirst(8 + length)
        }
        return lines()
    }

    mutating func flush() -> [String] {
        if framed != true { text.append(pending) }
        pending.removeAll()
        defer { text.removeAll() }
        let rest = lines()
        return text.isEmpty ? rest : rest + [String(decoding: text, as: UTF8.self)]
    }

    private mutating func lines() -> [String] {
        var out: [String] = []
        while let nl = text.firstIndex(of: 0x0A) {
            var line = text[text.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            out.append(String(decoding: line, as: UTF8.self))
            text.removeSubrange(text.startIndex...nl)
        }
        return out
    }
}
