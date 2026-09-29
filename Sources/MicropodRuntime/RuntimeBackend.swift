import Foundation
import MicropodCore

/// Backend selection: direct `container-apiserver` XPC calls vs the
/// `container` CLI subprocess.
public enum RuntimeBackendKind: String, Sendable {
    /// One persistent XPC connection; each op is a single round trip.
    case native
    /// Per-call `container` process spawns (the historic path).
    case cli
}

/// The resolved set of runtime-facing services.
public struct RuntimeServices: Sendable {
    public let kind: RuntimeBackendKind
    public let containers: any ContainerServing
    public let logs: any LogStreaming
    public let stats: any StatsSampling
    /// Volume list/create/delete/clone/commit — XPC routes when native
    /// (no process spawns on the cache hot path), the CLI otherwise.
    public let volumes: any VolumeServing
    /// Present when the native backend is active — the XPC client for
    /// guest/vsock consumers (vminitd, the API bridge endpoint).
    public let api: APIServerClient?
    /// Apiserver identity from the `ping` handshake, when known.
    public let health: APIServerHealth?
    /// Exit codes recorded by the native backend's `containerWait` waiters —
    /// what `WaitContainer`/`GetContainer` read. Nil on the CLI backend,
    /// which has no exit-code source (`Container.exit_code` stays empty and
    /// `WaitContainer` answers `known: false`).
    public let exitCodes: ExitCodeRegistry?

    /// True when the apiserver reported a version we've verified the
    /// protocol against. Unknown versions still work when the route set is
    /// additive, but callers may choose to be conservative.
    public var versionSupported: Bool {
        guard let health, let version = health.semver else { return false }
        return Self.supportedVersions.contains(version) || version.hasPrefix("1.3.")
    }

    /// Versions the wire protocol was verified against.
    public static let supportedVersions: Set<String> = ["1.3.1"]
}

/// Resolves `RuntimeServices` from the environment.
///
/// `MICROPOD_RUNTIME`:
///   - `cli`    → force the CLI backend (also used by the mock-CLI tests)
///   - `native` → force native, fail if the apiserver is unreachable
///   - unset/`auto` → native when the `ping` handshake succeeds, else CLI
///
/// `pingTimeout` bounds the handshake. Start-up allows launchd to activate a
/// cold apiserver; a re-resolution on a request path (`RuntimeHolder`)
/// passes a short one so the caller is never held for long.
public enum RuntimeBackendResolver {
    public static func resolve(
        client: ContainerCLIClient,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pingTimeout: Duration = .seconds(10)
    ) async -> RuntimeServices {
        // Every engine (apple, docker, sandbox) behind one ContainerServing;
        // `MICROPOD_ENGINES=apple` opts out of routing entirely.
        let apple = await resolveApple(client: client, environment: environment, pingTimeout: pingTimeout)
        return environment["MICROPOD_ENGINES"] == "apple" ? apple : apple.routed()
    }

    /// The apple engine alone: native XPC or `container` CLI transport.
    public static func resolveApple(
        client: ContainerCLIClient,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pingTimeout: Duration = .seconds(10)
    ) async -> RuntimeServices {
        let mode = environment["MICROPOD_RUNTIME"] ?? "auto"
        let cliContainers = ContainerService(client: client)
        let cliLogs = LogStreamer(client: client)
        let cliStats = StatsSampler(client: client)
        let cliVolumes = VolumeService(client: client)

        func cliServices(health: APIServerHealth? = nil) -> RuntimeServices {
            RuntimeServices(
                kind: .cli,
                containers: cliContainers,
                logs: cliLogs,
                stats: cliStats,
                volumes: cliVolumes,
                api: nil,
                health: health,
                exitCodes: nil
            )
        }

        guard mode != "cli" else { return cliServices() }

        // An explicit CLI path means the caller deliberately chose a
        // container binary (mock CLIs in tests, custom installs) — auto
        // mode must not silently bypass it for the native path. Only an
        // explicit MICROPOD_RUNTIME=native overrides that choice.
        if mode == "auto", environment["MICROPOD_CONTAINER_CLI_PATH"] != nil {
            return cliServices()
        }

        let api = APIServerClient()
        do {
            let health = try await api.ping(timeout: pingTimeout)
            let exitCodes = ExitCodeRegistry()
            let services = RuntimeServices(
                kind: .native,
                containers: NativeContainerService(api: api, cli: cliContainers, exitCodes: exitCodes),
                logs: NativeLogStreamer(api: api, exitCodes: exitCodes),
                stats: NativeStatsSampler(api: api),
                volumes: NativeVolumeService(api: api, cli: cliVolumes),
                api: api,
                health: health,
                exitCodes: exitCodes
            )
            guard services.versionSupported else {
                // The wire DTOs are versioned by us, not on the wire — an
                // unverified apiserver version is a correctness risk, so
                // auto stays on CLI. Explicit `native` is an opt-in and
                // proceeds with a warning.
                if mode == "native" {
                    let notice =
                        "micropod: apiserver version \(health.apiServerVersion) is unverified "
                        + "(supported: \(RuntimeServices.supportedVersions.sorted().joined(separator: ", ")) or 1.3.x); proceeding anyway\n"
                    FileHandle.standardError.write(Data(notice.utf8))
                    return services
                }
                return cliServices(health: health)
            }
            return services
        } catch {
            if mode == "native" {
                let notice =
                    "micropod: MICROPOD_RUNTIME=native but apiserver ping failed "
                    + "(\(error.localizedDescription)); falling back to CLI\n"
                FileHandle.standardError.write(Data(notice.utf8))
            }
            return cliServices()
        }
    }
}

/// The live runtime backend behind a long-running server (`MicropodAPI`).
///
/// The backend is resolved once at start-up. When that lands on the CLI —
/// the runtime was down, or its apiserver version unverified — callers
/// re-resolve lazily through `refreshIfNeeded` at natural liveness points
/// (`Ping`, `GetSystem`) and after transport errors, and the holder swaps to
/// native as soon as the apiserver answers. Attempts are rate-limited to one
/// per `minInterval` (the start-up resolution counts) unless forced, and
/// concurrent callers join the attempt in flight instead of starting another.
///
/// A live native backend is final. One whose XPC connection was invalidated
/// (the apiserver was unregistered — `container system stop`) never recovers
/// on its own, so it is re-resolved like a CLI backend and replaced by
/// whatever the resolver finds: a fresh native backend, or the CLI while the
/// runtime is down (which then swaps back once it is up).
///
/// A swap replaces the whole `RuntimeServices` value: a caller that read
/// `current` keeps one consistent set (containers, logs, stats, volumes, XPC
/// client, exit codes) for the rest of its request.
public actor RuntimeHolder {
    private var services: RuntimeServices
    private let resolve: @Sendable () async -> RuntimeServices
    private let minInterval: Duration
    /// Start of the most recent resolution attempt.
    private var lastAttempt: ContinuousClock.Instant
    private var inFlight: Task<RuntimeServices, Never>?

    public init(
        initial: RuntimeServices,
        resolve: @escaping @Sendable () async -> RuntimeServices,
        minInterval: Duration = .seconds(10)
    ) {
        self.services = initial
        self.resolve = resolve
        self.minInterval = minInterval
        self.lastAttempt = .now
    }

    public var current: RuntimeServices { services }

    /// Re-resolves when the current backend can still be replaced (CLI, or
    /// native with an invalidated connection) and `minInterval` has elapsed
    /// since the last attempt — or immediately when `force`d — then swaps
    /// atomically. Returns the services to use from here on.
    public func refreshIfNeeded(force: Bool = false) async -> RuntimeServices {
        if let inFlight {
            adopt(await inFlight.value)
            return services
        }
        guard Self.isReplaceable(services) else { return services }
        let now = ContinuousClock.now
        guard force || now - lastAttempt >= minInterval else { return services }
        lastAttempt = now
        let resolve = self.resolve
        let attempt = Task { await resolve() }
        inFlight = attempt
        let resolved = await attempt.value
        inFlight = nil
        adopt(resolved)
        return services
    }

    /// CLI may still become native; native is final while its connection lives.
    private static func isReplaceable(_ services: RuntimeServices) -> Bool {
        services.kind == .cli || services.api?.isInvalidated == true
    }

    /// Swaps to `resolved` when it upgrades CLI to native or replaces a dead
    /// native backend. A CLI result for a CLI backend keeps the current
    /// services (and their state). Idempotent, so every caller that awaited
    /// the same attempt may apply it.
    private func adopt(_ resolved: RuntimeServices) {
        guard Self.isReplaceable(services),
            resolved.kind == .native || services.kind == .native
        else { return }
        let reason =
            services.kind == .native
            ? "apiserver connection invalidated"
            : "apiserver reachable"
        let notice = "micropod: runtime backend \(services.kind.rawValue) -> \(resolved.kind.rawValue) (\(reason))\n"
        FileHandle.standardError.write(Data(notice.utf8))
        services = resolved
    }
}
