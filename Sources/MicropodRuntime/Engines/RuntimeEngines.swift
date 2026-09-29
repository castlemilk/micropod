import Foundation
import MicropodCore
import Synchronization

/// An execution engine micropod can drive: "apple" (a micro-VM per
/// container via container-apiserver), "docker" (a Docker Engine socket) or
/// "sandbox" (in-process ephemeral micro-VMs).
///
/// Engines are orthogonal to `RuntimeBackendKind`, which only picks the
/// transport (XPC vs CLI) to the apple engine.
public protocol RuntimeEngine: Sendable {
    var name: String { get }
    /// "vm", "microvm" or "container" (`RuntimeInfo.kind`).
    var kind: String { get }
    var summary: String { get }
    /// `RuntimeInfo.capabilities`; calls outside it throw `.unsupported`.
    var capabilities: [String] { get }
    var containers: any ContainerServing { get }
    var logs: any LogStreaming { get }
    var stats: (any StatsSampling)? { get }
    func probe() async -> EngineProbe
    /// Cheap ownership test used to route id-based calls.
    func owns(_ id: String) async -> Bool
}

public struct EngineProbe: Sendable, Equatable {
    public var available: Bool
    public var reason = ""
    public var version = ""
    public var endpoint = ""

    public init(available: Bool, reason: String = "", version: String = "", endpoint: String = "") {
        self.available = available
        self.reason = reason
        self.version = version
        self.endpoint = endpoint
    }
}

// MARK: - Persisted configuration

/// `~/.micropod/runtimes.json` (`MICROPOD_RUNTIMES_CONFIG` overrides the
/// path). Written by `SetDefaultRuntime` / `UpdateRuntime`.
public struct EngineConfig: Codable, Sendable, Equatable {
    public struct Engine: Codable, Sendable, Equatable {
        public var enabled: Bool?
        public var endpoint: String?
    }

    public var `default`: String?
    public var engines: [String: Engine] = [:]

    public init(default: String? = nil, engines: [String: Engine] = [:]) {
        self.default = `default`
        self.engines = engines
    }

    /// "docker" is opt-in so an existing Docker Desktop's containers don't
    /// appear in `ps` until asked for; everything else defaults on.
    static let enabledByDefault: Set<String> = ["apple", "sandbox"]

    func isEnabled(_ name: String) -> Bool {
        engines[name]?.enabled ?? Self.enabledByDefault.contains(name)
    }

    static func url(environment: [String: String]) -> URL {
        if let path = environment["MICROPOD_RUNTIMES_CONFIG"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod/runtimes.json")
    }

    static func load(from url: URL) -> EngineConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(EngineConfig.self, from: data)
        else { return EngineConfig() }
        return config
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Registry

/// Process-wide engine set + config. The non-apple engines live here (not in
/// `RuntimeServices`) because they must survive the apple backend's
/// CLI→native swaps: sandbox sessions are owned by this process.
public final class EngineRegistry: Sendable {
    public static let shared = EngineRegistry()

    private struct State {
        var config: EngineConfig
        var docker: DockerEngine
    }

    private let state: Mutex<State>
    private let configURL: URL
    /// `MICROPOD_DEFAULT_RUNTIME` overrides the persisted default (CI jobs).
    private let envDefault: String?
    public let sandbox: SandboxEngine

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sandbox: SandboxEngine = SandboxEngine()
    ) {
        configURL = EngineConfig.url(environment: environment)
        let config = EngineConfig.load(from: configURL)
        envDefault = environment["MICROPOD_DEFAULT_RUNTIME"]
        self.sandbox = sandbox
        state = Mutex(
            State(
                config: config,
                docker: DockerEngine(endpoint: config.engines["docker"]?.endpoint, environment: environment)))
    }

    public static let engineNames = ["apple", "docker", "sandbox"]

    public var config: EngineConfig { state.withLock { $0.config } }

    public var defaultName: String {
        if let envDefault { return envDefault }
        return state.withLock { $0.config.default } ?? "apple"
    }

    public func isEnabled(_ name: String) -> Bool {
        name == defaultName || state.withLock { $0.config.isEnabled(name) }
    }

    /// Non-apple engine by name (enabled or not).
    public func engine(_ name: String) -> (any RuntimeEngine)? {
        switch name {
        case "docker": return state.withLock { $0.docker }
        case "sandbox": return sandbox
        default: return nil
        }
    }

    /// Enabled non-apple engines, in routing order (cheapest ownership
    /// check first: sandbox is in-memory, docker is one socket round trip).
    public func extraEngines() -> [any RuntimeEngine] {
        ["sandbox", "docker"].filter(isEnabled).compactMap(engine)
    }

    public func setDefault(_ name: String, apple: any RuntimeEngine) async throws {
        guard Self.engineNames.contains(name) else {
            throw MicropodError.message("failedPrecondition: unknown runtime '\(name)'")
        }
        let target = name == "apple" ? apple : engine(name)!
        let probe = await target.probe()
        guard probe.available else {
            throw MicropodError.message("failedPrecondition: runtime '\(name)' unavailable: \(probe.reason)")
        }
        try mutate { config in
            config.default = name
            config.engines[name, default: .init()].enabled = true
        }
    }

    public func update(_ name: String, enabled: Bool?, endpoint: String?) throws {
        guard Self.engineNames.contains(name) else {
            throw MicropodError.message("failedPrecondition: unknown runtime '\(name)'")
        }
        if enabled == false, name == defaultName {
            throw MicropodError.message(
                "failedPrecondition: '\(name)' is the default runtime — set another default first")
        }
        if let endpoint, !endpoint.isEmpty {
            guard name == "docker" else {
                throw MicropodError.message("invalidArgument: runtime '\(name)' has no configurable endpoint")
            }
            if case .unix(let path) = try DockerClient.Endpoint.parse(endpoint),
                URL(fileURLWithPath: path).standardizedFileURL.path
                    == URL(fileURLWithPath: NSString("~/.micropod/docker.sock").expandingTildeInPath)
                    .standardizedFileURL.path
            {
                throw MicropodError.message(
                    "invalidArgument: that is micropod's own Docker shim — it already fronts the apple runtime")
            }
        }
        try mutate { config in
            if let enabled { config.engines[name, default: .init()].enabled = enabled }
            if let endpoint {
                config.engines[name, default: .init()].endpoint = endpoint.isEmpty ? nil : endpoint
            }
        }
        if endpoint != nil {
            state.withLock {
                $0.docker = DockerEngine(endpoint: $0.config.engines["docker"]?.endpoint)
            }
        }
    }

    private func mutate(_ body: (inout EngineConfig) -> Void) throws {
        let snapshot = state.withLock { state -> EngineConfig in
            body(&state.config)
            return state.config
        }
        try snapshot.save(to: configURL)
    }

    /// `ListRuntimes` payload; `apple` is the live apple engine.
    public func describe(apple: any RuntimeEngine) async -> Micropod_V1_ListRuntimesResponse {
        let defaultName = self.defaultName
        let engines: [any RuntimeEngine] = [apple] + ["docker", "sandbox"].compactMap(engine)
        var infos: [Micropod_V1_RuntimeInfo] = []
        for engine in engines {
            let probe = await engine.probe()
            infos.append(
                Micropod_V1_RuntimeInfo.with {
                    $0.name = engine.name
                    $0.kind = engine.kind
                    $0.description_p = engine.summary
                    $0.available = probe.available
                    $0.reason = probe.reason
                    $0.version = probe.version
                    $0.endpoint = probe.endpoint
                    $0.default = engine.name == defaultName
                    $0.enabled = isEnabled(engine.name)
                    $0.capabilities = engine.capabilities
                })
        }
        return Micropod_V1_ListRuntimesResponse.with {
            $0.runtimes = infos
            $0.default = defaultName
        }
    }
}

// MARK: - Apple engine

/// The existing backend (native XPC or CLI) presented as an engine.
public struct AppleEngine: RuntimeEngine {
    public let services: RuntimeServices
    public var name: String { "apple" }
    public var kind: String { "vm" }
    public var summary: String { "Apple container runtime — one micro-VM per container" }
    public var capabilities: [String] {
        [
            "run", "create", "start", "stop", "restart", "kill", "delete", "exec", "logs", "stats", "ports",
            "volumes", "networks", "export", "copy",
        ]
    }
    public var containers: any ContainerServing { services.containers }
    public var logs: any LogStreaming { services.logs }
    public var stats: (any StatsSampling)? { services.stats }

    public init(services: RuntimeServices) { self.services = services }

    public func probe() async -> EngineProbe {
        let version = services.health?.apiServerVersion ?? ""
        // A CLI backend is still usable while the runtime daemon is up; the
        // native ping having succeeded is the strong signal.
        if services.kind == .native {
            return EngineProbe(available: true, version: version, endpoint: "xpc:com.apple.container.apiserver")
        }
        let cli = ProcessInfo.processInfo.environment["MICROPOD_CONTAINER_CLI_PATH"] ?? "/usr/local/bin/container"
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            return EngineProbe(available: false, reason: "container CLI not found at \(cli)", endpoint: cli)
        }
        return EngineProbe(available: true, version: version, endpoint: cli)
    }

    public func owns(_ id: String) async -> Bool { true }
}

// MARK: - Router

/// `ContainerServing` over every enabled engine. `run`/`create` go to the
/// requested (or default) engine; id-based calls go to the engine that owns
/// the id, resolved sandbox → docker → apple; `list` merges all enabled
/// engines and stamps `Container.runtime`.
public struct RuntimeRouter: ContainerServing, LogStreaming, StatsSampling {
    public let apple: AppleEngine
    public let registry: EngineRegistry

    public init(apple: AppleEngine, registry: EngineRegistry) {
        self.apple = apple
        self.registry = registry
    }

    /// Engine for a new container.
    func target(_ request: ContainerRunRequest) async throws -> any RuntimeEngine {
        let name = request.runtime ?? registry.defaultName
        if name == "apple" { return apple }
        guard let engine = registry.engine(name) else {
            throw MicropodError.message(
                "failedPrecondition: unknown runtime '\(name)' (known: \(EngineRegistry.engineNames.joined(separator: ", ")))"
            )
        }
        guard registry.isEnabled(name) else {
            throw MicropodError.message(
                "failedPrecondition: runtime '\(name)' is disabled — enable it with UpdateRuntime")
        }
        let probe = await engine.probe()
        guard probe.available else {
            throw MicropodError.message("failedPrecondition: runtime '\(name)' unavailable: \(probe.reason)")
        }
        return engine
    }

    /// Engine that owns an existing container id.
    func owner(_ id: String) async -> any RuntimeEngine {
        for engine in registry.extraEngines() where await engine.owns(id) {
            return engine
        }
        return apple
    }

    static func require(_ engine: any RuntimeEngine, _ capability: String) throws {
        guard engine.capabilities.contains(capability) else {
            throw MicropodError.unsupported("runtime '\(engine.name)' does not support \(capability)")
        }
    }

    // MARK: ContainerServing

    public func list() async throws -> [Micropod_V1_Container] {
        var all = try await apple.containers.list().map { container in
            var container = container
            container.runtime = "apple"
            return container
        }
        // Other engines are best-effort: a stopped Docker Desktop must not
        // fail the listing of containers that are running fine elsewhere.
        for engine in registry.extraEngines() {
            guard let listed = try? await engine.containers.list() else { continue }
            all += listed.map { container in
                var container = container
                container.runtime = engine.name
                return container
            }
        }
        return all
    }

    public func inspect(_ id: String) async throws -> Data {
        try await owner(id).containers.inspect(id)
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        let engine = try await target(request)
        try Self.require(engine, "create")
        return try await engine.containers.create(request)
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        try await target(request).containers.run(request)
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        try await owner(request.containerID).containers.exec(request)
    }

    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        try await owner(request.containerID).containers.execDetailed(request)
    }

    public func start(_ id: String) async throws { try await owner(id).containers.start(id) }

    public func stop(_ id: String, timeout: Int) async throws {
        try await owner(id).containers.stop(id, timeout: timeout)
    }

    public func restart(_ id: String) async throws { try await owner(id).containers.restart(id) }

    public func stopAll() async throws {
        try await apple.containers.stopAll()
        for engine in registry.extraEngines() { try? await engine.containers.stopAll() }
    }

    public func kill(_ id: String, signal: String) async throws {
        try await owner(id).containers.kill(id, signal: signal)
    }

    public func delete(_ id: String, force: Bool) async throws {
        try await owner(id).containers.delete(id, force: force)
    }

    public func deleteAll(force: Bool) async throws {
        try await apple.containers.deleteAll(force: force)
        for engine in registry.extraEngines() { try? await engine.containers.deleteAll(force: force) }
    }

    public func prune() async throws -> String {
        var reports = [try await apple.containers.prune()]
        for engine in registry.extraEngines() {
            if let report = try? await engine.containers.prune(), !report.isEmpty {
                reports.append("\(engine.name): \(report)")
            }
        }
        return reports.joined(separator: "\n")
    }

    public func export(_ id: String, to outputPath: String) async throws {
        let engine = await owner(id)
        try Self.require(engine, "export")
        try await engine.containers.export(id, to: outputPath)
    }

    public func copy(from: String, to: String) async throws {
        // `id:path` on either side names the container.
        let ref = [from, to].first { !$0.hasPrefix("/") && !$0.hasPrefix(".") && $0.contains(":") }
        let id = ref.map { String($0.prefix { $0 != ":" }) }
        let engine: any RuntimeEngine = if let id { await owner(id) } else { apple }
        try Self.require(engine, "copy")
        try await engine.containers.copy(from: from, to: to)
    }

    // MARK: LogStreaming

    public func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in await owner(id).logs.stream(id: id, tail: tail, boot: boot) {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine] {
        try await owner(id).logs.tail(id: id, lines: lines, boot: boot)
    }

    // MARK: StatsSampling

    public func snapshot() async throws -> Micropod_V1_StatsSnapshot {
        try await snapshot(ids: [])
    }

    public func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot {
        var merged = try await apple.stats?.snapshot(ids: ids) ?? Micropod_V1_StatsSnapshot()
        for engine in registry.extraEngines() {
            guard let sampler = engine.stats, let snap = try? await sampler.snapshot(ids: ids) else { continue }
            merged.containers += snap.containers
        }
        return merged
    }
}

extension RuntimeServices {
    /// These services with containers/logs/stats routed across every
    /// enabled engine. Volumes, the XPC client and exit codes stay apple's.
    public func routed(through registry: EngineRegistry = .shared) -> RuntimeServices {
        guard router == nil else { return self }
        let router = RuntimeRouter(apple: AppleEngine(services: self), registry: registry)
        return RuntimeServices(
            kind: kind, containers: router, logs: router, stats: router, volumes: volumes,
            api: api, health: health, exitCodes: exitCodes)
    }

    /// The router when these services are routed, for engine management.
    public var router: RuntimeRouter? { containers as? RuntimeRouter }
}
