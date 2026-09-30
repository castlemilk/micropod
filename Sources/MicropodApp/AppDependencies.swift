import Foundation
import MicropodCore
import MicropodRuntime

/// Central factory for app dependencies (storagesentry pattern).
@MainActor
public final class AppDependencies {
    public static let shared = AppDependencies()

    public let client: ContainerCLIClient
    public let system: SystemService
    public private(set) var containers: any ContainerServing
    public let images: ImageService
    public let volumes: VolumeService
    public let networks: NetworkService
    public let registries: RegistryService
    public private(set) var statsSampler: any StatsSampling
    public private(set) var logStreamer: any LogStreaming
    public let terminal: TerminalService
    public let compose: ComposeService
    public let machine: MachineService
    /// The resolved runtime backend (cli until `useNativeBackend` resolves).
    public private(set) var runtime: RuntimeServices?
    /// Keeps `runtime` current after start-up (see `refreshBackendIfNeeded`).
    private var holder: RuntimeHolder?

    private convenience init() {
        // Env override so the app can be validated against a mock CLI.
        let cliPath =
            ProcessInfo.processInfo.environment["MICROPOD_CONTAINER_CLI_PATH"]
            ?? "/usr/local/bin/container"
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: cliPath))
        self.init(client: client)
    }

    public init(client: ContainerCLIClient) {
        self.client = client
        self.system = SystemService(client: client)
        self.containers = ContainerService(client: client)
        self.images = ImageService(client: client)
        self.volumes = VolumeService(client: client)
        self.networks = NetworkService(client: client)
        self.registries = RegistryService(client: client)
        self.statsSampler = StatsSampler(client: client)
        self.logStreamer = LogStreamer(client: client)
        self.terminal = TerminalService(client: client)
        self.compose = ComposeService(client: client)
        self.machine = MachineService(client: client)
    }

    /// Swaps container/log/stats services to the native apiserver backend
    /// when the `ping` handshake succeeds, and keeps the choice current from
    /// then on (`refreshBackendIfNeeded`). Safe to call once at app start;
    /// views built afterwards get the fast path.
    public func useNativeBackend() async {
        let client = self.client
        await useBackend { pingTimeout in
            await RuntimeBackendResolver.resolve(client: client, pingTimeout: pingTimeout)
        }
    }

    /// `useNativeBackend` with the resolver injected (tests script it).
    func useBackend(resolve: @escaping @Sendable (_ pingTimeout: Duration) async -> RuntimeServices) async {
        // Launch allows launchd time to activate a cold apiserver; later
        // re-resolutions sit on the poll path, so their ping stays short.
        let initial = await resolve(.seconds(10))
        holder = RuntimeHolder(initial: initial, resolve: { await resolve(.seconds(2)) })
        adopt(initial)
    }

    /// Replaces the backend when the current one can improve: the CLI once
    /// the apiserver answers, or a native backend whose XPC connection was
    /// invalidated — the apiserver was unregistered and re-registered by
    /// `container system stop/start`, a watchdog restart or a runtime update.
    /// Without this the app held the dead connection, every list, stats and
    /// logs call failing, until it was relaunched. A no-op while the backend
    /// is healthy; the holder re-resolves at most every 10 s unless `force`d.
    /// Returns true when the services were swapped.
    @discardableResult
    public func refreshBackendIfNeeded(force: Bool = false) async -> Bool {
        guard let holder else { return false }
        return adopt(await holder.refreshIfNeeded(force: force))
    }

    @discardableResult
    private func adopt(_ services: RuntimeServices) -> Bool {
        if let current = runtime, current.kind == services.kind, current.api === services.api {
            return false
        }
        runtime = services
        containers = services.containers
        statsSampler = services.stats
        logStreamer = services.logs
        return true
    }
}

public enum UserDefaultsKeys {
    public static let pollIntervalContainers = "pollIntervalContainers"
    public static let pollIntervalStats = "pollIntervalStats"
    public static let showMenuBarCount = "showMenuBarCount"
    public static let terminalShell = "terminalShell"
    public static let onboardingComplete = "onboardingComplete"
    public static let lastTab = "lastTab"
    public static let notifyPulls = "notifyPulls"
    public static let notifyBuilds = "notifyBuilds"
    public static let notifyCompose = "notifyCompose"
    public static let notifyPrune = "notifyPrune"
    public static let notifyKernel = "notifyKernel"
    public static let agentDockerShim = "agentDockerShim"
    public static let agentAPIServer = "agentAPIServer"
    public static let agentSharedFS = "agentSharedFS"
    /// Bool; missing means enabled. False stops the app from bouncing a
    /// runtime whose liveness probe keeps failing (it still reports it
    /// wedged): set it on a machine where the runtime runs other
    /// software's work, such as a CI rig.
    public static let runtimeAutoHeal = "runtimeAutoHeal"
}
