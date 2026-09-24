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
    /// when the `ping` handshake succeeds. Safe to call once at app start;
    /// views built afterwards get the fast path.
    public func useNativeBackend() async {
        let resolved = await RuntimeBackendResolver.resolve(client: client)
        guard resolved.kind == .native else { return }
        self.runtime = resolved
        self.containers = resolved.containers
        self.statsSampler = resolved.stats
        self.logStreamer = resolved.logs
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
}
