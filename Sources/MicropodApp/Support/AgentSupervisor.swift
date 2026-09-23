import Darwin
import Foundation
import MicropodCore

/// How the supervisor decides an agent is healthy between spawns.
enum AgentProbe: Sendable {
    /// A unix socket that accepts connections (docker.sock).
    case unixSocket(path: String)
    /// An HTTP endpoint that must answer 2xx (the JSON API's /health).
    case http(port: UInt16, path: String)
    /// Test seam.
    case custom(@Sendable () async -> Bool)
}

/// A managed helper process — a "kernel agent" the app owns end to end:
/// spawned on bootstrap, health-probed, restarted with backoff when it dies,
/// and terminated when the app quits.
struct AgentSpec: Sendable {
    let id: String
    let displayName: String
    let binaryName: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
    let probe: AgentProbe
    /// UserDefaults bool key; missing value means enabled.
    let enabledDefaultsKey: String
    /// Short human description of where the agent listens, for the UI.
    let endpoint: String
    /// Absolute binary path that skips bundle/build-dir resolution (tests).
    var binaryPathOverride: String? = nil
    /// When false the supervisor never kills foreign processes matching
    /// `binaryName` — tests set this so a spec that names a real binary
    /// can't reap the developer's actually-running agents.
    var reapsForeignCopies: Bool = true
}

struct AgentStatus: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        /// Healthy and spawned by this app instance.
        case running
        /// Healthy but spawned outside the app (task shim / task api) —
        /// monitored, never killed on quit.
        case adopted
        /// Spawned this session, probe not passing yet.
        case starting
        /// Not healthy; a respawn is scheduled (see `restarts`).
        case retryPending
        /// Binary could not be located anywhere.
        case missing
        /// Disabled in Settings.
        case stopped
    }

    var id: String
    var name: String
    var state: State
    var pid: Int32?
    var restarts: Int
    var lastError: String?
    var endpoint: String
}

/// Lock-protected box for live `Process` handles so quit-time teardown can
/// run synchronously from `applicationWillTerminate` (no await allowed).
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [String: Process] = [:]

    func set(_ id: String, _ process: Process?) {
        lock.lock()
        processes[id] = process
        lock.unlock()
    }

    func get(_ id: String) -> Process? {
        lock.lock()
        defer { lock.unlock() }
        return processes[id]
    }

    func terminateAll(graceSeconds: TimeInterval = 1.5) {
        lock.lock()
        let live = processes
        processes = [:]
        lock.unlock()

        for (_, process) in live where process.isRunning {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(graceSeconds)
        for (_, process) in live where process.isRunning {
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Supervises the app's helper daemons — the Docker Engine shim and the
/// local HTTP API — as tightly coupled children ("kernel agents"):
///
/// - **Adopt or spawn.** A healthy endpoint is adopted (monitored, left
///   alone on quit); an unhealthy one is (re)spawned from the bundled binary.
/// - **Backoff.** Respawns back off exponentially (5s → 60s cap) so a
///   crashing binary doesn't thrash.
/// - **Ownership.** PID files in ~/.micropod/run/ let a fresh app instance
///   reap orphans left by a crashed one; `MICROPOD_PARENT_PID` arms each
///   child's ParentDeathWatch so nothing outlives the app.
/// - **Quit teardown.** `terminateOwnedSync()` kills owned children from
///   `applicationWillTerminate` without needing an async hop.
actor AgentSupervisor {
    private let specs: [AgentSpec]
    private let runDirectory: URL
    private let isEnabled: @Sendable (AgentSpec) -> Bool
    private let onStatus: @Sendable ([AgentStatus]) -> Void
    private let children = ProcessBox()
    private let probeSession: URLSession

    /// Specs for Settings UI (Sendable value types; safe to read nonisolated).
    nonisolated var specsForUI: [AgentSpec] { specs }

    private var monitorTask: Task<Void, Never>?
    private var states: [String: AgentStatus] = [:]
    private var failures: [String: Int] = [:]
    private var restarts: [String: Int] = [:]
    private var nextRetryAt: [String: Date] = [:]
    private var startingSince: [String: Date] = [:]
    private var probeMisses: [String: Int] = [:]
    private var started = false

    init(
        specs: [AgentSpec],
        runDirectory: URL,
        isEnabled: @escaping @Sendable (AgentSpec) -> Bool,
        onStatus: @escaping @Sendable ([AgentStatus]) -> Void
    ) {
        self.specs = specs
        self.runDirectory = runDirectory
        self.isEnabled = isEnabled
        self.onStatus = onStatus
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        self.probeSession = URLSession(configuration: config)
    }

    /// The two agents the app manages today.
    static func micropodSpecs(
        enabled: @escaping @Sendable (AgentSpec) -> Bool,
        onStatus: @escaping @Sendable ([AgentStatus]) -> Void
    ) -> AgentSupervisor {
        let apiPort =
            UInt16(ProcessInfo.processInfo.environment["MICROPOD_API_PORT"] ?? "45454") ?? 45454
        let specs = [
            AgentSpec(
                id: "docker-shim",
                displayName: "Docker API shim",
                binaryName: "micropod-docker-shim",
                probe: .unixSocket(
                    path: NSString("~/.micropod/docker.sock").expandingTildeInPath),
                enabledDefaultsKey: UserDefaultsKeys.agentDockerShim,
                endpoint: "~/.micropod/docker.sock"),
            AgentSpec(
                id: "api-server",
                displayName: "HTTP API server",
                binaryName: "MicropodAPI",
                probe: .http(port: apiPort, path: "/health"),
                enabledDefaultsKey: UserDefaultsKeys.agentAPIServer,
                endpoint: "127.0.0.1:\(apiPort)"),
            AgentSpec(
                id: "shared-fs",
                displayName: "Shared filesystem",
                binaryName: "micropod-sharedfs",
                probe: .unixSocket(
                    path: NSString("~/micropod/share-cache/socket").expandingTildeInPath),
                enabledDefaultsKey: UserDefaultsKeys.agentSharedFS,
                endpoint: "~/micropod/share-cache/socket"),
        ]
        return AgentSupervisor(
            specs: specs,
            runDirectory: URL(fileURLWithPath: NSString("~/.micropod/run").expandingTildeInPath),
            isEnabled: enabled,
            onStatus: onStatus)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        for spec in specs {
            states[spec.id] = AgentStatus(
                id: spec.id, name: spec.displayName, state: .starting,
                pid: nil, restarts: 0, lastError: nil, endpoint: spec.endpoint)
        }
        publish()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        terminateOwnedSync()
    }

    /// Synchronous teardown for `applicationWillTerminate` — SIGTERM,
    /// short grace, then SIGKILL for owned children only.
    nonisolated func terminateOwnedSync() {
        children.terminateAll()
        for spec in specs {
            try? FileManager.default.removeItem(at: pidFileURL(for: spec.id))
        }
    }

    func statuses() -> [AgentStatus] {
        specs.map { spec in
            states[spec.id]
                ?? AgentStatus(
                    id: spec.id, name: spec.displayName, state: .stopped,
                    pid: nil, restarts: 0, lastError: nil, endpoint: spec.endpoint)
        }
    }

    /// Manual restart from Settings: drop the child, clear backoff, ensure.
    func restart(_ id: String) async {
        guard specs.contains(where: { $0.id == id }) else { return }
        if let child = children.get(id), child.isRunning {
            child.terminate()
        }
        children.set(id, nil)
        try? FileManager.default.removeItem(at: pidFileURL(for: id))
        failures[id] = 0
        nextRetryAt[id] = nil
        startingSince[id] = nil
        probeMisses[id] = 0
        states[id]?.state = .starting
        publish()
        await tick()
    }

    /// "Restart All" from Settings — restarts every enabled agent; disabled
    /// ones are skipped (restart would just respawn them).
    func restartAll() async {
        for spec in specs where isEnabled(spec) {
            await restart(spec.id)
        }
    }

    // MARK: - Monitor

    /// One monitor pass over all agents. Internal (not private) so tests can
    /// drive ticks directly without the 5s monitor loop.
    func tick() async {
        for spec in specs {
            await tickAgent(spec)
        }
        publish()
    }

    private func tickAgent(_ spec: AgentSpec) async {
        if states[spec.id] == nil {
            states[spec.id] = AgentStatus(
                id: spec.id, name: spec.displayName, state: .starting,
                pid: nil, restarts: 0, lastError: nil, endpoint: spec.endpoint)
        }
        guard isEnabled(spec) else {
            if let child = children.get(spec.id), child.isRunning {
                child.terminate()
            }
            children.set(spec.id, nil)
            states[spec.id]?.state = .stopped
            states[spec.id]?.pid = nil
            return
        }

        let healthy = await probe(spec)

        if healthy {
            failures[spec.id] = 0
            nextRetryAt[spec.id] = nil
            startingSince[spec.id] = nil
            probeMisses[spec.id] = 0
            if let child = children.get(spec.id), child.isRunning {
                // Keep the pid file fresh — it's what lets a *future* app
                // instance reap this child if we crash without quitting.
                ensurePIDFile(spec, pid: child.processIdentifier)
                states[spec.id]?.state = .running
                states[spec.id]?.pid = child.processIdentifier
            } else {
                // Adopted endpoints are someone else's process — the pid
                // file must not survive, or a later launch would reap a
                // process we never owned.
                children.set(spec.id, nil)
                reapStalePIDFile(spec)
                states[spec.id]?.state = .adopted
                states[spec.id]?.pid = nil
            }
            states[spec.id]?.lastError = nil
            return
        }

        // Unhealthy. If our child is still alive it may be mid-boot — give it
        // a grace window before declaring it wedged.
        if let child = children.get(spec.id), child.isRunning {
            let since = startingSince[spec.id] ?? Date()
            startingSince[spec.id] = since
            if Date().timeIntervalSince(since) > 30 {
                child.terminate()
                children.set(spec.id, nil)
                markFailed(spec, "spawned but never became healthy")
            } else {
                states[spec.id]?.state = .starting
                states[spec.id]?.pid = child.processIdentifier
            }
            return
        }

        // A single failed probe is often transient — a busy socket or a
        // stalled accept queue — so confirm with a second miss before
        // spawning. Otherwise we'd launch a doomed duplicate against an
        // endpoint another live process still owns.
        let misses = (probeMisses[spec.id] ?? 0) + 1
        probeMisses[spec.id] = misses
        if misses < 2 {
            states[spec.id]?.lastError = "probe failed — confirming before restart"
            return
        }

        // Nothing ours is alive — clear out anything squatting on the
        // endpoint, then respawn once backoff allows. Orphans from crashed
        // app instances come from the pid file; *foreign* copies of our
        // binary (a `task shim` left in a terminal, a zombie that lost its
        // listener but kept the port) would otherwise make the respawn fail
        // to bind forever.
        reapOrphanedAgent(spec)
        children.set(spec.id, nil)
        if spec.reapsForeignCopies {
            reapForeignCopies(of: spec)
        }

        guard resolveBinary(spec) != nil else {
            states[spec.id]?.state = .missing
            states[spec.id]?.lastError = "\(spec.binaryName) not found"
            return
        }

        if let retryAt = nextRetryAt[spec.id], retryAt > Date() {
            states[spec.id]?.state = .retryPending
            return
        }

        spawn(spec)
    }

    private func markFailed(_ spec: AgentSpec, _ reason: String) {
        let n = (failures[spec.id] ?? 0) + 1
        failures[spec.id] = n
        // 5s, 10s, 20s, 40s, capped at 60s.
        let delay = min(60.0, 5.0 * pow(2.0, Double(n - 1)))
        nextRetryAt[spec.id] = Date().addingTimeInterval(delay)
        states[spec.id]?.state = .retryPending
        states[spec.id]?.lastError = reason
    }

    private func spawn(_ spec: AgentSpec) {
        guard let binary = resolveBinary(spec) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = spec.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in spec.environment {
            environment[key] = value
        }
        // Arms the child's ParentDeathWatch: if this app dies without a clean
        // quit, the agent exits on its own within ~2s.
        environment[ParentDeathWatch.parentPIDEnv] = "\(ProcessInfo.processInfo.processIdentifier)"
        process.environment = environment

        // Agent output goes to ~/.micropod/run/<id>.log — a real debug
        // surface instead of /dev/null.
        let logURL = runDirectory.appendingPathComponent("\(spec.id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            children.set(spec.id, process)
            restarts[spec.id] = (restarts[spec.id] ?? 0) + 1
            startingSince[spec.id] = Date()
            states[spec.id]?.state = .starting
            states[spec.id]?.pid = process.processIdentifier
            states[spec.id]?.restarts = restarts[spec.id] ?? 0
            states[spec.id]?.lastError = nil
            writePIDFile(spec, pid: process.processIdentifier)
        } catch {
            markFailed(spec, "spawn failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Probes

    private func probe(_ spec: AgentSpec) async -> Bool {
        switch spec.probe {
        case .unixSocket(let path):
            return await Task.detached(priority: .utility) {
                Self.unixSocketAccepts(path)
            }.value
        case .http(let port, let path):
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return false }
            do {
                let (_, response) = try await probeSession.data(from: url)
                guard let http = response as? HTTPURLResponse else { return false }
                return (200..<300).contains(http.statusCode)
            } catch {
                return false
            }
        case .custom(let check):
            return await check()
        }
    }

    /// True when something accepts connections on the unix socket path.
    static func unixSocketAccepts(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBufferPointer { src in
                memcpy(dest.baseAddress, src.baseAddress!, pathBytes.count)
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    // MARK: - PID files & orphan reaping

    private nonisolated func pidFileURL(for id: String) -> URL {
        runDirectory.appendingPathComponent("\(id).pid")
    }

    private func writePIDFile(_ spec: AgentSpec, pid: Int32) {
        let record: [String: Any] = [
            "pid": Int(pid),
            "binary": spec.binaryName,
            "started_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: pidFileURL(for: spec.id), options: .atomic)
        }
    }

    /// Writes the pid file only when missing or stale — every healthy tick
    /// would otherwise rewrite the same JSON every few seconds.
    private func ensurePIDFile(_ spec: AgentSpec, pid: Int32) {
        let url = pidFileURL(for: spec.id)
        if let data = try? Data(contentsOf: url),
            let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            record["pid"] as? Int == Int(pid)
        {
            return
        }
        writePIDFile(spec, pid: pid)
    }

    /// The recorded pid no longer corresponds to our child — drop it so a
    /// future launch doesn't reap a process it doesn't own.
    private func reapStalePIDFile(_ spec: AgentSpec) {
        try? FileManager.default.removeItem(at: pidFileURL(for: spec.id))
    }

    /// If a previous app instance crashed, its agent may still be alive but
    /// unservable (orphaned). When the pid file names a live process running
    /// our binary, kill it before respawning so the new instance binds cleanly.
    private func reapOrphanedAgent(_ spec: AgentSpec) {
        let url = pidFileURL(for: spec.id)
        guard let data = try? Data(contentsOf: url),
            let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = record["pid"] as? Int, pid > 1
        else { return }

        // Only reap when the live pid is actually our binary — never kill an
        // unrelated process that recycled the pid.
        guard Self.processAlive(Int32(pid)),
            Self.processPath(Int32(pid))?.hasSuffix("/\(spec.binaryName)") == true
        else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        kill(Int32(pid), SIGTERM)
        let deadline = Date().addingTimeInterval(1.0)
        while Self.processAlive(Int32(pid)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if Self.processAlive(Int32(pid)) {
            kill(Int32(pid), SIGKILL)
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Kill every running copy of the agent's binary that isn't our live
    /// child. Only called after the endpoint has failed two consecutive
    /// probes — a healthy, adopted endpoint never reaches this, so a user's
    /// intentionally-running `task shim`/`task api` is left alone while it
    /// actually serves. A copy that can't serve is a zombie squatting on the
    /// port/socket and must go so the respawn can bind.
    private func reapForeignCopies(of spec: AgentSpec) {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var squatters: [Int32] = []
        for raw in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) {
            let pid = Int32(raw)
            guard pid > 1, pid != selfPID else { continue }
            guard Self.processPath(pid)?.hasSuffix("/\(spec.binaryName)") == true else {
                continue
            }
            if let child = children.get(spec.id), child.isRunning,
                child.processIdentifier == pid
            {
                continue
            }
            squatters.append(pid)
        }
        guard !squatters.isEmpty else { return }
        for pid in squatters { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(1.0)
        for pid in squatters {
            while Self.processAlive(pid), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if Self.processAlive(pid) { kill(pid, SIGKILL) }
        }
    }

    private static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Binary resolution

    /// Same search order as the app's other helpers: the .app's MacOS
    /// directory first, then dev build outputs for `swift build` workflows.
    private func resolveBinary(_ spec: AgentSpec) -> URL? {
        if let override = spec.binaryPathOverride {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent(spec.binaryName),
            URL(fileURLWithPath: ".build/debug/\(spec.binaryName)"),
            URL(fileURLWithPath: ".build/release/\(spec.binaryName)"),
        ]
        for candidate in candidates {
            if let url = candidate, FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func publish() {
        onStatus(statuses())
    }
}
