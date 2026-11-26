import Foundation
import MicropodCore

/// Containers in one shared Linux machine booted by micropod's Rust
/// Hypervisor.framework VMM (`vmm/`), OrbStack-style: a single supervised
/// VM (`HVFMachineSupervisor`) runs containerd + crun behind a Docker
/// Engine API, and this engine drives that API over the machine's socket.
///
/// The machine starts on demand: `run`, `create`, and `start` or `restart`
/// of one of its containers boot it when it is stopped. Read-only calls
/// (`probe`, `list`, `owns`, `inspect`, stats, logs) never do — a stopped
/// machine lists no containers, so routing stays cheap for every other
/// engine. Its containers still route here while it is stopped: `owns`
/// answers from `HVFContainerIndex` on the host, and every id-based call
/// other than start/restart then reports that the machine is stopped.
///
/// The attached CLI exec path supports piped stdin and separate binary output.
/// Terminal exec, archive copy/export and signals other than SIGKILL have
/// separate capability checks.
public struct HVFEngine: RuntimeEngine, ContainerServing, LogStreaming, StatsSampling {
    public let machine: HVFMachineClient
    let docker: DockerEngine

    public var root: URL { machine.layout.root }
    public var name: String { "hvf" }
    public var kind: String { "microvm" }
    public var summary: String {
        "Shared Linux machine on micropod's Hypervisor.framework VMM — containers share one VM, started on first use"
    }
    /// Verified against the guest engine by `scripts/e2e_hvf.sh`. "volumes"
    /// and "images" are the subsets `HVFVolumeStore`/`HVFImageStore` list.
    public static let supportedCapabilities = [
        "run", "create", "start", "stop", "restart", "kill", "delete", "exec", "logs", "stats", "ports", "volumes",
        "images",
    ]
    public var capabilities: [String] { Self.supportedCapabilities }
    public var containers: any ContainerServing { self }
    public var logs: any LogStreaming { self }
    public var stats: (any StatsSampling)? { self }
    public var volumeStore: (any EngineVolumeServing)? { HVFVolumeStore(machine: machine) }
    public var imageStore: (any EngineImageServing)? { HVFImageStore(machine: machine) }

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

    var index: HVFContainerIndexStore { HVFContainerIndexStore(layout: machine.layout) }

    /// The guest decides while the machine serves; otherwise the host-side
    /// index does, so a stopped machine's containers are never misrouted
    /// to another engine (and never boot the machine).
    public func owns(_ id: String) async -> Bool {
        guard machine.isServing else { return index.load().entry(for: id) != nil }
        return await docker.owns(id)
    }

    /// `id` names the container the failing call was about.
    private func requireServing(_ id: String? = nil) throws {
        guard machine.isServing else {
            let status = machine.status().summary
            if let id {
                throw MicropodError.message(
                    "failedPrecondition: container '\(id)' is on the hvf machine, which is not running (\(status)); "
                        + "run `micropod machine start` (`micropod start \(id)` also starts it)")
            }
            throw MicropodError.message(
                "failedPrecondition: the hvf machine is not running (\(status)); "
                    + "start it with `micropod machine start`")
        }
    }

    /// Runs `body` on container `id`; a guest 404 also drops a stale index entry.
    private func forgettingMissing<T>(_ id: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if ConnectCodeMapping.code(for: error) == "not_found" { index.update { $0.remove(id) } }
            throw error
        }
    }

    /// Replaces the index from a fresh guest listing (best-effort).
    private func refreshIndex() async {
        let listedAt = Date()
        guard let listed = try? await docker.listWithIDs() else { return }
        index.update { $0.refresh(from: Self.indexEntries(listed), listedAt: listedAt) }
    }

    /// `list` names a container by its name when it has one, else its id.
    static func indexEntries(_ listed: [(container: Micropod_V1_Container, engineID: String)])
        -> [(id: String, name: String?)]
    {
        listed.compactMap { entry in
            let id = entry.engineID.isEmpty ? entry.container.id : entry.engineID
            guard !id.isEmpty else { return nil }
            return (id, entry.container.id == id || entry.container.id.isEmpty ? nil : entry.container.id)
        }
    }

    private func unsupported(_ what: String) -> MicropodError {
        .unsupported("runtime 'hvf' does not support \(what)")
    }

    // MARK: ContainerServing

    /// The guest's listing has no ports; a running container's come from
    /// its inspect (one local round trip each, concurrently). Every listing
    /// also refreshes the container index.
    public func list() async throws -> [Micropod_V1_Container] {
        guard machine.isServing else { return [] }
        let listedAt = Date()
        let entries = try await docker.listWithIDs()
        index.update { $0.refresh(from: Self.indexEntries(entries), listedAt: listedAt) }
        let listed = entries.map(\.container)
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
        try requireServing(id)
        return try await forgettingMissing(id) { try await docker.inspect(id) }
    }

    /// Refuses what the guest cannot do, resolves host bind sources (the
    /// workspace share mounts at the host's canonical path, so `/tmp/x`
    /// must reach the guest as `/private/tmp/x`), and turns `--cache` and
    /// `--cache-scope` into the labels the guest engine reads
    /// (`io.micropod.cache`, `io.micropod.cache.scope`; a label the request
    /// already sets wins).
    static func admit(_ request: ContainerRunRequest) throws -> ContainerRunRequest {
        if request.interactive || request.tty {
            throw MicropodError.unsupported("runtime 'hvf' does not support interactive stdin or a TTY")
        }
        if request.sandbox != nil { throw MicropodError.unsupported("runtime 'hvf' does not support sandbox options") }
        var request = try ContainerCacheOptions.admitted(request, runtime: "hvf")
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
        return try await createIndexed(request)
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        let request = try Self.admit(request)
        try await machine.ensureRunning()
        // Indexed before the start: a container whose start fails still exists.
        let handle = try await createIndexed(request)
        try await docker.start(handle)
        return handle
    }

    private func createIndexed(_ request: ContainerRunRequest) async throws -> String {
        let created = try await docker.createContainer(request)
        let id = created.engineID.isEmpty ? created.handle : created.engineID
        index.update { $0.record(id: id, name: request.name) }
        return created.handle
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
        if !request.detach && (request.interactive || request.tty) {
            throw unsupported("interactive exec requires attached file handles")
        }
        try requireServing(request.containerID)
        return try await docker.execDetailed(request)
    }

    public func execAttached(_ request: ContainerExecRequest, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle)
        async throws -> Int32
    {
        try requireServing(request.containerID)
        return try await docker.execAttached(request, stdin: stdin, stdout: stdout, stderr: stderr)
    }

    /// Boots a stopped machine first: its containers survive a machine stop.
    public func start(_ id: String) async throws {
        try await machine.ensureRunning()
        try await forgettingMissing(id) { try await docker.start(id) }
    }

    public func stop(_ id: String, timeout: Int) async throws {
        try requireServing(id)
        try await docker.stop(id, timeout: timeout)
    }

    /// The guest engine has no restart operation: stop (with grace), start.
    /// Like `start`, boots a stopped machine.
    public func restart(_ id: String) async throws {
        try await machine.ensureRunning()
        try await forgettingMissing(id) { try await docker.stop(id, timeout: 10) }
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
        try requireServing(id)
        try await docker.kill(id, signal: "KILL")
    }

    public func delete(_ id: String, force: Bool) async throws {
        try requireServing(id)
        try await forgettingMissing(id) { try await docker.delete(id, force: force) }
        index.update { $0.remove(id) }
    }

    public func deleteAll(force: Bool) async throws {
        guard machine.isServing else { return }
        do {
            try await docker.deleteAll(force: force)
        } catch {
            await refreshIndex()
            throw error
        }
        await refreshIndex()
    }

    /// No `containers/prune` in the guest: remove every container that is
    /// not running or starting. Best-effort per container, like Docker's
    /// prune: one that cannot be removed is reported, the rest still go,
    /// and one already gone counts as pruned by someone else.
    public func prune() async throws -> String {
        guard machine.isServing else { return "" }
        var removed: [String] = []
        var failures: [String] = []
        for container in try await docker.list() where !["running", "starting"].contains(container.state) {
            do {
                try await docker.delete(container.id, force: false)
                removed.append(container.id)
            } catch {
                if ConnectCodeMapping.code(for: error) == "not_found" {
                    removed.append(container.id)  // removed by someone else meanwhile
                } else {
                    failures.append("\(container.id) (\(error.localizedDescription))")
                }
            }
        }
        if !removed.isEmpty { index.update { index in removed.forEach { index.remove($0) } } }
        return Self.pruneReport(removed: removed.count, failures: failures)
    }

    static func pruneReport(removed: Int, failures: [String]) -> String {
        var parts: [String] = []
        if removed > 0 { parts.append("removed \(removed) containers") }
        if !failures.isEmpty {
            parts.append("could not remove \(failures.count): \(failures.joined(separator: "; "))")
        }
        return parts.joined(separator: "; ")
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
        try requireServing(id)
        var splitter = LogFrameSplitter()
        var kept = LogTailBuffer(limit: lines)
        for try await chunk in logChunks(id: id, follow: false) {
            kept.append(splitter.feed(chunk))
        }
        kept.append(splitter.flush())
        return kept.lines.map { LogLine(text: $0) }
    }

    /// With `tail`, the existing log is read first and its last `tail`
    /// complete lines shown; the follow stream then replays the same
    /// append-only file from the start, so those lines are skipped by count
    /// and nothing written in between is lost.
    public func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try requireServing(id)
                    var skip = 0
                    if let tail {
                        var splitter = LogFrameSplitter()
                        var recent = LogTailBuffer(limit: max(tail, 0))
                        for try await chunk in logChunks(id: id, follow: false) {
                            let lines = splitter.feed(chunk)
                            skip += lines.count
                            recent.append(lines)
                        }
                        for line in recent.lines { continuation.yield(LogLine(text: line)) }
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

/// The last `limit` lines of a log that may be far longer, without holding
/// all of it: trimmed back to `limit` whenever it grows past about twice
/// that. A negative limit keeps every line. Any `limit` is safe, including
/// `Int.max` from a client's `tail` parameter.
struct LogTailBuffer {
    let limit: Int
    private var buffered: [String] = []

    init(limit: Int) { self.limit = limit }

    /// `2 * limit + 256`, saturating.
    var trimThreshold: Int {
        let (doubled, overflow) = limit.multipliedReportingOverflow(by: 2)
        let (bound, overflowAgain) = doubled.addingReportingOverflow(256)
        return overflow || overflowAgain ? Int.max : bound
    }

    mutating func append(_ lines: [String]) {
        buffered += lines
        if limit >= 0, buffered.count > trimThreshold { buffered.removeFirst(buffered.count - limit) }
    }

    var lines: [String] { limit >= 0 ? Array(buffered.suffix(limit)) : buffered }
}
