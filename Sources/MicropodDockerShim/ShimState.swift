import Foundation
import MicropodCore

/// Session-scoped shim state: the original Docker create bodies (needed to
/// render inspect/list faithfully and to honor AutoRemove), exec records,
/// and exit codes captured at die time for `wait` conditions.
actor ShimState {
    struct ExecRecord {
        var id: String
        var containerID: String
        var cmd: [String]
        var running: Bool
        var exitCode: Int?
    }

    private(set) var creates: [String: DockerCreateRequest] = [:]
    private(set) var execs: [String: ExecRecord] = [:]
    private(set) var lastExitCodes: [String: Int] = [:]
    private var nameToID: [String: String] = [:]

    func remember(id: String, name: String?, request: DockerCreateRequest) {
        creates[id] = request
        if let name, !name.isEmpty {
            nameToID[name] = id
        }
        if request.HostConfig?.AutoRemove == true {
            autoRemoveIDs.insert(id)
        } else {
            autoRemoveIDs.remove(id)
        }
        snapshot()
    }

    func id(forName name: String) -> String? {
        nameToID[name]
    }

    func createRequest(for id: String) -> DockerCreateRequest? {
        creates[id]
    }

    func forget(id: String) {
        startedIDs.remove(id)
        attachInFlightIDs.remove(id)
        creates.removeValue(forKey: id)
        // lastExitCodes deliberately survives — see noteExit.
        nameToID = nameToID.filter { $0.value != id }
        autoRemoveIDs.remove(id)
        resetRestartTracking(id)
        stopErrors.removeValue(forKey: id)
        snapshot()
    }

    func registerExec(_ record: ExecRecord) {
        execs[record.id] = record
    }

    func finishExec(id: String, exitCode: Int) {
        guard var record = execs[id] else { return }
        record.running = false
        record.exitCode = exitCode
        execs[id] = record
    }

    func exec(_ id: String) -> ExecRecord? {
        execs[id]
    }

    /// Containers this shim has issued a `/start` for. The runtime cannot tell
    /// us — it reports "stopped" for both a never-started container and one
    /// that ran and exited — and asking it costs a CLI process per poll.
    private var startedIDs: Set<String> = []

    func markStarted(id: String) {
        startedIDs.insert(id)
    }

    /// Containers whose `container start --attach` run has not finished.
    ///
    /// Held here rather than behind a lock in AttachRegistry because the
    /// events loop needs to consult it: taking a non-reentrant NSLock from
    /// inside that actor deadlocks it, and a stalled events loop stops every
    /// reap and restart in the shim.
    private var attachInFlightIDs: Set<String> = []

    func markAttachRunning(id: String) {
        attachInFlightIDs.insert(id)
    }

    func clearAttachRunning(id: String) {
        attachInFlightIDs.remove(id)
    }

    func isAttachRunning(id: String) -> Bool {
        attachInFlightIDs.contains(id)
    }

    func hasStarted(id: String) -> Bool {
        startedIDs.contains(id)
    }

    /// Exit codes must outlive the container they describe: with `--rm` the
    /// client's `/wait` is still polling when the container is deleted, and a
    /// forgotten code reads back as 0 — a failed run reported as success.
    /// Bounded so a long-lived shim doesn't accumulate them forever.
    private static let exitCodeHistoryLimit = 512
    private var exitCodeOrder: [String] = []

    func noteExit(id: String, code: Int) {
        if lastExitCodes[id] == nil {
            exitCodeOrder.append(id)
            if exitCodeOrder.count > Self.exitCodeHistoryLimit {
                let evicted = exitCodeOrder.removeFirst()
                lastExitCodes.removeValue(forKey: evicted)
            }
        }
        lastExitCodes[id] = code
    }

    func exitCode(for id: String) -> Int? {
        lastExitCodes[id]
    }

    // MARK: - In-flight stops (fast-stop safety)

    private var stopTasks: [String: Task<Void, Never>] = [:]
    private var stopErrors: [String: String] = [:]

    func setStopTask(_ id: String, _ task: Task<Void, Never>) {
        stopTasks[id] = task
        stopErrors.removeValue(forKey: id)
    }

    func stopTask(for id: String) -> Task<Void, Never>? {
        stopTasks[id]
    }

    func finishStopTask(_ id: String, error: String?) {
        stopTasks.removeValue(forKey: id)
        if let error { stopErrors[id] = error }
    }

    func stopError(for id: String) -> String? {
        stopErrors[id]
    }

    func awaitStop(_ id: String) async {
        while let task = stopTasks[id] {
            await task.value
        }
    }

    // MARK: - Restart policy supervision

    private var intentionalStops = Set<String>()
    private var restartAttempts: [String: Int] = [:]
    private var lastObservedRunning: [String: Date] = [:]

    /// Marks a stop as client-intentional (docker `stop`), which suppresses
    /// `unless-stopped` restarts but not `always`.
    func noteIntentionalStop(_ id: String) {
        intentionalStops.insert(id)
    }

    func clearIntentionalStop(_ id: String) {
        intentionalStops.remove(id)
    }

    func isIntentionalStop(_ id: String) -> Bool {
        intentionalStops.contains(id)
    }

    func noteRunning(_ id: String) {
        lastObservedRunning[id] = Date()
    }

    /// Records that the container has been running; resets the restart
    /// backoff once it stayed up past the stability window.
    func ranStably(_ id: String, threshold: TimeInterval = 10) -> Bool {
        if let since = lastObservedRunning[id], Date().timeIntervalSince(since) >= threshold {
            restartAttempts[id] = 0
            return true
        }
        return false
    }

    func nextRestartDelay(_ id: String, base: Double = 0.1, cap: Double = 30) -> Double {
        let attempts = restartAttempts[id] ?? 0
        restartAttempts[id] = attempts + 1
        return min(base * pow(2, Double(attempts)), cap)
    }

    func restartAttemptCount(_ id: String) -> Int {
        restartAttempts[id] ?? 0
    }

    func resetRestartTracking(_ id: String) {
        restartAttempts.removeValue(forKey: id)
        lastObservedRunning.removeValue(forKey: id)
        intentionalStops.remove(id)
    }

    // MARK: - Restart persistence

    private struct PersistedState: Codable {
        var version = 1
        var creates: [String: StoredCreate] = [:]
    }

    private struct StoredCreate: Codable {
        var name: String?
        var request: DockerCreateRequest
    }

    private var persistenceURL: URL?
    private var autoRemoveIDs: Set<String> = []

    init(
        creates: [String: DockerCreateRequest] = [:],
        names: [String: String] = [:],
        autoRemove: Set<String> = [],
        persistenceURL: URL? = nil
    ) {
        self.creates = creates
        self.nameToID = names
        self.autoRemoveIDs = autoRemove
        self.persistenceURL = persistenceURL
    }

    /// Enables crash/restart-safe memory: every mutation is snapshotted to
    /// `url` so a relaunched shim still knows ports, env, labels, names and
    /// AutoRemove flags of containers it created.
    func enablePersistence(at url: URL) {
        persistenceURL = url
        snapshot()
    }

    static func loadPersisted(from url: URL) -> ShimState {
        guard let data = try? Data(contentsOf: url),
            let persisted = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return ShimState(persistenceURL: url) }
        var seededCreates = [String: DockerCreateRequest]()
        var seededNames = [String: String]()
        var seededAutoRemove = Set<String>()
        for (id, stored) in persisted.creates {
            seededCreates[id] = stored.request
            if let name = stored.name, !name.isEmpty {
                seededNames[name] = id
            }
            if stored.request.HostConfig?.AutoRemove == true {
                seededAutoRemove.insert(id)
            }
        }
        return ShimState(
            creates: seededCreates, names: seededNames, autoRemove: seededAutoRemove,
            persistenceURL: url)
    }

    /// Drops state for containers that no longer exist after a restart.
    func retainOnly(ids: Set<String>) {
        let stale = Set(creates.keys).subtracting(ids)
        for id in stale {
            creates.removeValue(forKey: id)
            lastExitCodes.removeValue(forKey: id)
        }
        nameToID = nameToID.filter { ids.contains($0.value) }
        autoRemoveIDs.subtract(stale)
        for id in stale {
            resetRestartTracking(id)
            stopErrors.removeValue(forKey: id)
        }
        snapshot()
    }

    var autoRemoveContainerIDs: Set<String> { autoRemoveIDs }

    /// True when any tracked container carries a restart policy — the event
    /// hub must keep polling to supervise those.
    var hasRestartPolicies: Bool {
        creates.values.contains {
            guard let name = $0.HostConfig?.RestartPolicy?.Name?.lowercased() else { return false }
            return !name.isEmpty && name != "no"
        }
    }

    private func snapshot() {
        guard let persistenceURL else { return }
        var persisted = PersistedState()
        for (id, request) in creates {
            persisted.creates[id] = StoredCreate(
                name: nameToID.first(where: { $0.value == id })?.key, request: request)
        }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }
}

enum IDGenerator {
    static func containerID() -> String {
        let adjectives = ["vibrant", "quiet", "brave", "clever", "eager", "gentle", "lively"]
        let nouns = ["otter", "falcon", "cactus", "harbor", "lantern", "maple", "quartz"]
        let adjective = adjectives.randomElement() ?? "swift"
        let noun = nouns.randomElement() ?? "otter"
        return "\(adjective)_\(noun)_\(randomSuffix())"
    }

    static func randomSuffix(length: Int = 10) -> String {
        String((0..<length).map { _ in "abcdef0123456789".randomElement()! })
    }

    static func execID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Intercepts testcontainers' Ryuk resource-reaper creation. Ryuk expects a
/// bind-mounted /var/run/docker.sock, which the Apple runtime cannot pass
/// through virtiofs as a working unix socket — so instead we strip the socket
/// bind and point Ryuk at this shim's TCP listener over the VM bridge.
enum RyukSupport {
    static let ryukImageMarker = "testcontainers/ryuk"

    static func isRyuk(_ image: String) -> Bool {
        image.contains(ryukImageMarker)
    }

    /// Returns a possibly-modified copy of the create body.
    static func intercept(
        _ request: DockerCreateRequest, bridgeHost: String, tcpPort: UInt16
    ) -> (request: DockerCreateRequest, notes: [String]) {
        guard isRyuk(request.Image) else { return (request, []) }
        var modified = request
        var notes = [String]()

        var binds = modified.HostConfig?.Binds ?? []
        let before = binds.count
        binds = binds.filter { !$0.lowercased().contains("docker.sock") }
        if binds.count != before {
            notes.append("removed \(before - binds.count) docker.sock bind(s)")
        }

        var env = modified.Env ?? []
        let dockerHost = "tcp://\(bridgeHost):\(tcpPort)"
        if !env.contains(where: { $0.hasPrefix("DOCKER_HOST=") }) {
            env.append("DOCKER_HOST=\(dockerHost)")
            notes.append("injected DOCKER_HOST=\(dockerHost)")
        } else {
            env = env.map { $0.hasPrefix("DOCKER_HOST=") ? "DOCKER_HOST=\(dockerHost)" : $0 }
        }

        // Ryuk listens on 8080; make sure it is published so clients can reach it.
        var bindings = modified.HostConfig?.PortBindings ?? [:]
        if bindings["8080/tcp"] == nil || bindings["8080/tcp"]?.isEmpty == true {
            bindings["8080/tcp"] = [DockerPortBinding(HostIp: nil, HostPort: nil)]
            notes.append("published 8080/tcp")
        }

        modified.Env = env
        var hostConfig = modified.HostConfig ?? DockerHostConfig()
        hostConfig.Binds = binds
        hostConfig.PortBindings = bindings
        modified.HostConfig = hostConfig
        return (modified, notes)
    }
}
