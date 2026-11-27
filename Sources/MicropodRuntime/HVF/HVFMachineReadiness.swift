import Foundation
import MicropodCore
import Synchronization

/// Whether the hvf machine can take work now, read from live state only: a
/// supervisor holding its lock, `running` published, the Docker socket on
/// disk, and the guest Docker API answering `_ping` within
/// `pingFreshness`. Installed assets alone say nothing: a stopped or
/// crash-looping machine reports what it is doing, never `running`, so a
/// rig controller does not lease work that would cold-boot or fail late.
///
/// Ping and GetSystem report `status`, and advertise `caches-v2` and
/// `buildkit` only while the machine is ready and its tool bundle ships
/// them.
public struct HVFMachineReadiness: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable, CaseIterable {
        /// Serving: the only status that admits work.
        case running
        /// A supervisor is booting or relaunching the VMM.
        case starting
        case stopping
        /// No supervisor: `machine start` (or the first run) boots it.
        case stopped
        /// The supervisor gave up. A container call or `machine start`
        /// retries at once; a status read of the default machine starts it
        /// on demand once `HVFMachineAutostart.retryAfter` has passed.
        case failed
        /// `running` is published, but the guest Docker API is not answering.
        case notReady = "not-ready"
        /// Assets are missing (`machine install`).
        case notInstalled = "not-installed"
        /// Installed, but the layout cannot host a machine.
        case unusable
    }

    public var status: Status
    /// Why, in `machine status` words: the phase, restarts, the last exit.
    public var detail: String
    /// The staged payload's version, or "hvf".
    public var version: String
    public var revision: String
    /// Ready, and the tool bundle ships BuildKit.
    public var buildkit: Bool
    /// Ready, and the tool bundle's engine attaches dependency caches.
    public var caches: Bool

    public var isReady: Bool { status == .running }

    /// What the backend always offers, then what only a ready machine does.
    public var features: [String] {
        ["hvf", "rootless", "proto-binary"] + (caches ? ["caches-v2"] : []) + (buildkit ? ["buildkit"] : [])
    }

    /// `ComponentVersion.state`: "running", "missing", or "stopped" for
    /// every other not-ready status (`detail` says which).
    public var componentState: String {
        switch status {
        case .running: return "running"
        case .notInstalled: return "missing"
        default: return "stopped"
        }
    }

    public init(
        status: Status, detail: String, version: String = "hvf", revision: String = "unknown", buildkit: Bool = false,
        caches: Bool = false
    ) {
        self.status = status
        self.detail = detail
        self.version = version
        self.revision = revision
        self.buildkit = buildkit
        self.caches = caches
    }

    /// How long a `_ping` answer stands for the guest being up. Within it a
    /// readiness check makes no guest round trip.
    public static let pingFreshness: Duration = .seconds(3)

    /// The last `_ping` answer per Docker socket and VMM pid, so a VMM the
    /// supervisor relaunched is pinged afresh.
    private static let answered = Mutex<[String: ContinuousClock.Instant]>([:])

    static func answeredRecently(_ key: String, now: ContinuousClock.Instant) -> Bool {
        answered.withLock { entries in
            guard let at = entries[key] else { return false }
            return now - at < pingFreshness
        }
    }

    static func recordAnswer(_ key: String, at instant: ContinuousClock.Instant) {
        answered.withLock { $0[key] = instant }
    }

    static func forgetAnswer(_ key: String) {
        _ = answered.withLock { $0.removeValue(forKey: key) }
    }
}

extension HVFMachineClient {
    /// The machine's readiness from live state. Never boots anything; makes
    /// at most one guest round trip (`_ping`, `pingTimeout`), and none while
    /// a recent answer stands or the supervisor does not report `running`.
    public func readiness(pingTimeout: Duration = .seconds(1)) async -> HVFMachineReadiness {
        let status = status()
        let version = status.payload?.current?.version ?? "hvf"
        let revision = status.payload?.current?.revision ?? "unknown"
        func notReady(_ value: HVFMachineReadiness.Status, _ detail: String? = nil) -> HVFMachineReadiness {
            HVFMachineReadiness(status: value, detail: detail ?? status.summary, version: version, revision: revision)
        }
        guard status.installed else { return notReady(.notInstalled) }
        if let problem = status.problem { return notReady(.unusable, problem) }
        switch status.phase {
        case .starting: return notReady(.starting)
        case .stopping: return notReady(.stopping)
        case .stopped: return notReady(.stopped)
        case .failed: return notReady(.failed)
        case .running: break
        }
        // `running` with a live supervisor; the guest must still answer.
        let key = "\(layout.dockerSocket.path)#\(status.state?.vmmPID ?? 0)"
        guard isServing else {
            HVFMachineReadiness.forgetAnswer(key)
            return notReady(.notReady, "\(status.summary); no Docker socket at \(layout.dockerSocket.path)")
        }
        if !HVFMachineReadiness.answeredRecently(key, now: .now) {
            guard await Self.ping(layout.dockerSocket, timeout: pingTimeout) else {
                HVFMachineReadiness.forgetAnswer(key)
                return notReady(.notReady, "\(status.summary); the guest Docker API did not answer _ping")
            }
            HVFMachineReadiness.recordAnswer(key, at: .now)
        }
        return HVFMachineReadiness(
            status: .running, detail: status.summary, version: version, revision: revision,
            buildkit: layout.missingBuildKitFiles().isEmpty,
            caches: HVFToolsManifest.load(bundle: layout.tools)?.caches == true)
    }
}

// MARK: - Starting a default machine that is down

extension HVFMachineClient {
    /// `readiness()` for a machine that is the default runtime: one that is
    /// down without having been stopped on request (never started since
    /// the Mac booted, its supervisor gone, or given up after crashes) is
    /// started in the background and reported `starting` until the guest
    /// answers. That is when a runner would have booted it with its first
    /// job; reporting `stopped` instead would leave a rig controller that
    /// treats only `running` as leasable waiting on a machine nothing
    /// starts.
    ///
    /// While that start runs, every read says why it was started ("starting
    /// on demand (failed: …)"), also once the new supervisor has published
    /// its own state, which knows nothing of the last one's crashes.
    ///
    /// A machine whose supervisor gave up (`failed`) is reported `failed`,
    /// with the supervisor's reason, for `HVFMachineAutostart.retryAfter`
    /// after it gave up, and only then started on demand: a crash loop is
    /// not rebooted by the very next status read, and its reason stays
    /// visible. A machine stopped on request (`machine stop`, or an update
    /// that left it as it found it) stays `stopped`: only `machine start` or
    /// a container call boots it. Starts are single-flight per root, and one
    /// that failed is not retried for `HVFMachineAutostart.retryAfter`.
    /// `MICROPOD_HVF_AUTOSTART=0` turns this off (plain `readiness()`).
    public func readinessStartingWhenDown(
        start: (@Sendable () async throws -> Void)? = nil
    ) async -> HVFMachineReadiness {
        let ready = await readiness()
        guard environment["MICROPOD_HVF_AUTOSTART"] != "0" else { return ready }
        let root = layout.root.path
        func onDemand(_ status: HVFMachineReadiness.Status, _ detail: String) -> HVFMachineReadiness {
            HVFMachineReadiness(status: status, detail: detail, version: ready.version, revision: ready.revision)
        }
        if let cause = HVFMachineAutostart.inFlightCause(root) {
            switch ready.status {
            case .stopped, .failed: return onDemand(.starting, "starting on demand (\(cause))")
            case .starting, .notReady: return onDemand(ready.status, "starting on demand (\(cause)): \(ready.detail)")
            default: return ready
            }
        }
        guard [.stopped, .failed].contains(ready.status), !stoppedOnRequest else { return ready }
        if let failure = HVFMachineAutostart.lastFailure(root) {
            var failed = ready
            failed.detail = "\(ready.detail); the last start on demand failed: \(failure)"
            return failed
        }
        if ready.status == .failed, let wait = gaveUpRecently() {
            var failed = ready
            failed.detail = "\(ready.detail); started on demand again in \(wait) s"
            return failed
        }
        guard HVFMachineAutostart.begin(root, cause: ready.detail) else {
            // Another reader began it between the two looks.
            return onDemand(.starting, "starting on demand (\(ready.detail))")
        }
        let client = self
        let start = start ?? { try await client.ensureRunning() }
        Task.detached {
            do {
                try await start()
                HVFMachineAutostart.finish(root, failure: nil)
            } catch {
                HVFMachineAutostart.finish(root, failure: error.localizedDescription)
            }
        }
        return onDemand(.starting, "starting on demand (\(ready.detail))")
    }

    /// Seconds until a supervisor that gave up (the state it left says
    /// `failed`) is `HVFMachineAutostart.retryAfter` behind; nil once it is.
    func gaveUpRecently(now: Date = Date()) -> Int? {
        guard let state = try? HVFMachineState.load(from: layout.state), state.phase == .failed else { return nil }
        let age = now.timeIntervalSince(state.updatedAt)
        let window = Double(HVFMachineAutostart.retryAfter.components.seconds)
        // A clock set back since then holds nothing up.
        guard age >= 0, age < window else { return nil }
        return Int((window - age).rounded(.up))
    }

    /// No supervisor, and the last one recorded a stop it was asked for.
    var stoppedOnRequest: Bool {
        guard !HVFFileLock.isHeld(layout.supervisorLock) else { return false }
        return (try? HVFMachineState.load(from: layout.state))?.phase == .stopped
    }
}

/// Single-flight bookkeeping for `readinessStartingWhenDown`.
public enum HVFMachineAutostart {
    /// How long a failed start on demand is not retried.
    public static let retryAfter: Duration = .seconds(60)

    private struct Entry {
        var inFlight = false
        /// Why the start in flight began: the readiness detail then.
        var cause: String?
        var failedAt: ContinuousClock.Instant?
        var failure: String?
    }

    private static let entries = Mutex<[String: Entry]>([:])

    /// True when the caller should start the machine now. `cause`: why
    /// (the readiness detail), reported while it runs.
    static func begin(_ root: String, cause: String = "", now: ContinuousClock.Instant = .now) -> Bool {
        entries.withLock { all in
            var entry = all[root] ?? Entry()
            if entry.inFlight { return false }
            if let failedAt = entry.failedAt, now - failedAt < retryAfter { return false }
            entry.inFlight = true
            entry.cause = cause
            all[root] = entry
            return true
        }
    }

    /// Why the start on demand in flight began; nil when none runs.
    static func inFlightCause(_ root: String) -> String? {
        entries.withLock { all in
            guard let entry = all[root], entry.inFlight else { return nil }
            return entry.cause ?? ""
        }
    }

    static func finish(_ root: String, failure: String?, now: ContinuousClock.Instant = .now) {
        entries.withLock { all in
            all[root] = Entry(inFlight: false, failedAt: failure == nil ? nil : now, failure: failure)
        }
    }

    /// Why the last start on demand failed, while it is not retried.
    static func lastFailure(_ root: String, now: ContinuousClock.Instant = .now) -> String? {
        entries.withLock { all in
            guard let entry = all[root], !entry.inFlight, let at = entry.failedAt, now - at < retryAfter else {
                return nil
            }
            return entry.failure
        }
    }

    /// Tests: forget every root.
    static func reset() { entries.withLock { $0.removeAll() } }
}
