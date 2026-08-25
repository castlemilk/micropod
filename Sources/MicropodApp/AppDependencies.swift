import Foundation
import MicropodCore

/// Central factory for app dependencies (storagesentry pattern).
@MainActor
public final class AppDependencies {
    public static let shared = AppDependencies()

    public let client: ContainerCLIClient
    public let system: SystemService
    public let containers: ContainerService
    public let images: ImageService
    public let volumes: VolumeService
    public let networks: NetworkService
    public let registries: RegistryService
    public let statsSampler: StatsSampler
    public let logStreamer: LogStreamer
    public let terminal: TerminalService
    public let compose: ComposeService
    public let machine: MachineService

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
}
