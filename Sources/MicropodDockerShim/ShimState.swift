import Foundation
import MicropodCore
import MicropodSharedFS

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
    /// Reverse mirror of `nameToID` so snapshot/forget stay O(N) instead of
    /// scanning all names per container (long-lived shims track hundreds).
    private var idToName: [String: String] = [:]

    /// Docker-visible name for a runtime id (create-time alias), if tracked.
    func dockerName(for id: String) -> String? { idToName[id] }

    /// True while any tracked container sits on a custom (non-default)
    /// network — the events loop keeps polling then, to refresh managed
    /// hosts files as membership churns.
    private var customNetworks: [String: Set<String>] = [:]

    var hasCustomNetworks: Bool { !customNetworks.isEmpty }

    func remember(id: String, name: String?, request: DockerCreateRequest) {
        creates[id] = request
        if let name, !name.isEmpty {
            nameToID[name] = id
            idToName[id] = name
            // (Re)creating under a tombstoned rename-aside name revives it.
            tombstoned.remove(name)
        }
        // Custom-network membership (for managed /etc/hosts DNS): mirrors
        // the attachment mapping in buildRunRequest.
        let custom = request.attachedNetworks
        if custom.isEmpty {
            customNetworks.removeValue(forKey: id)
        } else {
            customNetworks[id] = Set(custom)
        }
        if request.HostConfig?.AutoRemove == true {
            autoRemoveIDs.insert(id)
        } else {
            autoRemoveIDs.remove(id)
        }
        deriveHealthSpec(id: id)
        snapshot()
    }

    func id(forName name: String) -> String? {
        nameToID[name]
    }

    /// Record a Docker-side rename (the Apple runtime has no rename; the
    /// runtime id is unchanged and only this mapping moves). Old Docker
    /// name(s) for the id stop resolving, like real renames.
    func rename(id: String, newName: String) {
        if let old = idToName[id], nameToID[old] == id {
            nameToID.removeValue(forKey: old)
        } else {
            nameToID = nameToID.filter { $0.value != id }
        }
        nameToID[newName] = id
        idToName[id] = newName
        snapshot()
    }

    /// Tombstoned Docker names: rename-aside of a stopped container deletes
    /// it (freeing the runtime id — see containerRename) while remembering
    /// that the new name was deliberately consumed, so its later removal is
    /// idempotent instead of 404. Cleared when the name is (re)created.
    /// In-memory only: renames are always followed promptly by the
    /// recreate/remove that motivated them.
    private var tombstoned: Set<String> = []

    func tombstone(name: String) {
        tombstoned.insert(name)
    }

    func isTombstoned(_ name: String) -> Bool {
        tombstoned.contains(name)
    }

    func clearTombstone(_ name: String) {
        tombstoned.remove(name)
    }

    func createRequest(for id: String) -> DockerCreateRequest? {
        creates[id]
    }

    func forget(id: String) {
        startedIDs.remove(id)
        attachInFlightIDs.remove(id)
        creates.removeValue(forKey: id)
        // lastExitCodes deliberately survives — see noteExit.
        // O(1) via the mirror; the equality guard keeps the maps consistent
        // even if a name was ever reassigned without a forget in between.
        if let old = idToName.removeValue(forKey: id), nameToID[old] == id {
            nameToID.removeValue(forKey: old)
        }
        autoRemoveIDs.remove(id)
        resetRestartTracking(id)
        forgetHealth(id: id)
        customNetworks.removeValue(forKey: id)
        stopErrors.removeValue(forKey: id)
        sharedViews.removeValue(forKey: id)
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

    private var sharedViews: [String: [ViewID]] = [:]

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

    // MARK: - Healthcheck supervision

    /// Normalized create-time healthcheck (durations in seconds).
    struct HealthSpec: Sendable, Codable {
        /// ["CMD", args...] or ["CMD-SHELL", script].
        var test: [String]
        var intervalS: Double
        var timeoutS: Double
        var retries: Int
        var startPeriodS: Double
        var startIntervalS: Double

        /// Nil when no healthcheck is configured (absent, empty, or
        /// Test == ["NONE"]). Docker durations arrive as nanoseconds.
        static func from(_ body: DockerHealthcheck?) -> HealthSpec? {
            guard let body, let test = body.Test, !test.isEmpty else { return nil }
            guard test != ["NONE"] else { return nil }
            guard test[0] == "CMD" || test[0] == "CMD-SHELL" else { return nil }
            let interval = body.Interval.map { Double($0) / 1e9 } ?? 30
            return HealthSpec(
                test: test,
                intervalS: interval > 0 ? interval : 30,
                timeoutS: body.Timeout.map { max(Double($0) / 1e9, 0.05) } ?? 30,
                retries: body.Retries ?? 3,
                startPeriodS: max(Double(body.StartPeriod ?? 0) / 1e9, 0),
                startIntervalS: {
                    guard let raw = body.StartInterval, raw > 0 else { return interval }
                    return Double(raw) / 1e9
                }())
        }
    }

    struct HealthLogEntry: Sendable, Codable {
        var startedAt: Date
        var exitCode: Int
        var output: String
    }

    struct HealthStatus: Sendable {
        var status: String  // starting | healthy | unhealthy
        var failingStreak: Int
        var log: [HealthLogEntry]  // last 5 probes
        var everHealthy: Bool
        var firstRunningAt: Date?
        var nextProbeAt: Date
        var inFlight: Bool

        static var initial: HealthStatus {
            HealthStatus(
                status: "starting", failingStreak: 0, log: [],
                everHealthy: false, firstRunningAt: nil,
                nextProbeAt: Date(), inFlight: false)
        }
    }

    private var healthSpecs: [String: HealthSpec] = [:]
    private var healthStatuses: [String: HealthStatus] = [:]

    /// Health specs ride on the remembered create bodies (persisted), so a
    /// restarted shim re-derives supervision without extra snapshot fields.
    private func deriveHealthSpec(id: String) {
        if let request = creates[id], let spec = HealthSpec.from(request.Healthcheck) {
            healthSpecs[id] = spec
            if healthStatuses[id] == nil {
                healthStatuses[id] = .initial
            }
        } else {
            healthSpecs.removeValue(forKey: id)
            healthStatuses.removeValue(forKey: id)
        }
    }

    func healthSpec(id: String) -> HealthSpec? { healthSpecs[id] }

    func healthStatus(id: String) -> HealthStatus? { healthStatuses[id] }

    var hasHealthChecks: Bool { !healthSpecs.isEmpty }

    /// (Re)start resets supervision to starting (Docker semantics); the spec
    /// survives. Called on observed start transitions and explicit starts.
    func resetHealth(id: String) {
        guard healthSpecs[id] != nil else { return }
        var status = healthStatuses[id] ?? .initial
        status.status = "starting"
        status.failingStreak = 0
        status.everHealthy = false
        status.firstRunningAt = nil
        status.nextProbeAt = Date()
        status.inFlight = false
        healthStatuses[id] = status
    }

    /// Containers due for a probe: supervised, currently running, due, and
    /// without a probe already in flight (slow probes must not pile up).
    func healthDueIDs(runningIDs: Set<String>) -> [String] {
        let now = Date()
        return healthSpecs.keys.filter { id in
            guard runningIDs.contains(id), let status = healthStatuses[id] else { return false }
            return !status.inFlight && status.nextProbeAt <= now
        }
    }

    func noteProbeStarted(id: String, intervalS: Double) {
        guard var status = healthStatuses[id] else { return }
        status.inFlight = true
        // Schedule the next slot now so a hung probe cannot stall cadence;
        // recordProbe reschedules precisely on completion.
        status.nextProbeAt = Date().addingTimeInterval(intervalS)
        healthStatuses[id] = status
    }

    /// Record a probe outcome; returns the new status string.
    @discardableResult
    func recordProbe(id: String, success: Bool, output: String) -> String {
        guard var status = healthStatuses[id], let spec = healthSpecs[id] else { return "none" }
        status.inFlight = false
        let entry = HealthLogEntry(
            startedAt: Date(), exitCode: success ? 0 : 1,
            output: String(output.prefix(2048)))
        status.log.append(entry)
        if status.log.count > 5 { status.log.removeFirst(status.log.count - 5) }
        if success {
            status.failingStreak = 0
            status.everHealthy = true
            status.status = "healthy"
        } else {
            status.failingStreak += 1
            let pastStart: Bool = {
                guard let since = status.firstRunningAt else { return false }
                return Date().timeIntervalSince(since) >= spec.startPeriodS
            }()
            if pastStart, status.failingStreak > spec.retries {
                status.status = "unhealthy"
            } else if !status.everHealthy {
                status.status = "starting"
            }
            // else: was healthy, still within retries → stays healthy.
        }
        let interval =
            status.status == "starting" && spec.startIntervalS > 0
            ? spec.startIntervalS : spec.intervalS
        status.nextProbeAt = Date().addingTimeInterval(interval)
        healthStatuses[id] = status
        return status.status
    }

    /// Stamp first-observed-running (start-period baseline). Called alongside
    /// the existing running observation.
    func noteHealthRunning(id: String) {
        guard healthSpecs[id] != nil else { return }
        if healthStatuses[id]?.firstRunningAt == nil {
            healthStatuses[id]?.firstRunningAt = Date()
        }
    }

    private func forgetHealth(id: String) {
        healthSpecs.removeValue(forKey: id)
        healthStatuses.removeValue(forKey: id)
    }

    // MARK: - Shared file-share views

    func rememberSharedViews(containerID: String, views: [ViewID]) {
        guard !views.isEmpty else { return }
        sharedViews[containerID] = views
        snapshot()
    }

    func sharedViews(for containerID: String) -> [ViewID] {
        sharedViews[containerID] ?? []
    }

    func forgetSharedViews(containerID: String) -> [ViewID] {
        let views = sharedViews.removeValue(forKey: containerID) ?? []
        if !views.isEmpty { snapshot() }
        return views
    }

    // MARK: - Restart persistence

    private struct PersistedState: Codable {
        var version = 1
        var creates: [String: StoredCreate] = [:]
        var sharedViews: [String: [ViewID]] = [:]
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
        sharedViews: [String: [ViewID]] = [:],
        persistenceURL: URL? = nil
    ) {
        self.creates = creates
        self.nameToID = names
        // Defensive: first name wins if legacy state ever maps two names to
        // one id (uniqueKeysWithValues would trap).
        var mirror = [String: String]()
        mirror.reserveCapacity(names.count)
        for (name, id) in names where mirror[id] == nil {
            mirror[id] = name
        }
        self.idToName = mirror
        self.autoRemoveIDs = autoRemove
        self.sharedViews = sharedViews
        self.persistenceURL = persistenceURL
        // Health specs ride on the remembered create bodies (persisted), so
        // supervision re-derives for every construction path, including
        // snapshot reloads (status restarts at starting). Inlined (not via
        // deriveHealthSpec) because actor init cannot call isolated methods.
        // Custom-network membership re-derives the same way.
        for id in creates.keys {
            if let request = creates[id], let spec = HealthSpec.from(request.Healthcheck) {
                healthSpecs[id] = spec
                healthStatuses[id] = .initial
            }
            if let request = creates[id], !request.attachedNetworks.isEmpty {
                customNetworks[id] = Set(request.attachedNetworks)
            }
        }
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
            sharedViews: persisted.sharedViews,
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
        for id in stale {
            idToName.removeValue(forKey: id)
        }
        autoRemoveIDs.subtract(stale)
        for id in stale {
            customNetworks.removeValue(forKey: id)
        }
        for id in stale {
            resetRestartTracking(id)
            forgetHealth(id: id)
            stopErrors.removeValue(forKey: id)
            sharedViews.removeValue(forKey: id)
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
            persisted.creates[id] = StoredCreate(name: idToName[id], request: request)
        }
        persisted.sharedViews = sharedViews
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

/// Docker↔Apple container-name translation.
/// Docker accepts `/?[a-zA-Z0-9][a-zA-Z0-9_.-]+` with no practical length
/// cap; the Apple runtime additionally requires ≤ 63 bytes and rejects
/// leading `_` (probed: 63 ok, 64+ "not a valid container ID", `_foo`
/// rejected, `UPPER`/`9foo`/`foo.bar` accepted). Stock clients hit this with
/// long generated names — notably testcontainers' `reaper_<session>` (71
/// chars). When the requested name is already valid it passes through
/// untouched; otherwise a deterministic sanitized runtime name is derived
/// (content-hash suffix, so it is stable across shim restarts) and the
/// caller aliases requested → runtime in `ShimState`, so every later lookup
/// by Docker name keeps working. `docker ps` then shows the sanitized name:
/// cosmetic, documented, and strictly better than a hard failure for a name
/// Docker itself accepts.
enum DockerNaming {
    static let maxLength = 63

    static func isRuntimeValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxLength else { return false }
        guard let first = name.first, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy(Self.isRuntimeChar)
    }

    private static func isRuntimeChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-"
    }

    private static func sanitizedChar(_ ch: Character) -> Character {
        isRuntimeChar(ch) ? ch : "-"
    }

    /// Returns `(runtimeName, aliased)`. Pure function of the input.
    static func runtimeName(for requested: String) -> (name: String, aliased: Bool) {
        if isRuntimeValid(requested) { return (requested, false) }
        var sanitized = String(requested.map(Self.sanitizedChar))
        if let first = sanitized.first, !(first.isLetter || first.isNumber) {
            sanitized = "c" + sanitized
        }
        if sanitized.isEmpty { sanitized = "c" }
        if sanitized.count > maxLength {
            let digest = (try? ChunkHash.compute(Data(requested.utf8)))?.value ?? "deadbeefdead"
            sanitized = String(sanitized.prefix(maxLength - 13)) + "-" + digest.prefix(12)
        }
        return (sanitized, true)
    }
}

/// Intercepts bind-mounted /var/run/docker.sock, which the Apple runtime
/// cannot pass through virtiofs as a working unix socket — so instead we
/// strip the socket bind and point the container at this shim's TCP listener
/// over the VM bridge.
///
/// This applies to EVERY container (not just Ryuk): Docker-in-Docker clients
/// such as the cuttlefish runner mount the socket expecting a daemon, and
/// without the redirect the bind arrives as a dead file. Ryuk additionally
/// gets its 8080 port published so session clients can reach it.
enum RyukSupport {
    static let ryukImageMarker = "testcontainers/ryuk"

    static func isRyuk(_ image: String) -> Bool {
        image.contains(ryukImageMarker)
    }

    /// Returns a possibly-modified copy of the create body.
    static func intercept(
        _ request: DockerCreateRequest, bridgeHost: String, tcpPort: UInt16
    ) -> (request: DockerCreateRequest, notes: [String]) {
        let ryuk = isRyuk(request.Image)
        var modified = request
        var notes = [String]()

        var binds = modified.HostConfig?.Binds ?? []
        let before = binds.count
        binds = binds.filter { !$0.lowercased().contains("docker.sock") }
        if binds.count != before {
            notes.append("removed \(before - binds.count) docker.sock bind(s)")
        } else if !ryuk {
            // No socket bind and not Ryuk: nothing to do.
            return (request, [])
        }

        // Any container that mounted the socket (or Ryuk, which needs the
        // daemon even without an explicit bind) talks to the shim over TCP.
        if binds.count != before || ryuk {
            var env = modified.Env ?? []
            let dockerHost = "tcp://\(bridgeHost):\(tcpPort)"
            if !env.contains(where: { $0.hasPrefix("DOCKER_HOST=") }) {
                env.append("DOCKER_HOST=\(dockerHost)")
                notes.append("injected DOCKER_HOST=\(dockerHost)")
            } else {
                env = env.map { $0.hasPrefix("DOCKER_HOST=") ? "DOCKER_HOST=\(dockerHost)" : $0 }
            }
            modified.Env = env
        }

        // Ryuk listens on 8080; make sure it is published so clients can
        // reach it. Non-Ryuk containers keep their ports untouched.
        var bindings = modified.HostConfig?.PortBindings ?? [:]
        if ryuk,
            bindings["8080/tcp"] == nil || bindings["8080/tcp"]?.isEmpty == true
        {
            bindings["8080/tcp"] = [DockerPortBinding(HostIp: nil, HostPort: nil)]
            notes.append("published 8080/tcp")
        }

        var hostConfig = modified.HostConfig ?? DockerHostConfig()
        hostConfig.Binds = binds
        hostConfig.PortBindings = bindings
        modified.HostConfig = hostConfig
        return (modified, notes)
    }
}
