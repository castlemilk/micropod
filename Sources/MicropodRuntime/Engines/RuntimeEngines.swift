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
    /// Named volumes this engine keeps, for `VolumeRouter`; nil when it has
    /// none of its own. The Apple runtime's are passed to the router by
    /// each surface instead.
    var volumeStore: (any EngineVolumeServing)? { get }
    /// Images this engine keeps, for `ImageRouter`; nil when it has none.
    var imageStore: (any EngineImageServing)? { get }
    func probe() async -> EngineProbe
    /// Cheap ownership test used to route id-based calls.
    func owns(_ id: String) async -> Bool
    /// Park until container `id` may have changed state (it exited) or
    /// `timeout` passes; false when the engine has no such signal and the
    /// caller should poll instead.
    func awaitStateChange(_ id: String, timeout: Duration) async -> Bool
    /// Exit code of an exited container when this engine tracks it natively
    /// (e.g. `hvf` or `sandbox`), or nil when unknown / still running.
    func exitCode(_ id: String) async -> Int32?
}

extension RuntimeEngine {
    public func awaitStateChange(_ id: String, timeout: Duration) async -> Bool { false }
    public func exitCode(_ id: String) async -> Int32? { nil }
    public var volumeStore: (any EngineVolumeServing)? { nil }
    public var imageStore: (any EngineImageServing)? { nil }
}

/// `RuntimeInfo.capabilities` for volume and image management, beyond the
/// container ones. "volumes" (mounting, listing, creating, inspecting and
/// removing named volumes) and "images" (listing, inspecting and pulling)
/// are the base; the rest are each one more operation.
public enum ResourceCapability {
    public static let imageRemove = "image-remove"  // rmi and image prune
    public static let imageTag = "image-tag"
    public static let imagePush = "image-push"
    public static let imageSave = "image-save"
    public static let imageLoad = "image-load"
    public static let build = "build"
    public static let volumePrune = "volume-prune"
    public static let volumeClone = "volume-clone"  // CloneVolume / CommitVolumeClone
}

public struct EngineProbe: Sendable, Equatable {
    public var available: Bool
    public var reason = ""
    public var version = ""
    public var endpoint = ""
    /// Live capabilities for engines that can vary with the active worker build.
    public var capabilities: [String]?

    public init(
        available: Bool, reason: String = "", version: String = "", endpoint: String = "", capabilities: [String]? = nil
    ) {
        self.available = available
        self.reason = reason
        self.version = version
        self.endpoint = endpoint
        self.capabilities = capabilities
    }
}

/// First-class execution modes: fast shared-VM containers (`hvf`) vs
/// 1-microVM-per-workload isolated sandboxes (`sandbox`).
public enum RuntimeMode: String, CaseIterable, Sendable {
    case container
    case sandbox

    public var engineName: String {
        switch self {
        case .container: return "hvf"
        case .sandbox: return "sandbox"
        }
    }

    public var summary: String {
        switch self {
        case .container: return "Fast shared Linux microVM (hvf — Docker API, BuildKit, 10-tool caches)"
        case .sandbox: return "Isolated 1-microVM-per-workload sandbox (ephemeral rootfs, checkpoints, egress control)"
        }
    }

    public init?(engineName: String) {
        switch EngineRegistry.canonicalName(engineName) {
        case "hvf": self = .container
        case "sandbox": self = .sandbox
        default: return nil
        }
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
        var hvf: HVFEngine
    }

    private let state: Mutex<State>
    private let configURL: URL
    private let dockerEnvironment: [String: String]
    /// `MICROPOD_DEFAULT_RUNTIME` overrides the persisted default (CI jobs).
    private let envDefault: String?
    public let sandbox: SandboxEngine
    private let ci: DockerEngine

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sandbox: SandboxEngine = SandboxEngine()
    ) {
        configURL = EngineConfig.url(environment: environment)
        dockerEnvironment = environment.filter { $0.key == "DOCKER_HOST" || $0.key == "DOCKER_API_VERSION" }
        let config = EngineConfig.load(from: configURL)
        envDefault = environment["MICROPOD_DEFAULT_RUNTIME"]
        self.sandbox = sandbox
        ci = DockerEngine(worker: CIWorker(environment: environment))
        state = Mutex(
            State(
                config: config,
                docker: DockerEngine(endpoint: config.engines["docker"]?.endpoint, environment: environment),
                hvf: HVFEngine(environment: environment)))
    }

    public static let engineNames = ["apple", "docker", "sandbox", "ci", "hvf"]

    /// Normalizes ergonomic mode aliases (`container` -> `hvf`, `isolated`/`microvm` -> `sandbox`)
    /// so every CLI and API surface speaks both clean modes and concrete engine names.
    public static func canonicalName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "container", "containers": return "hvf"
        case "sandbox", "sandboxes", "isolated", "microvm": return "sandbox"
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    public var config: EngineConfig { state.withLock { $0.config } }

    public var defaultName: String {
        if let envDefault { return Self.canonicalName(envDefault) }
        if let persisted = state.withLock({ $0.config.default }) {
            return Self.canonicalName(persisted)
        }
        return "apple"
    }

    public var activeMode: RuntimeMode? { RuntimeMode(engineName: defaultName) }

    /// Whether a merged listing leaves Apple's runtime out without asking
    /// it: another engine is the default and Apple's is disabled or not
    /// installed. With Apple the default, or enabled and installed, it is
    /// asked as before (a stopped runtime is then skipped by its error, which
    /// a gated client answers without spawning).
    public func skipsApple(installed: @autoclosure () -> Bool) -> Bool {
        defaultName != "apple" && (!isEnabled("apple") || !installed())
    }

    public func isEnabled(_ rawName: String) -> Bool {
        let name = Self.canonicalName(rawName)
        if name == defaultName { return true }
        return state.withLock { state in
            if let explicit = state.config.engines[name]?.enabled { return explicit }
            // Auto-enable HVF once installed on disk so users don't need a separate `runtime enable hvf`.
            if name == "hvf" { return state.hvf.machine.status().installed }
            return state.config.isEnabled(name)
        }
    }

    /// Non-apple engine by name (enabled or not).
    public func engine(_ rawName: String) -> (any RuntimeEngine)? {
        switch Self.canonicalName(rawName) {
        case "docker": return state.withLock { $0.docker }
        case "ci": return ci
        case "sandbox": return sandbox
        case "hvf": return state.withLock { $0.hvf }
        default: return nil
        }
    }

    /// Enabled non-apple engines, in routing order (cheapest ownership
    /// check first: sandbox is in-memory, docker is one socket round trip).
    public func extraEngines() -> [any RuntimeEngine] {
        ["sandbox", "ci", "docker", "hvf"].filter(isEnabled).compactMap(engine)
    }

    public func setDefault(_ rawName: String, apple: any RuntimeEngine) async throws {
        let name = Self.canonicalName(rawName)
        guard Self.engineNames.contains(name) else {
            throw MicropodError.message("failedPrecondition: unknown runtime '\(rawName)'")
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

    public func update(_ rawName: String, enabled: Bool?, endpoint: String?) throws {
        let name = Self.canonicalName(rawName)
        guard Self.engineNames.contains(name) else {
            throw MicropodError.message("failedPrecondition: unknown runtime '\(rawName)'")
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
                $0.docker = DockerEngine(
                    endpoint: $0.config.engines["docker"]?.endpoint, environment: dockerEnvironment)
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
        let engines: [any RuntimeEngine] = [apple] + ["docker", "sandbox", "ci", "hvf"].compactMap(engine)
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
                    $0.capabilities = probe.capabilities ?? engine.capabilities
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
    /// Whether the `container` CLI is on disk; injectable for tests.
    private let cliInstalled: @Sendable () -> Bool
    public var name: String { "apple" }
    public var kind: String { "vm" }
    public var summary: String { "Apple container runtime — one micro-VM per container" }
    public var capabilities: [String] {
        [
            "run", "create", "start", "stop", "restart", "kill", "delete", "exec", "logs", "stats", "ports",
            "volumes", "networks", "export", "copy", "images", ResourceCapability.imageRemove,
            ResourceCapability.imageTag, ResourceCapability.imagePush, ResourceCapability.imageSave,
            ResourceCapability.imageLoad, ResourceCapability.build, ResourceCapability.volumePrune,
            ResourceCapability.volumeClone,
        ]
    }
    public var containers: any ContainerServing { services.containers }
    public var logs: any LogStreaming { services.logs }
    public var stats: (any StatsSampling)? { services.stats }

    public init(services: RuntimeServices, cliInstalled: @escaping @Sendable () -> Bool = AppleEngine.cliIsInstalled) {
        self.services = services
        self.cliInstalled = cliInstalled
    }

    /// The `container` CLI the default client would run is on disk.
    @Sendable public static func cliIsInstalled() -> Bool {
        ContainerExecutableLocator.isExecutableFile(ContainerExecutableLocator.resolve().path)
    }

    /// Reachable without a local CLI over XPC (native) or the managed
    /// gateway, else only through the CLI.
    public var isInstalled: Bool { services.kind != .cli || cliInstalled() }

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
        let name = request.runtime.map(EngineRegistry.canonicalName) ?? registry.defaultName
        if request.sandbox != nil && name != "sandbox" {
            throw MicropodError.unsupported("sandbox options need runtime 'sandbox', not '\(name)'")
        }
        if request.initImage != nil && name != "apple" {
            throw MicropodError.unsupported("init_image needs runtime 'apple', not '\(name)'")
        }
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

    /// `RuntimeEngine.awaitStateChange` on the engine that owns `id`.
    public func awaitStateChange(_ id: String, timeout: Duration) async -> Bool {
        await owner(id).awaitStateChange(id, timeout: timeout)
    }

    /// Exit code reported by the engine that owns `id`, if available.
    public func exitCode(_ id: String) async -> Int32? {
        await owner(id).exitCode(id)
    }

    public func state(of id: String) async -> String {
        await owner(id).containers.state(of: id)
    }

    /// Engine that owns an existing container id. Each call probes the
    /// enabled engines (a guest round trip for hvf); a caller that observes
    /// one container repeatedly resolves it once.
    public func owner(_ id: String) async -> any RuntimeEngine {
        for engine in registry.extraEngines() where await engine.owns(id) {
            return engine
        }
        return apple
    }

    /// The Apple runtime is not running or cannot be reached: the errors
    /// `ConnectCodeMapping` classifies `unavailable` (`runtimeNotRunning`,
    /// a lost XPC channel, a missing `container` CLI, the CLI's own
    /// runtime-down output). Timeouts, decode failures, refusals and
    /// cancellation are not.
    static func appleRuntimeIsDown(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        return ConnectCodeMapping.code(for: error) == "unavailable"
    }

    static func require(_ engine: any RuntimeEngine, _ capability: String) throws {
        guard engine.capabilities.contains(capability) else {
            throw MicropodError.unsupported("runtime '\(engine.name)' does not support \(capability)")
        }
    }

    // MARK: ContainerServing

    public func list() async throws -> [Micropod_V1_Container] {
        var all: [Micropod_V1_Container] = []
        do {
            if !registry.skipsApple(installed: apple.isInstalled) {
                all = try await apple.containers.list().map { container in
                    var container = container
                    container.runtime = "apple"
                    return container
                }
            }
        } catch {
            // With another engine as the default, a stopped Apple runtime is
            // just one more best-effort engine: its absence must not hide
            // the default engine's containers. Any other Apple failure is
            // still the listing's failure.
            guard registry.defaultName != "apple", Self.appleRuntimeIsDown(error) else { throw error }
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
        return try await engine.containers.create(try Self.cacheLabels(request, for: engine))
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        let engine = try await target(request)
        return try await engine.containers.run(try Self.cacheLabels(request, for: engine))
    }

    /// `--cache`/`--cache-scope` as labels for engines other than hvf,
    /// which maps them itself (`HVFEngine.admit`).
    static func cacheLabels(_ request: ContainerRunRequest, for engine: any RuntimeEngine) throws
        -> ContainerRunRequest
    {
        engine.name == "hvf" ? request : try ContainerCacheOptions.admitted(request, runtime: engine.name)
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        try await owner(request.containerID).containers.exec(request)
    }

    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        try await owner(request.containerID).containers.execDetailed(request)
    }

    public func execAttached(_ request: ContainerExecRequest, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle)
        async throws -> Int32
    {
        try Task.checkCancellation()
        let engine = await owner(request.containerID)
        try Task.checkCancellation()
        return try await engine.containers.execAttached(request, stdin: stdin, stdout: stdout, stderr: stderr)
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
        var merged = Micropod_V1_StatsSnapshot()
        do {
            if registry.skipsApple(installed: apple.isInstalled) {
                merged.sampledAt = ISO8601DateFormatter().string(from: Date())
            } else {
                merged = try await apple.stats?.snapshot(ids: ids) ?? merged
            }
        } catch {
            // As in `list`: a stopped Apple runtime is skipped when Apple is
            // not the default; any other Apple failure still surfaces.
            guard registry.defaultName != "apple", Self.appleRuntimeIsDown(error) else { throw error }
            merged.sampledAt = ISO8601DateFormatter().string(from: Date())
        }
        for engine in registry.extraEngines() {
            guard let sampler = engine.stats, let snap = try? await sampler.snapshot(ids: ids) else { continue }
            merged.containers += snap.containers
        }
        return merged
    }
}

extension RuntimeServices {
    /// These services with containers/logs/stats routed across every
    /// enabled engine. `volumes`, the XPC client and exit codes stay
    /// apple's: surfaces route volumes and images with `VolumeRouter` and
    /// `ImageRouter` over `router?.registry`.
    public func routed(through registry: EngineRegistry = .shared) -> RuntimeServices {
        guard router == nil else { return self }
        let router = RuntimeRouter(apple: AppleEngine(services: self), registry: registry)
        return RuntimeServices(
            kind: kind, containers: router, logs: router, stats: router, volumes: volumes,
            api: api, health: health, exitCodes: exitCodes, followsManagedSelection: followsManagedSelection)
    }

    /// The router when these services are routed, for engine management.
    public var router: RuntimeRouter? { containers as? RuntimeRouter }
}
