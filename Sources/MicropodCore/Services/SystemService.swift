import Darwin
import Foundation

public protocol SystemServing: Sendable {
    /// `container system status`, including the CLI version.
    func status() async throws -> Micropod_V1_SystemStatus
    func start() async throws
    /// Like `start()` but lets the CLI install the recommended kernel if the
    /// local one is missing. Used by explicit operator restart/recovery;
    /// automatic startup does not install a kernel.
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
    private var value: (identity: CLIExecutableIdentity, version: String)?

    func get(for identity: CLIExecutableIdentity) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value?.identity == identity ? value?.version : nil
    }

    func set(_ version: String, for identity: CLIExecutableIdentity) {
        lock.lock()
        defer { lock.unlock() }
        value = (identity, version)
    }
}

/// Includes inode and ctime so atomic replacement, symlink retargeting and
/// in-place upgrades invalidate the cache even when mtime was preserved.
private struct CLIExecutableIdentity: Equatable {
    let path: String
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    static func read(_ url: URL) -> Self? {
        var metadata = stat()
        guard
            url.withUnsafeFileSystemRepresentation({ path in
                guard let path else { return false }
                return stat(path, &metadata) == 0
            })
        else { return nil }
        return Self(
            path: url.resolvingSymlinksInPath().path, device: metadata.st_dev,
            inode: metadata.st_ino, size: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec, modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
            changedSeconds: metadata.st_ctimespec.tv_sec, changedNanoseconds: metadata.st_ctimespec.tv_nsec)
    }
}

public struct SystemService: SystemServing {
    private let client: ContainerCLIClient
    /// Reuse a version only while the installed executable is unchanged.
    private let versionCache = CLIVersionCache()

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func dependencyStatus(
        backend: String = "cli",
        nativeReadiness: @Sendable () async -> RuntimeDependencyStatus.NativeReadiness = { .unobserved }
    ) async -> RuntimeDependencyStatus {
        let path = client.executableURL.path
        let available = client.isAvailable()
        guard available, RuntimeDependencyStatus.hostSupported else {
            return RuntimeDependencyStatus(cliAvailable: available, cliPath: path, status: nil, backend: backend)
        }
        do {
            let status = try await status()
            let native = status.status == "running" ? await nativeReadiness() : .unobserved
            return RuntimeDependencyStatus(
                cliAvailable: true, cliPath: path, status: status, backend: backend, native: native)
        } catch {
            // Do not expose raw process output/environment in rig diagnostics.
            return RuntimeDependencyStatus(
                cliAvailable: true, cliPath: path, status: nil, statusFailed: true, backend: backend)
        }
    }

    /// A stopped runtime is a *status* (`status == "stopped"`), never an
    /// error: `container system status` exits 1 when the apiserver is down,
    /// and callers (health ticks, `Ping`, `GetSystem`) must be able to tell
    /// "runtime stopped" from "CLI broken" without parsing exceptions.
    public func status() async throws -> Micropod_V1_SystemStatus {
        // Independent CLIs — fetch concurrently (the version is cached after
        // the first call, so steady-state this is a single round-trip).
        async let version = cliVersion()
        // Exit 1 is normal for a stopped service, but its JSON must actually
        // say that. An empty/error response must never trigger auto-start.
        let output = try await client.run(
            ContainerCommandFactory.systemStatus(), timeout: .seconds(15), acceptingExitCodes: [0, 1])
        let cli = try await version
        let response = try MicropodJSON.decode(
            SystemStatusResponse.self, from: Data(output.utf8), context: "system status")
        var status = ModelMapper.systemStatus(from: response, cliVersion: cli)
        if Self.stoppedStatusValues.contains(status.status) {
            status.status = "stopped"
        }
        return status
    }

    /// The CLI's own words for a down apiserver, normalised to "stopped" so
    /// consumers compare against one value.
    static let stoppedStatusValues: Set<String> = ["unregistered", "not running"]

    public func cliVersion() async throws -> String {
        let executable = client.executableURL
        let identity = CLIExecutableIdentity.read(executable)
        if let identity, let cached = versionCache.get(for: identity) { return cached }
        let output = try await ContainerCLIClient(executableURL: executable).run(
            ContainerCommandFactory.systemVersion(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(
            SystemVersionEntry.self, from: Data(output.utf8), context: "system version")
        let cli = entries.first { $0.appName == "container" } ?? entries.first
        let version = cli?.version ?? "unknown"
        if let identity, CLIExecutableIdentity.read(executable) == identity {
            versionCache.set(version, for: identity)
        }
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
