import Foundation
import MicropodCore

/// Containers in one shared Linux machine booted by micropod's Rust
/// Hypervisor.framework VMM (`vmm/`), OrbStack-style: a single supervised
/// VM (`HVFMachineSupervisor`) runs containerd + crun behind a Docker
/// Engine API, and this engine drives that API over the machine's socket.
///
/// The machine starts on demand: `run`, `create` and `start` boot it when
/// it is stopped. Read-only calls (`probe`, `list`, `owns`, `inspect`,
/// stats, logs) never do — a stopped machine simply has no containers to
/// report, so routing stays cheap for every other engine.
///
/// The guest engine implements non-interactive Docker semantics. Requests
/// it cannot honour (interactive stdin, a TTY, archive copy/export,
/// signals other than SIGKILL) are refused explicitly.
public struct HVFEngine: RuntimeEngine, ContainerServing, LogStreaming, StatsSampling {
    public let machine: HVFMachineClient
    let docker: DockerEngine

    public var root: URL { machine.layout.root }
    public var name: String { "hvf" }
    public var kind: String { "microvm" }
    public var summary: String {
        "Shared Linux machine on micropod's Hypervisor.framework VMM — containers share one VM, started on first use"
    }
    /// Verified against the guest engine by `scripts/e2e_hvf.sh`.
    public static let supportedCapabilities = [
        "run", "create", "start", "stop", "restart", "kill", "delete", "exec", "logs", "stats", "ports", "volumes",
    ]
    public var capabilities: [String] { Self.supportedCapabilities }
    public var containers: any ContainerServing { self }
    public var logs: any LogStreaming { self }
    public var stats: (any StatsSampling)? { self }

    public init(root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let layout = root.map { HVFMachineLayout(root: $0) } ?? HVFMachineLayout(environment: environment)
        machine = HVFMachineClient(layout: layout, environment: environment)
        docker = DockerEngine(client: machine.docker)
    }

    // MARK: Probe

    /// Available once every asset is installed — a stopped machine is
    /// started by the first `run`. Never boots the VM.
    public func probe() async -> EngineProbe {
        let status = machine.status()
        let endpoint = machine.layout.dockerEndpoint
        guard status.installed else {
            return EngineProbe(
                available: false,
                reason:
                    "HVF machine not installed under \(root.path): missing \(status.missing.joined(separator: ", "))"
                    + " — run `micropod machine install`",
                endpoint: endpoint)
        }
        if let problem = status.problem {
            return EngineProbe(available: false, reason: "HVF machine unusable: \(problem)", endpoint: endpoint)
        }
        guard status.phase == .running, machine.isServing else {
            let next = status.phase == .failed ? "the next run retries" : "starts on first run"
            return EngineProbe(available: true, reason: "machine \(status.summary); \(next)", endpoint: endpoint)
        }
        do {
            let response = try await machine.docker.request("GET", "/version", timeout: .seconds(3))
            let info = (try? response.json()) as? [String: Any]
            let server = info?["Version"] as? String ?? "unknown"
            let api = info?["ApiVersion"] as? String ?? "?"
            return EngineProbe(
                available: true, reason: "machine \(status.summary)", version: "\(server) (Docker API \(api))",
                endpoint: endpoint)
        } catch {
            return EngineProbe(
                available: true,
                reason: "machine \(status.summary), but its Docker API did not answer: \(error.localizedDescription)",
                endpoint: endpoint)
        }
    }

    public func owns(_ id: String) async -> Bool {
        guard machine.isServing else { return false }
        return await docker.owns(id)
    }

    private func requireServing() throws {
        guard machine.isServing else {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine is not running (\(machine.status().summary)); "
                    + "start it with `micropod machine start`")
        }
    }

    private func unsupported(_ what: String) -> MicropodError {
        .unsupported("runtime 'hvf' does not support \(what)")
    }

    // MARK: ContainerServing

    /// The guest's listing has no ports; a running container's come from
    /// its inspect (one local round trip each, concurrently).
    public func list() async throws -> [Micropod_V1_Container] {
        guard machine.isServing else { return [] }
        let listed = try await docker.list()
        let docker = self.docker
        let ports = await withTaskGroup(of: (String, [Micropod_V1_PortMapping]).self) { group in
            for container in listed where container.state == "running" {
                group.addTask {
                    // A container removed since the listing simply has no ports.
                    guard let data = try? await docker.inspect(container.id) else { return (container.id, []) }
                    return (container.id, Self.publishedPorts(inspect: data))
                }
            }
            var found: [String: [Micropod_V1_PortMapping]] = [:]
            for await (id, mappings) in group where !mappings.isEmpty { found[id] = mappings }
            return found
        }
        return listed.map { container in
            var container = container
            container.runtime = name
            if container.publishedPorts.isEmpty, let mapped = ports[container.id] { container.publishedPorts = mapped }
            return container
        }
    }

    /// `NetworkSettings.Ports` (`{"80/tcp": [{"HostIp", "HostPort"}]}`).
    static func publishedPorts(inspect data: Data) -> [Micropod_V1_PortMapping] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let settings = json["NetworkSettings"] as? [String: Any],
            let ports = settings["Ports"] as? [String: Any]
        else { return [] }
        return ports.keys.sorted().flatMap { key -> [Micropod_V1_PortMapping] in
            let parts = key.split(separator: "/")
            guard let container = parts.first.flatMap({ UInt32($0) }) else { return [] }
            let transport = parts.count > 1 ? String(parts[1]) : "tcp"
            return (ports[key] as? [[String: Any]] ?? []).compactMap { binding in
                guard let host = (binding["HostPort"] as? String).flatMap(UInt32.init) else { return nil }
                return Micropod_V1_PortMapping.with {
                    $0.hostPort = host
                    $0.containerPort = container
                    $0.protocol = transport
                    $0.hostIp = binding["HostIp"] as? String ?? ""
                }
            }
        }
    }

    public func inspect(_ id: String) async throws -> Data {
        try requireServing()
        return try await docker.inspect(id)
    }

    /// Refuses what the guest cannot do, and resolves host bind sources:
    /// the workspace share mounts at the host's canonical path, so
    /// `/tmp/x` must reach the guest as `/private/tmp/x`.
    static func admit(_ request: ContainerRunRequest) throws -> ContainerRunRequest {
        if request.interactive || request.tty {
            throw MicropodError.unsupported("runtime 'hvf' does not support interactive stdin or a TTY")
        }
        if request.sandbox != nil { throw MicropodError.unsupported("runtime 'hvf' does not support sandbox options") }
        var request = request
        request.volumes = request.volumes.map { spec in
            guard spec.hasPrefix("/") else { return spec }
            var parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            parts[0] = HVFMachineLayout.canonicalPath(parts[0])
            return parts.joined(separator: ":")
        }
        return request
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        let request = try Self.admit(request)
        try await machine.ensureRunning()
        return try await docker.create(request)
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        let request = try Self.admit(request)
        try await machine.ensureRunning()
        return try await docker.run(request)
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        let result = try await execDetailed(request)
        guard result.exitCode == 0 else {
            throw MicropodError.cliFailure(
                command: "hvf exec \(request.containerID)", exitCode: result.exitCode, stderr: result.error)
        }
        return result.output
    }

    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        if request.interactive || request.tty { throw unsupported("interactive exec (stdin or a TTY)") }
        if request.detach { throw unsupported("detached exec") }
        try requireServing()
        return try await docker.execDetailed(request)
    }

    public func start(_ id: String) async throws {
        try await machine.ensureRunning()
        try await docker.start(id)
    }

    public func stop(_ id: String, timeout: Int) async throws {
        try requireServing()
        try await docker.stop(id, timeout: timeout)
    }

    /// The guest engine has no restart operation: stop (with grace), start.
    public func restart(_ id: String) async throws {
        try requireServing()
        try await docker.stop(id, timeout: 10)
        try await docker.start(id)
    }

    public func stopAll() async throws {
        guard machine.isServing else { return }
        try await docker.stopAll()
    }

    /// The guest maps kill onto CRI StopContainer, which only delivers SIGKILL.
    public func kill(_ id: String, signal: String) async throws {
        let normalized = signal.uppercased().replacingOccurrences(of: "SIG", with: "")
        guard ["", "KILL", "9"].contains(normalized) else { throw unsupported("signal \(signal) (SIGKILL only)") }
        try requireServing()
        try await docker.kill(id, signal: "KILL")
    }

    public func delete(_ id: String, force: Bool) async throws {
        try requireServing()
        try await docker.delete(id, force: force)
    }

    public func deleteAll(force: Bool) async throws {
        guard machine.isServing else { return }
        try await docker.deleteAll(force: force)
    }

    /// No `containers/prune` in the guest: remove every container that is
    /// not running or starting.
    public func prune() async throws -> String {
        guard machine.isServing else { return "" }
        var removed = 0
        for container in try await docker.list() where !["running", "starting"].contains(container.state) {
            try await docker.delete(container.id, force: false)
            removed += 1
        }
        return removed == 0 ? "" : "removed \(removed) containers"
    }

    public func export(_ id: String, to outputPath: String) async throws {
        throw unsupported("export (the guest engine has no archive API)")
    }

    public func copy(from: String, to: String) async throws {
        throw unsupported("copy (the guest engine has no archive API)")
    }

    // MARK: LogStreaming

    /// The guest serves the whole log or nothing (no `tail`/`since`), so
    /// the tail is cut here.
    public func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine] {
        try requireServing()
        var splitter = LogFrameSplitter()
        var kept: [String] = []
        for try await chunk in logChunks(id: id, follow: false) {
            kept += splitter.feed(chunk)
            if lines >= 0, kept.count > 2 * lines + 256 { kept.removeFirst(kept.count - lines) }
        }
        kept += splitter.flush()
        return (lines >= 0 ? Array(kept.suffix(lines)) : kept).map { LogLine(text: $0) }
    }

    /// With `tail`, the existing log is read first and its last `tail`
    /// complete lines shown; the follow stream then replays the same
    /// append-only file from the start, so those lines are skipped by count
    /// and nothing written in between is lost.
    public func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try requireServing()
                    var skip = 0
                    if let tail {
                        var splitter = LogFrameSplitter()
                        var recent: [String] = []
                        for try await chunk in logChunks(id: id, follow: false) {
                            let lines = splitter.feed(chunk)
                            skip += lines.count
                            recent += lines
                            if recent.count > 2 * max(tail, 0) + 256 { recent.removeFirst(recent.count - max(tail, 0)) }
                        }
                        for line in recent.suffix(max(tail, 0)) { continuation.yield(LogLine(text: line)) }
                    }
                    var splitter = LogFrameSplitter()
                    for try await chunk in logChunks(id: id, follow: true) {
                        for line in splitter.feed(chunk) {
                            if skip > 0 {
                                skip -= 1
                            } else {
                                continuation.yield(LogLine(text: line))
                            }
                        }
                    }
                    for line in splitter.flush().dropFirst(skip) { continuation.yield(LogLine(text: line)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func logChunks(id: String, follow: Bool) -> AsyncThrowingStream<Data, Error> {
        machine.docker.stream(
            "GET", "/containers/\(DockerEngine.escape(id))/logs",
            query: ["stdout": "1", "stderr": "1", "follow": follow ? "1" : "0"])
    }

    // MARK: StatsSampling

    public func snapshot() async throws -> Micropod_V1_StatsSnapshot { try await snapshot(ids: []) }

    public func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot {
        guard machine.isServing else {
            return Micropod_V1_StatsSnapshot.with { $0.sampledAt = ISO8601DateFormatter().string(from: Date()) }
        }
        return try await docker.snapshot(ids: ids)
    }
}
