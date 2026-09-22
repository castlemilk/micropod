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
    /// Fast liveness probe for the self-healing supervisor: `container list`
    /// through the apiserver with a short ceiling. `system status` can keep
    /// answering while the container path is wedged (e.g. a crash-looping
    /// network plugin holds a pending op that blocks every container call) —
    /// this exercises the path that actually breaks.
    func livenessProbe() async throws
    /// Streaming output of `container system kernel set --recommended`.
    func installRecommendedKernel() -> AsyncThrowingStream<String, Error>
    /// Raw system service logs (`container system logs --last`).
    func systemLogs(last: String) async throws -> String
}

/// Reference-boxed CLI-version cache shared by all copies of the
/// (value-type) service. All locking happens in synchronous helpers — Swift 6
/// forbids `NSLock` in async contexts, and the lock never spans an await.
private final class CLIVersionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ version: String) {
        lock.lock()
        defer { lock.unlock() }
        value = version
    }
}

public struct SystemService: SystemServing {
    private let client: ContainerCLIClient
    /// The CLI version never changes under a running process, so
    /// cache-on-first-use is safe. A struct (not an actor) so concurrent
    /// status/df/version calls run their CLIs in parallel.
    private let versionCache = CLIVersionCache()

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func status() async throws -> Micropod_V1_SystemStatus {
        // Independent CLIs — fetch concurrently (the version is cached after
        // the first call, so steady-state this is a single round-trip).
        async let statusOutput = client.run(
            ContainerCommandFactory.systemStatus(), timeout: .seconds(15))
        async let version = cliVersion()
        let (output, cli) = try await (statusOutput, version)
        let response = try MicropodJSON.decode(
            SystemStatusResponse.self, from: Data(output.utf8), context: "system status")
        return ModelMapper.systemStatus(from: response, cliVersion: cli)
    }

    public func cliVersion() async throws -> String {
        if let cached = versionCache.get() { return cached }
        let output = try await client.run(ContainerCommandFactory.systemVersion(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(
            SystemVersionEntry.self, from: Data(output.utf8), context: "system version")
        let cli = entries.first { $0.appName == "container" } ?? entries.first
        let version = cli?.version ?? "unknown"
        versionCache.set(version)
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

    public func livenessProbe() async throws {
        _ = try await client.run(
            ContainerCommandFactory.listContainers(all: false), timeout: .seconds(8))
    }

    public func installRecommendedKernel() -> AsyncThrowingStream<String, Error> {
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
