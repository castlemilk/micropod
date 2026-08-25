import AppKit
import MicropodCore
import Observation
import SwiftUI

// MARK: - Storage

/// One measured bucket of the runtime's on-disk footprint (macOS app support
/// directory). Sizes come from `du`, not estimates.
struct StorageBucket: Identifiable, Equatable {
    let name: String
    let path: String
    let sizeBytes: Int64
    let explanation: String
    var id: String { name }
}

// MARK: - Activity feed

/// One aggregate resource sample across all running containers.
/// No per-sample id: the ring is append-only and charted by timestamp, so a
/// UUID would be 16 bytes of pure overhead per sample.
struct ResourceSample: Equatable {
    let timestamp: Date
    let cpuPercent: Double
    let memoryUsedBytes: UInt64
    let memoryLimitBytes: UInt64
    let networkRxBytes: UInt64
    let networkTxBytes: UInt64
}

struct ActivityEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String
    let level: Level

    enum Level: Equatable {
        case info, success, error
    }

    init(
        id: UUID = UUID(), timestamp: Date = Date(), category: String, message: String,
        level: Level = .info
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.level = level
    }
}

func launchedContainerID(
    runOutput: String,
    request: ContainerRunRequest,
    previousIDs: Set<String>,
    refreshedContainers: [Micropod_V1_Container]
) -> String? {
    let requestedName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let requestedName, !requestedName.isEmpty,
        refreshedContainers.contains(where: { $0.id == requestedName })
    {
        return requestedName
    }

    let output = runOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    if request.detach, refreshedContainers.contains(where: { $0.id == output }) {
        return output
    }

    var candidates = refreshedContainers.filter { !previousIDs.contains($0.id) }
    let matchingImage = candidates.filter { $0.image == request.image }
    if !matchingImage.isEmpty {
        candidates = matchingImage
    }
    if let candidate = candidates.sorted(by: { lhs, rhs in
        let left = parseDate(lhs.createdAt) ?? .distantPast
        let right = parseDate(rhs.createdAt) ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }).first {
        return candidate.id
    }

    return request.detach && !output.isEmpty ? output : nil
}

@MainActor
@Observable
final class AppStore {
    // MARK: - Dependencies

    let dependencies: AppDependencies

    // MARK: - Navigation

    enum ActiveTab: String, CaseIterable, Identifiable {
        case dashboard, containers, images, volumes, networks, registries, build, compose, environments, storage,
            settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: "Dashboard"
            case .containers: "Containers"
            case .images: "Images"
            case .volumes: "Volumes"
            case .networks: "Networks"
            case .registries: "Registries"
            case .build: "Build"
            case .compose: "Compose"
            case .environments: "Environments"
            case .storage: "Storage"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.50percent"
            case .containers: "shippingbox"
            case .images: "photo.stack"
            case .volumes: "externaldrive"
            case .networks: "network"
            case .registries: "globe"
            case .build: "hammer"
            case .compose: "square.stack.3d.up"
            case .environments: "folder"
            case .storage: "internaldrive"
            case .settings: "gearshape"
            }
        }
    }

    var activeTab: ActiveTab = .dashboard
    var selectedContainerID: String?
    var selectedImageID: String?
    var selectedVolumeID: String?
    var selectedNetworkID: String?
    var showCommandPalette = false
    /// One-shot flags set by the command palette so views open their sheets.
    var pendingRunSheet = false
    var pendingPullSheet = false
    var appearance: Appearance = .system

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    // MARK: - Activity

    private(set) var activity: [ActivityEntry] = []
    private let maxActivityEntries = 200

    func recordActivity(_ category: String, _ message: String, level: ActivityEntry.Level = .info) {
        activity.append(ActivityEntry(category: category, message: message, level: level))
        if activity.count > maxActivityEntries {
            activity.removeFirst(activity.count - maxActivityEntries)
        }
        MicropodNotifier.shared.maybePost(category: category, message: message, level: level)
    }

    func recentActivity(limit: Int) -> [ActivityEntry] {
        guard limit > 0 else { return [] }
        return Array(activity.suffix(limit).reversed())
    }

    // MARK: - Runtime state

    var clientAvailable = false
    var systemStatus: Micropod_V1_SystemStatus?
    var systemStatusError: String?
    var isStartingRuntime = false
    var isInstallingKernel = false
    var kernelInstallProgress: [String] = []
    /// 0...1 when the CLI reports a fraction; nil while indeterminate.
    var kernelInstallFraction: Double?
    var kernelInstallComplete = false
    var kernelInstallError: String?
    var onboardingComplete = UserDefaults.standard.bool(forKey: UserDefaultsKeys.onboardingComplete)

    // MARK: - Resource state

    var containers: [Micropod_V1_Container] = []
    var images: [Micropod_V1_Image] = []
    private(set) var hasLoadedImages = false
    var volumes: [Micropod_V1_Volume] = []
    var networks: [Micropod_V1_Network] = []
    var registries: [Micropod_V1_RegistryLogin] = []
    var diskUsage: Micropod_V1_DiskUsage?
    var statsSnapshot: Micropod_V1_StatsSnapshot?
    /// id → stats for the current snapshot; O(1) lookups for rows/sorts
    /// (the linear `containers.first {}` scan was per-row and per-comparison).
    private(set) var statsByID: [String: Micropod_V1_ContainerStats] = [:]
    var machines: [MachineEntry] = []
    var systemProperties: SystemPropertyListResponse?
    var machineError: String?
    /// Rolling system-wide resource samples for the dashboard charts.
    private(set) var statsHistory: [ResourceSample] = []
    /// Measured runtime storage buckets (app support dir), refreshed on demand.
    private(set) var storageBuckets: [StorageBucket] = []
    private(set) var storageTotalBytes: Int64 = 0
    var isMeasuringStorage = false
    var lastRefreshError: String?

    // MARK: - Derived

    var runningCount: Int { containers.filter { $0.state == "running" }.count }
    var agentWorkloadCount: Int {
        containers.count { WorkloadMetadata(labels: $0.labels).isAgent }
    }
    var localImageCount: Int { images.count }
    var localImageBytes: UInt64 {
        images.reduce(0) { total, image in
            let (sum, overflow) = total.addingReportingOverflow(image.sizeBytes)
            return overflow ? UInt64.max : sum
        }
    }
    var isRuntimeRunning: Bool { systemStatus?.status == "running" }

    // MARK: - Polling

    @ObservationIgnored private var containersTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    /// Background supervisor that keeps the container runtime running.
    /// On bootstrap it auto-starts if stopped; on every tick it restarts the
    /// runtime when it sees the status go from running to stopped or a CLI
    /// failure that smells like "runtime down". Respects `userStoppedUntil`
    /// so an explicit user Stop action is honored for ~2 minutes.
    @ObservationIgnored private var runtimeSupervisorTask: Task<Void, Never>?
    @ObservationIgnored private var lastSupervisedRuntimeRunning = false
    @ObservationIgnored private var consecutiveStartFailures = 0
    @ObservationIgnored private var userStoppedUntil: Date?
    @ObservationIgnored private var wasVisible = false

    init(dependencies: AppDependencies = AppDependencies.shared) {
        self.dependencies = dependencies
        // Restore the last visited tab (macOS convention: return to where
        // you left off).
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastTab),
            let tab = ActiveTab(rawValue: raw)
        {
            activeTab = tab
        }
    }

    func bootstrap() {
        guard containersTask == nil else { return }
        clientAvailable = dependencies.client.isAvailable()
        Task {
            await refreshSystemStatus()
            // Auto-start the daemon right away — the supervisor takes its
            // first tick 5s later, but we don't want to sit on a stopped
            // runtime in that gap.
            if clientAvailable, !isRuntimeRunning {
                await attemptRuntimeStart(reason: "auto-start on launch")
            }
            await refreshImages()
        }
        startPollers()
        startRuntimeSupervisor()
    }

    func stopPollers() {
        containersTask?.cancel()
        containersTask = nil
        statsTask?.cancel()
        statsTask = nil
        runtimeSupervisorTask?.cancel()
        runtimeSupervisorTask = nil
    }

    /// Ensures the Apple container runtime is always running while the app is
    /// alive. Polls system status every 30s; if it observes running → stopped
    /// or a CLI error that smells like "runtime down", it kicks off
    /// `startRuntime()`. On repeated failures the supervisor backs off
    /// exponentially up to 5 minutes so it doesn't thrash.
    private func startRuntimeSupervisor() {
        runtimeSupervisorTask?.cancel()
        runtimeSupervisorTask = Task { [weak self] in
            // Initial pass: wait for the first status to land before deciding.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self else { return }
                await self.runRuntimeSupervisorTick()
                let backoff = self.supervisorBackoff()
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }

    private func supervisorBackoff() -> Double {
        // 20s normal; up to 90s after repeated failures (kernel download
        // can take a minute; don't hammer the CLI).
        let n = consecutiveStartFailures
        if n <= 0 { return 20 }
        let seconds = min(90.0, 20.0 * pow(2.0, Double(min(n, 3))))
        return seconds
    }

    private func runRuntimeSupervisorTick() async {
        defer { lastSupervisedRuntimeRunning = isRuntimeRunning }

        // Always refresh status first — the containers/stats pollers don't
        // touch systemStatus, so without this the supervisor would reason
        // on stale data after any external daemon change.
        await refreshSystemStatus()

        guard clientAvailable else { return }

        // Honor the user's explicit Stop action for a short cooldown.
        if let until = userStoppedUntil, until > Date() {
            return
        }
        userStoppedUntil = nil

        // If we observe the daemon running now but it was stopped last tick,
        // record a fresh edge; otherwise just ensure it stays up.
        let err = systemStatusError?.lowercased() ?? ""
        if !isRuntimeRunning, !err.isEmpty {
            // Common CLI messages: the runtime VM isn't registered / started.
            if err.contains("ensure container system service has been started")
                || err.contains("xpc connection")
                || err.contains("system is not running")
                || err.contains("unregistered")
                || err.contains("connection invalid")
            {
                await attemptRuntimeStart(reason: "auto-restart: status error")
                return
            }
        }

        if isRuntimeRunning {
            lastSupervisedRuntimeRunning = true
            consecutiveStartFailures = 0
            return
        }
        // Not running and no obvious "restart" error: try once anyway.
        await attemptRuntimeStart(reason: "auto-start: runtime not running")
    }

    private func attemptRuntimeStart(reason: String) async {
        recordActivity("system", "Runtime supervisor: \(reason) — starting…", level: .info)
        isStartingRuntime = true
        defer { isStartingRuntime = false }
        do {
            // Use the kernel-installing variant so the daemon always comes
            // back, even if the local kernel image was lost. CLI is fast when
            // the kernel is already present.
            try await dependencies.system.startWithKernelInstall()
            consecutiveStartFailures = 0
            lastSupervisedRuntimeRunning = true
            recordActivity("system", "Runtime supervisor: started daemon", level: .success)
            await refreshSystemStatus()
            // Refresh dependents without blocking the supervisor — these
            // can hang on the wedged CLI and we don't want to delay the
            // next supervisor tick.
            Task { await refreshContainers() }
        } catch {
            consecutiveStartFailures += 1
            recordActivity(
                "system",
                "Runtime supervisor: start failed (\(consecutiveStartFailures)x): \(error.localizedDescription)",
                level: .error)
        }
    }

    /// Adjusts polling intensity based on whether the main window is visible.
    func setMainWindowVisible(_ visible: Bool) {
        wasVisible = visible
        restartStatsPolling()
    }

    private func startPollers() {
        let containerInterval = UserDefaults.standard.double(forKey: UserDefaultsKeys.pollIntervalContainers)
            .nonzeroOr(3.0)
        let hiddenInterval = max(containerInterval, 30.0)
        containersTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.wasVisible {
                    // Refresh system status first so the per-resource polls
                    // don't trip over a stopped daemon with a stale "running"
                    // status cached in `systemStatus`.
                    await self.refreshSystemStatus()
                    await self.refreshContainers()
                    try? await Task.sleep(for: .seconds(containerInterval))
                } else {
                    try? await Task.sleep(for: .seconds(hiddenInterval))
                }
            }
        }
        restartStatsPolling()
    }

    private func restartStatsPolling() {
        statsTask?.cancel()
        let interval = UserDefaults.standard.double(forKey: UserDefaultsKeys.pollIntervalStats)
        let hiddenInterval = interval.nonzeroOr(30.0)
        let visibleInterval = min(hiddenInterval, 5.0)
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.wasVisible {
                    await self.refreshSystemStatus()
                    await self.refreshStats()
                    try? await Task.sleep(for: .seconds(visibleInterval))
                } else {
                    try? await Task.sleep(for: .seconds(hiddenInterval))
                }
            }
        }
    }

    // MARK: - System

    func refreshSystemStatus() async {
        // Re-check on every refresh so installing/removing the CLI mid-session
        // is picked up without relaunching the app.
        clientAvailable = dependencies.client.isAvailable()
        do {
            systemStatus = try await dependencies.system.status()
            systemStatusError = nil
            // The kernel banner is stale when the kernel is already on disk
            // (e.g. installed before the app, or by an earlier session).
            if !onboardingComplete, isKernelInstalled {
                onboardingComplete = true
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.onboardingComplete)
            }
        } catch {
            // CRITICAL: clear the stale cached status so the supervisor
            // detects the daemon has gone down. Without this, `isRuntimeRunning`
            // returns true from the cached "running" value and the supervisor
            // never tries to restart.
            systemStatus = nil
            systemStatusError = error.localizedDescription
        }
    }

    func startRuntime() async {
        isStartingRuntime = true
        defer { isStartingRuntime = false }
        do {
            try await dependencies.system.start()
            recordActivity("system", "Runtime started", level: .success)
            await refreshSystemStatus()
        } catch {
            recordActivity("system", "Failed to start runtime: \(error.localizedDescription)", level: .error)
            systemStatusError = error.localizedDescription
        }
    }

    func stopRuntime() async {
        // Honor the explicit user action for ~2 minutes; the supervisor
        // won't fight back and restart it during this window.
        userStoppedUntil = Date().addingTimeInterval(120)
        do {
            try await dependencies.system.stop()
            recordActivity("system", "Runtime stopped")
            systemStatus = nil
        } catch {
            recordActivity("system", "Failed to stop runtime: \(error.localizedDescription)", level: .error)
            systemStatusError = error.localizedDescription
        }
    }

    func installRecommendedKernel() async {
        isInstallingKernel = true
        kernelInstallProgress = []
        kernelInstallFraction = nil
        kernelInstallComplete = false
        kernelInstallError = nil
        defer { isInstallingKernel = false }
        do {
            for try await line in dependencies.system.installRecommendedKernel() {
                kernelInstallProgress.append(line)
                if kernelInstallProgress.count > 200 {
                    kernelInstallProgress.removeFirst(kernelInstallProgress.count - 200)
                }
                // The CLI has no percentage output; derive a rough stage
                // fraction from keyword progress so the bar still moves.
                kernelInstallFraction = Self.estimateKernelFraction(for: line)
            }
            // Green "complete" moment, then clear the banner.
            kernelInstallComplete = true
            MicropodNotifier.shared.postKernel(
                result: "The container runtime kernel was installed successfully.", isError: false)
            try? await Task.sleep(for: .seconds(1.6))
            onboardingComplete = true
            UserDefaults.standard.set(true, forKey: UserDefaultsKeys.onboardingComplete)
            await refreshSystemStatus()
        } catch {
            kernelInstallError = error.localizedDescription
            MicropodNotifier.shared.postKernel(result: error.localizedDescription, isError: true)
        }
    }

    /// Rough download-progress heuristic: the CLI prints one "Installing…
    /// from <url>" line, then silent work, so most of the bar is animated
    /// while it runs. We keep a sensible 0.15 baseline on the first line and
    /// jump to complete on success.
    static func estimateKernelFraction(for line: String) -> Double? {
        let lower = line.lowercased()
        if lower.contains("installing") || lower.contains("downloading") { return 0.15 }
        if lower.contains("extract") || lower.contains("unpack") { return 0.45 }
        if lower.contains("verif") { return 0.7 }
        if lower.contains("install") { return 0.9 }
        return nil
    }

    /// Whether the runtime's kernel is present on disk (the banner is stale
    /// otherwise — containers can already be running).
    var isKernelInstalled: Bool {
        let candidateRoots = [systemStatus?.appRoot, kernelDefaultRoot].compactMap { $0 }
        for root in candidateRoots {
            let kernel = URL(fileURLWithPath: root).appendingPathComponent("kernels/default.kernel-arm64")
            if FileManager.default.fileExists(atPath: kernel.path) { return true }
        }
        return false
    }

    private var kernelDefaultRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/com.apple.container"
    }

    // MARK: - Refresh

    func refreshAll() async {
        await refreshSystemStatus()
        await refreshContainers()
        await refreshImages()
        await refreshVolumes()
        await refreshNetworks()
        await refreshRegistries()
        await refreshDiskUsage()
    }

    /// Measures the runtime's on-disk footprint with `du -sk` per bucket
    /// (fast, no recursive Swift enumeration over multi-GB trees).
    func refreshStorage() async {
        guard !isMeasuringStorage else { return }
        isMeasuringStorage = true
        defer { isMeasuringStorage = false }

        let root = storageRoot
        let buckets: [(String, String, String)] = [
            (
                "Snapshots", "snapshots",
                "Image + container filesystem layers — the biggest bucket. Reclaimed by image prune and container deletion."
            ),
            (
                "Containers", "containers",
                "VM disks of running and stopped containers. Deleting containers reclaims their disk."
            ),
            ("Content", "content", "OCI image blobs referenced by the content store."),
            ("Volumes", "volumes", "Named volume data (e.g. database volumes)."),
            ("Kernels", "kernels", "Installed kernel images for the VM runtime."),
            ("Builder", "builder", "BuildKit builder shim state."),
        ]
        var measured: [StorageBucket] = []
        var total: Int64 = 0
        for (name, dir, explanation) in buckets {
            let path = root.appendingPathComponent(dir).path
            let bytes = Self.diskSize(path)
            total += bytes
            measured.append(
                StorageBucket(name: name, path: path, sizeBytes: bytes, explanation: explanation))
        }
        storageBuckets = measured
        storageTotalBytes = total
    }

    private var storageRoot: URL {
        if let appRoot = systemStatus?.appRoot, !appRoot.isEmpty {
            return URL(fileURLWithPath: appRoot, isDirectory: true)
        }
        return URL(fileURLWithPath: kernelDefaultRoot, isDirectory: true)
    }

    /// `du -sk` (1 KiB blocks) of a directory; 0 when it doesn't exist.
    private static func diskSize(_ path: String) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let line = String(data: data, encoding: .utf8)?.split(separator: "\t").first,
                let kb = Int64(line)
            else { return 0 }
            return kb * 1024
        } catch {
            return 0
        }
    }

    // MARK: - Long-running operations (2.6)

    let operationRegistry = OperationRegistry()

    func cancelOperation(_ id: UUID) {
        operationRegistry.cancel(id)
    }

    var operations: [ActiveOperation] {
        operationRegistry.operations
    }

    /// Registers a pull with the operations drawer and streams it to
    /// completion or failure. Returns the operation id.
    @discardableResult
    func startPull(reference: String, platform: String?) -> UUID {
        let id = operationRegistry.begin("Pull \(reference)", kind: .pull)
        let task = Task {
            do {
                for try await event in dependencies.images.pull(reference, platform: platform) {
                    operationRegistry.update(id) { $0.events.append(event.line) }
                }
                operationRegistry.finish(id, status: .succeeded)
                await refreshImages()
                recordActivity("images", "Pulled \(reference)", level: .success)
            } catch is CancellationError {
                operationRegistry.finish(id, status: .cancelled)
            } catch {
                operationRegistry.finish(id, status: .failed(error.localizedDescription))
                recordActivity("images", "Failed to pull \(reference): \(error.localizedDescription)", level: .error)
            }
        }
        operationRegistry.registerTask(id, task)
        return id
    }

    /// Registers a build with the operations drawer and streams BuildKit
    /// progress to completion or failure. Returns the operation id.
    @discardableResult
    func startBuild(request: ContainerBuildRequest) -> UUID {
        let tagLabel = request.tags.joined(separator: ", ")
        let id = operationRegistry.begin("Build \(tagLabel.isEmpty ? "image" : tagLabel)", kind: .build)
        let task = Task {
            do {
                for try await chunk in dependencies.client.stream(ContainerCommandFactory.build(request)) {
                    if Task.isCancelled { break }
                    let lines = String(data: chunk, encoding: .utf8)?.split(separator: "\n") ?? []
                    for line in lines {
                        operationRegistry.update(id) { $0.events.append(String(line)) }
                    }
                }
                await refreshImages()
                operationRegistry.finish(id, status: .succeeded)
                recordActivity("build", "Built \(tagLabel.isEmpty ? "image" : tagLabel)", level: .success)
            } catch is CancellationError {
                operationRegistry.finish(id, status: .cancelled)
            } catch {
                operationRegistry.finish(id, status: .failed(error.localizedDescription))
                recordActivity(
                    "build",
                    "Build failed\(tagLabel.isEmpty ? "" : " for \(tagLabel)"): \(error.localizedDescription)",
                    level: .error)
            }
        }
        operationRegistry.registerTask(id, task)
        return id
    }

    // MARK: - Compose

    /// Streaming variant for the compose stepper — yields each progress line
    /// as it arrives; activity + error recording at the stream's end. Mirrors
    /// the stream into a drawer operation so compose shows up there too.
    func composeUpStream(plan: ComposePlan) -> AsyncThrowingStream<String, Error> {
        let id = operationRegistry.begin("Compose up \(plan.composeName)", kind: .compose)
        let execution = dependencies.compose.startUp(plan: plan)
        operationRegistry.registerTask(id, execution.task)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in execution.stream {
                        operationRegistry.update(id) { $0.events.append(line) }
                        continuation.yield(line)
                    }
                    operationRegistry.finish(id, status: .succeeded)
                    recordActivity(
                        "compose",
                        "Up complete — \(plan.composeName) (\(plan.steps.count) steps)",
                        level: .success)
                    continuation.finish()
                } catch is CancellationError {
                    operationRegistry.finish(id, status: .cancelled)
                    continuation.finish(throwing: CancellationError())
                } catch {
                    operationRegistry.finish(id, status: .failed(error.localizedDescription))
                    recordActivity(
                        "compose",
                        "Up failed for \(plan.composeName): \(error.localizedDescription)",
                        level: .error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { execution.task.cancel() }
            }
        }
    }

    func composeUp(plan: ComposePlan) async throws -> [String] {
        var progress: [String] = []
        do {
            for try await line in await dependencies.compose.up(plan: plan) {
                progress.append(line)
            }
            recordActivity("compose", "Up complete — \(plan.composeName) (\(plan.steps.count) steps)", level: .success)
        } catch {
            recordActivity("compose", "Up failed for \(plan.composeName): \(error.localizedDescription)", level: .error)
            throw error
        }
        return progress
    }

    func composeDown(composeName: String) async throws {
        do {
            try await dependencies.compose.down(composeName: composeName)
            recordActivity("compose", "Tore down \(composeName)")
        } catch {
            recordActivity("compose", "Down failed for \(composeName): \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    func refreshContainers() async {
        // Don't waste a CLI invocation when the daemon is down; the
        // supervisor will bring it back and the next poll will catch up.
        guard isRuntimeRunning, clientAvailable else { return }
        do {
            containers = try await dependencies.containers.list()
            lastRefreshError = nil
        } catch {
            // A stopped runtime fails every poll — that's expected state the
            // status card already shows; don't storm the modal alert.
            if isRuntimeRunning {
                lastRefreshError = error.localizedDescription
            }
        }
    }

    func refreshImages() async {
        guard isRuntimeRunning, clientAvailable else {
            hasLoadedImages = false
            return
        }
        do {
            images = try await dependencies.images.list()
            hasLoadedImages = true
        } catch {
            hasLoadedImages = false
            // Background refresh: failures surface as stale panes; not banner-worthy.
        }
    }

    func refreshVolumes() async {
        guard isRuntimeRunning, clientAvailable else { return }
        do {
            volumes = try await dependencies.volumes.list()
        } catch {
            // Background refresh: failures surface as stale panes; not banner-worthy.
        }
    }

    func refreshNetworks() async {
        guard isRuntimeRunning, clientAvailable else { return }
        do {
            networks = try await dependencies.networks.list()
        } catch {
            // Background refresh: failures surface as stale panes; not banner-worthy.
        }
    }

    // MARK: - Machine / VM surface (4.1)

    func refreshMachines() async {
        do {
            machines = try await dependencies.machine.list()
            machineError = nil
        } catch {
            machineError = error.localizedDescription
        }
    }

    func refreshSystemProperties() async {
        do {
            systemProperties = try await dependencies.machine.properties()
            machineError = nil
        } catch {
            machineError = error.localizedDescription
        }
    }

    func createMachine(image: String, name: String, cpus: String, memory: String) async {
        do {
            try await dependencies.machine.create(
                image: image, name: name.isEmpty ? nil : name,
                cpus: cpus.isEmpty ? nil : cpus, memory: memory.isEmpty ? nil : memory)
            recordActivity("system", "Created machine \(name.isEmpty ? image : name)", level: .success)
            await refreshMachines()
        } catch {
            machineError = error.localizedDescription
            recordActivity("system", "Failed to create machine \(name): \(error.localizedDescription)", level: .error)
        }
    }

    func deleteMachine(_ name: String) async {
        do {
            try await dependencies.machine.delete(name)
            recordActivity("system", "Deleted machine \(name)")
            await refreshMachines()
        } catch {
            machineError = error.localizedDescription
            recordActivity("system", "Failed to delete machine \(name): \(error.localizedDescription)", level: .error)
        }
    }

    func refreshRegistries() async {
        do {
            registries = try await dependencies.registries.list()
        } catch {
            // Background refresh: failures surface as stale panes; not banner-worthy.
        }
    }

    func refreshDiskUsage() async {
        guard isRuntimeRunning else { return }
        do {
            diskUsage = try await dependencies.system.diskUsage()
        } catch {
            // Dashboard shows "Disk usage unavailable" for this; not banner-worthy.
        }
    }

    func refreshStats() async {
        do {
            let snapshot = try await dependencies.statsSampler.snapshot()
            statsSnapshot = snapshot
            statsByID = Dictionary(snapshot.containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            appendStatsSample(snapshot)
        } catch {
            // Stats are best-effort; silence transient failures.
        }
    }

    /// Aggregates one snapshot into the rolling history. Cap covers a 3 h
    /// window at the default 5 s visible cadence (~2160 samples).
    private func appendStatsSample(_ snapshot: Micropod_V1_StatsSnapshot) {
        let containers = snapshot.containers
        let cpu = containers.reduce(0.0) { $0 + $1.cpuPercent }
        let used = containers.reduce(UInt64(0)) { $0 + $1.memoryUsedBytes }
        let limit = containers.reduce(UInt64(0)) { $0 + $1.memoryLimitBytes }
        let rx = containers.reduce(UInt64(0)) { $0 + $1.networkRxBytes }
        let tx = containers.reduce(UInt64(0)) { $0 + $1.networkTxBytes }
        statsHistory.append(
            ResourceSample(
                timestamp: Date(), cpuPercent: cpu, memoryUsedBytes: used, memoryLimitBytes: limit,
                networkRxBytes: rx, networkTxBytes: tx))
        if statsHistory.count > 2500 {
            statsHistory.removeFirst(statsHistory.count - 2500)
        }
    }

    // MARK: - Container actions

    func startContainer(_ id: String) async {
        do {
            try await dependencies.containers.start(id)
            recordActivity("containers", "Started \(id)", level: .success)
        } catch {
            recordActivity("containers", "Failed to start \(id): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshContainers()
    }

    func stopContainer(_ id: String) async {
        do {
            try await dependencies.containers.stop(id)
            recordActivity("containers", "Stopped \(id)")
        } catch {
            recordActivity("containers", "Failed to stop \(id): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshContainers()
    }

    func restartContainer(_ id: String) async {
        do {
            try await dependencies.containers.restart(id)
            recordActivity("containers", "Restarted \(id)", level: .success)
        } catch {
            recordActivity("containers", "Failed to restart \(id): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshContainers()
    }

    func killContainer(_ id: String) async {
        do {
            try await dependencies.containers.kill(id)
            recordActivity("containers", "Killed \(id)")
        } catch {
            recordActivity("containers", "Failed to kill \(id): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshContainers()
    }

    func deleteContainer(_ id: String, force: Bool = false) async {
        do {
            try await dependencies.containers.delete(id, force: force)
            recordActivity("containers", "Deleted \(id)")
        } catch {
            recordActivity("containers", "Failed to delete \(id): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        if selectedContainerID == id { selectedContainerID = nil }
        await refreshContainers()
    }

    func pruneContainers() async {
        do {
            let report = try await dependencies.containers.prune()
            recordActivity("containers", "Pruned stopped containers — \(report)")
        } catch {
            recordActivity("containers", "Prune failed: \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshContainers()
    }

    /// Batch actions for multi-select (docker `stop a b c` semantics).
    func batchStop(_ ids: [String]) async {
        var failed = 0
        for id in ids {
            do { try await dependencies.containers.stop(id) } catch { failed += 1 }
        }
        recordActivity(
            "containers", "Stopped \(ids.count - failed)/\(ids.count) containers",
            level: failed == 0 ? .success : .error)
        await refreshContainers()
    }

    func batchStart(_ ids: [String]) async {
        var failed = 0
        for id in ids {
            do { try await dependencies.containers.start(id) } catch { failed += 1 }
        }
        recordActivity(
            "containers", "Started \(ids.count - failed)/\(ids.count) containers",
            level: failed == 0 ? .success : .error)
        await refreshContainers()
    }

    func batchRestart(_ ids: [String]) async {
        var failed = 0
        for id in ids {
            do { try await dependencies.containers.restart(id) } catch { failed += 1 }
        }
        recordActivity(
            "containers", "Restarted \(ids.count - failed)/\(ids.count) containers",
            level: failed == 0 ? .success : .error)
        await refreshContainers()
    }

    func batchKill(_ ids: [String]) async {
        var failed = 0
        for id in ids {
            do { try await dependencies.containers.kill(id) } catch { failed += 1 }
        }
        recordActivity(
            "containers", "Killed \(ids.count - failed)/\(ids.count) containers",
            level: failed == 0 ? .success : .error)
        await refreshContainers()
    }

    func batchDelete(_ ids: [String]) async {
        var failed = 0
        for id in ids {
            do { try await dependencies.containers.delete(id, force: true) } catch { failed += 1 }
        }
        recordActivity(
            "containers", "Deleted \(ids.count - failed)/\(ids.count) containers",
            level: failed == 0 ? .success : .error)
        await refreshContainers()
    }

    func stopAllContainers() async {
        for container in containers where container.state == "running" {
            await stopContainer(container.id)
        }
    }

    func deleteAllContainers(force: Bool = false) async {
        for container in containers {
            await deleteContainer(container.id, force: force)
        }
    }

    @discardableResult
    func startRunContainer(_ request: ContainerRunRequest) -> UUID {
        let label = request.name.flatMap { $0.isEmpty ? nil : $0 } ?? request.image
        let previousIDs = Set(containers.map(\.id))
        let id = operationRegistry.begin("Run \(label)", kind: .container)
        let task = Task {
            do {
                let runOutput = try await dependencies.containers.run(request)
                lastRefreshError = nil
                if request.detach, !runOutput.isEmpty {
                    selectedContainerID = runOutput
                }
                let refreshTask = Task { @MainActor in
                    await refreshContainers()
                }
                await refreshTask.value
                if let resolvedID = launchedContainerID(
                    runOutput: runOutput,
                    request: request,
                    previousIDs: previousIDs,
                    refreshedContainers: containers)
                {
                    selectedContainerID = resolvedID
                }
                operationRegistry.finish(id, status: .succeeded)
                recordActivity("containers", "Launched \(label)", level: .success)
            } catch is CancellationError {
                operationRegistry.finish(id, status: .cancelled)
            } catch {
                let message = error.localizedDescription
                operationRegistry.finish(id, status: .failed(message))
                lastRefreshError = message
                recordActivity("containers", "Failed to launch \(label): \(message)", level: .error)
            }
        }
        operationRegistry.registerTask(id, task)
        return id
    }

    // MARK: - Image actions

    func pullImage(_ reference: String) async {
        do {
            var sawProgress = false
            for try await _ in dependencies.images.pull(reference, platform: nil) {
                sawProgress = true
            }
            _ = sawProgress
            recordActivity("images", "Pulled \(reference)", level: .success)
        } catch {
            recordActivity("images", "Failed to pull \(reference): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshImages()
    }

    func deleteImage(_ reference: String, force: Bool = false) async {
        do {
            try await dependencies.images.delete(reference, force: force)
            recordActivity("images", "Deleted image \(reference)")
        } catch {
            recordActivity(
                "images", "Failed to delete image \(reference): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshImages()
    }

    func pruneImages(all: Bool = false) async {
        do {
            let report = try await dependencies.images.prune(danglingOnly: !all)
            recordActivity("images", "Pruned images — \(report)")
        } catch {
            recordActivity("images", "Image prune failed: \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshImages()
        await refreshDiskUsage()
    }

    func tagImage(source: String, target: String) async {
        do {
            try await dependencies.images.tag(source: source, target: target)
            recordActivity("images", "Tagged \(source) → \(target)")
        } catch {
            recordActivity("images", "Failed to tag \(source): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshImages()
    }

    // MARK: - Volume / Network actions

    func createVolume(name: String, size: String?) async {
        do {
            try await dependencies.volumes.create(name: name, size: size)
            recordActivity("volumes", "Created volume \(name)", level: .success)
        } catch {
            recordActivity("volumes", "Failed to create volume \(name): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshVolumes()
    }

    func deleteVolume(_ name: String) async {
        do {
            try await dependencies.volumes.delete(name)
            recordActivity("volumes", "Deleted volume \(name)")
        } catch {
            recordActivity("volumes", "Failed to delete volume \(name): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshVolumes()
    }

    func pruneVolumes() async {
        do {
            let report = try await dependencies.volumes.prune()
            recordActivity("volumes", "Pruned volumes — \(report)")
        } catch {
            recordActivity("volumes", "Volume prune failed: \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshVolumes()
        await refreshDiskUsage()
    }

    func createNetwork(name: String, internalNetwork: Bool) async {
        do {
            try await dependencies.networks.create(name: name, internal: internalNetwork)
            recordActivity("networks", "Created network \(name)", level: .success)
        } catch {
            recordActivity("networks", "Failed to create network \(name): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshNetworks()
    }

    func deleteNetwork(_ name: String) async {
        do {
            try await dependencies.networks.delete(name)
            recordActivity("networks", "Deleted network \(name)")
        } catch {
            recordActivity("networks", "Failed to delete network \(name): \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshNetworks()
    }

    func pruneNetworks() async {
        do {
            let report = try await dependencies.networks.prune()
            recordActivity("networks", "Pruned networks — \(report)")
        } catch {
            recordActivity("networks", "Network prune failed: \(error.localizedDescription)", level: .error)
            lastRefreshError = error.localizedDescription
        }
        await refreshNetworks()
    }

    // MARK: - Registry actions

    func loginRegistry(server: String, username: String, password: String) async throws {
        do {
            try await dependencies.registries.login(server: server, username: username, password: password)
            recordActivity("registries", "Logged in to \(server)", level: .success)
            await refreshRegistries()
        } catch {
            recordActivity("registries", "Registry login failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    func logoutRegistry(_ server: String) async throws {
        do {
            try await dependencies.registries.logout(server)
            recordActivity("registries", "Logged out of \(server)")
            await refreshRegistries()
        } catch {
            recordActivity("registries", "Registry logout failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }
}

private extension Double {
    func nonzeroOr(_ fallback: Double) -> Double {
        self > 0 ? self : fallback
    }
}
