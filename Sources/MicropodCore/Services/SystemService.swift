import Foundation

public protocol SystemServing: Sendable {
    /// `container system status`, including the CLI version.
    func status() async throws -> Micropod_V1_SystemStatus
    func start() async throws
    /// Like `start()` but lets the CLI install the recommended kernel if the
    /// local one is missing. Used by the runtime supervisor so the daemon
    /// always comes back without requiring user interaction.
    func startWithKernelInstall() async throws
    func stop() async throws
    func diskUsage() async throws -> Micropod_V1_DiskUsage
    /// Streaming output of `container system kernel set --recommended`.
    func installRecommendedKernel() -> AsyncThrowingStream<String, Error>
    /// Raw system service logs (`container system logs --last`).
    func systemLogs(last: String) async throws -> String
}

public actor SystemService: SystemServing {
    private let client: ContainerCLIClient
    private var cachedCLIVersion: String?

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func status() async throws -> Micropod_V1_SystemStatus {
        let output = try await client.run(ContainerCommandFactory.systemStatus(), timeout: .seconds(15))
        let response = try MicropodJSON.decode(
            SystemStatusResponse.self, from: Data(output.utf8), context: "system status")
        let version = try await cliVersion()
        return ModelMapper.systemStatus(from: response, cliVersion: version)
    }

    public func cliVersion() async throws -> String {
        if let cached = cachedCLIVersion { return cached }
        let output = try await client.run(ContainerCommandFactory.systemVersion(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(
            SystemVersionEntry.self, from: Data(output.utf8), context: "system version")
        let cli = entries.first { $0.appName == "container" } ?? entries.first
        let version = cli?.version ?? "unknown"
        cachedCLIVersion = version
        return version
    }

    public func start() async throws {
        _ = try await client.run(ContainerCommandFactory.systemStart(), timeout: .seconds(60))
    }

    public func startWithKernelInstall() async throws {
        // No --disable-kernel-install flag: the CLI installs the recommended
        // kernel if the local one is missing or stale.
        _ = try await client.run(
            ContainerCommand(arguments: ["system", "start"], stdinData: nil),
            timeout: .seconds(180))
    }

    public func stop() async throws {
        _ = try await client.run(ContainerCommandFactory.systemStop(), timeout: .seconds(60))
    }

    public func diskUsage() async throws -> Micropod_V1_DiskUsage {
        let output = try await client.run(ContainerCommandFactory.systemDF(), timeout: .seconds(15))
        let response = try MicropodJSON.decode(DiskUsageResponse.self, from: Data(output.utf8), context: "system df")
        return ModelMapper.diskUsage(from: response)
    }

    public nonisolated func installRecommendedKernel() -> AsyncThrowingStream<String, Error> {
        let command = ContainerCommandFactory.systemKernelSetRecommended()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in client.stream(command) {
                        if let text = String(data: chunk, encoding: .utf8) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func systemLogs(last: String = "5m") async throws -> String {
        try await client.run(ContainerCommandFactory.systemLogs(last: last), timeout: .seconds(15))
    }
}
