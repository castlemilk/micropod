import Darwin
import Foundation
import MicropodCore

/// The machine as every non-supervisor process sees it: assets on disk,
/// whether a supervisor holds the lock, and what it last published.
public struct HVFMachineStatus: Sendable, Equatable {
    public var root: String
    public var socket: String
    /// Missing assets by layout name; empty once installed.
    public var missing: [String]
    /// Why an installed layout still cannot host the machine.
    public var problem: String?
    public var supervisorAlive: Bool
    /// The effective phase: `stopped` (or `failed`) whenever no supervisor
    /// holds the lock, whatever a stale state file says.
    public var phase: HVFMachinePhase
    public var state: HVFMachineState?
    /// state.json exists but could not be read.
    public var stateError: String?
    /// True when a newer versioned payload is staged at `<root>/current` than the running VMM loaded.
    public var updatePending: Bool = false
    /// Staged vs running versioned payload summary.
    public var payload: HVFPayloadStatus?

    public var installed: Bool { missing.isEmpty }

    /// One line for `machine status` and engine probes.
    public var summary: String {
        if !installed { return "not installed: missing \(missing.joined(separator: ", "))" }
        if let problem { return problem }
        if let stateError { return "\(phase.rawValue) (\(stateError))" }
        // Staging never moves `current`: the pending target is what is staged.
        let target = payload?.staged?.version ?? payload?.current?.version
        let pending = updatePending ? ", update pending -> \(target ?? "staged")" : ""
        switch phase {
        case .running:
            return
                "running (vmm pid \(state?.vmmPID.map(String.init) ?? "?"), restarts \(state?.restartCount ?? 0)\(pending))"
        case .starting:
            let restarts = state?.restartCount ?? 0
            return restarts > 0
                ? "starting (restart \(restarts) after: \(state?.lastExitReason ?? "unexpected exit"))" : "starting"
        case .stopping: return "stopping"
        case .failed: return "failed: \(state?.lastExitReason ?? "unknown reason")"
        case .stopped:
            if let state, !supervisorAlive, [.running, .starting, .stopping].contains(state.phase) {
                return "stopped (supervisor pid \(state.supervisorPID) exited without stopping the machine)"
            }
            return "stopped"
        }
    }
}

/// Status, start-on-demand and stop for the shared hvf machine. Safe to use
/// from any number of processes at once: the supervisor lock admits one
/// supervisor, `run/start.lock` keeps concurrent starters from racing to
/// launch, and every caller waits on the same Docker `_ping`.
public struct HVFMachineClient: Sendable {
    /// The guest engine serves Docker API 1.44 through 1.47.
    public static let apiVersion = "v1.44"

    public let layout: HVFMachineLayout
    let environment: [String: String]
    let inspector: any HVFProcessInspecting

    public init(
        layout: HVFMachineLayout? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        inspector: any HVFProcessInspecting = HVFDarwinProcessInspector()
    ) {
        self.layout = layout ?? HVFMachineLayout(environment: environment)
        self.environment = environment
        self.inspector = inspector
    }

    public var docker: DockerClient {
        DockerClient(endpoint: .unix(layout.dockerSocket.path), apiVersion: Self.apiVersion)
    }

    /// Atomically links `canonical` (default `~/.micropod/docker.sock`) to this
    /// machine's `run/docker.sock`, replacing a stale socket or a link to one.
    /// Refuses, unless `force`, while another daemon answers on `canonical`:
    /// a socket there, or a link to another machine's live socket (a
    /// throwaway root started with `machine start` must not take over the
    /// rig's Docker endpoint).
    @discardableResult
    public func linkCanonicalDockerSocket(canonical: URL? = nil, force: Bool = false) throws -> URL {
        let linkURL = (canonical ?? HVFMachineLayout.canonicalDockerSocket(environment: environment))
            .standardizedFileURL
        let targetPath = layout.dockerSocket.path
        if linkURL.path == targetPath { return linkURL }
        let fm = FileManager.default
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var st = stat()
        if lstat(linkURL.path, &st) == 0 {
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK {
                let dest = try? fm.destinationOfSymbolicLink(atPath: linkURL.path)
                if dest == targetPath { return linkURL }
                if let dest, !force, Self.isUnixSocketListening(dest) {
                    throw MicropodError.message(
                        "failedPrecondition: \(linkURL.path) already points at \(dest), where another daemon is "
                            + "listening; stop it or pass --force to point it at this machine")
                }
            } else if mode == S_IFSOCK, !force, Self.isUnixSocketListening(linkURL.path) {
                throw MicropodError.message(
                    "failedPrecondition: another daemon is actively listening on \(linkURL.path); "
                        + "stop it or pass --force to replace it with the HVF socket")
            }
        }

        let staging = linkURL.deletingLastPathComponent()
            .appendingPathComponent(".docker.sock.link.\(UUID().uuidString.prefix(8))")
        try? fm.removeItem(at: staging)
        try fm.createSymbolicLink(atPath: staging.path, withDestinationPath: targetPath)
        guard rename(staging.path, linkURL.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: staging)
            throw MicropodError.message(
                "failed to link \(linkURL.path) -> \(targetPath): \(String(cString: strerror(code)))")
        }
        return linkURL
    }

    private static func isUnixSocketListening(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for i in 0..<bytes.count { dst[i] = bytes[i] }
            }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    // MARK: Status

    /// Never boots anything and never talks to the guest.
    public func status() -> HVFMachineStatus {
        let alive = HVFFileLock.isHeld(layout.supervisorLock)
        var state: HVFMachineState?
        var stateError: String?
        do {
            state = try HVFMachineState.load(from: layout.state)
        } catch {
            stateError = error.localizedDescription
        }
        let phase: HVFMachinePhase =
            if alive { state?.phase ?? .starting } else if state?.phase == .failed { .failed } else { .stopped }
        let missing = layout.missingAssets()
        let payload = HVFPayloadStore.status(layout: layout)
        return HVFMachineStatus(
            root: layout.root.path, socket: layout.dockerSocket.path, missing: missing,
            problem: missing.isEmpty ? layout.configurationProblem() : nil, supervisorAlive: alive, phase: phase,
            state: state, stateError: stateError, updatePending: payload.updatePending, payload: payload)
    }

    /// Cheap "is there a guest engine to talk to": a live supervisor that
    /// published `running` and a socket on disk. No guest round trip.
    public var isServing: Bool {
        guard FileManager.default.fileExists(atPath: layout.dockerSocket.path),
            HVFFileLock.isHeld(layout.supervisorLock),
            let state = try? HVFMachineState.load(from: layout.state)
        else { return false }
        return state.phase == .running
    }

    /// Docker `_ping` on `socket`. A failure is the expected answer while
    /// the guest boots, so it is a value, not an error.
    public static func ping(_ socket: URL, timeout: Duration = .seconds(2)) async -> Bool {
        let client = DockerClient(endpoint: .unix(socket.path), apiVersion: apiVersion)
        guard client.reachable else { return false }
        do {
            return try await client.request("GET", "/_ping", timeout: timeout).status == 200
        } catch {
            return false
        }
    }

    // MARK: Start

    /// Returns once the guest Docker API answers, starting a detached
    /// supervisor first when none is running. Fails at once while
    /// `machine install` runs, and when the supervisor it started is
    /// stopped (`machine stop`) before the machine became ready.
    public func ensureRunning(timeout: Duration = .seconds(180)) async throws {
        if layout.installInProgress { throw layout.installInProgressError() }
        let missing = layout.missingAssets()
        guard missing.isEmpty else {
            throw MicropodError.message(
                "failedPrecondition: hvf machine not installed under \(layout.root.path): missing "
                    + "\(missing.joined(separator: ", ")); run `micropod machine install`")
        }
        if let problem = layout.configurationProblem() { throw MicropodError.message("failedPrecondition: \(problem)") }
        if isServing, await Self.ping(layout.dockerSocket) { return }

        let deadline = ContinuousClock.now + timeout
        var launched: Set<Int32> = []
        var launches = 0
        while true {
            if HVFFileLock.isHeld(layout.supervisorLock) {
                if (try? HVFMachineState.load(from: layout.state))?.phase == .running,
                    await Self.ping(layout.dockerSocket)
                {
                    return
                }
            } else {
                // No supervisor. Either none was running, or the one this
                // call waited on has finished — report how, or start one.
                let state = try? HVFMachineState.load(from: layout.state)
                switch Self.stepWithoutSupervisor(state: state, launched: launched, launches: launches) {
                case .launch:
                    // Before the first supervisor resolves its payload: a store
                    // the earlier updater left pending boots only once probed.
                    if launches == 0 { HVFPayloadStore.migrateLegacyStoreBeforeBoot(layout: layout) }
                    launches += 1
                    if let pid = try await launchSupervisor(until: deadline) { launched.insert(pid) }
                    continue
                case .failedToStart(let reason):
                    throw MicropodError.message(
                        "unavailable: hvf machine failed to start: \(reason) (see \(layout.consoleLog.path))")
                case .stoppedWhileStarting:
                    throw MicropodError.message(
                        "unavailable: the hvf machine was stopped (`micropod machine stop`) before it became ready")
                case .gaveUp:
                    throw MicropodError.message(
                        "unavailable: hvf machine supervisor exited before the machine became ready"
                            + (state.map { " (phase \($0.phase.rawValue): \($0.lastExitReason ?? "no reason"))" } ?? "")
                            + supervisorLogTail())
                }
            }
            guard ContinuousClock.now < deadline else {
                let status = status()
                throw MicropodError.message(
                    "deadlineExceeded: hvf machine not ready after \(timeout) (\(status.summary)); "
                        + "see \(layout.consoleLog.path)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    enum StepWithoutSupervisor: Equatable {
        case launch
        /// A supervisor this call launched gave up (`failed`).
        case failedToStart(String)
        /// A supervisor this call launched was asked to stop: an explicit
        /// stop wins over the start that was waiting for it.
        case stoppedWhileStarting
        /// Launched twice and still nothing holds the lock.
        case gaveUp
    }

    /// What `ensureRunning` does when no supervisor holds the lock, from
    /// the last published state and the supervisors this call launched.
    static func stepWithoutSupervisor(state: HVFMachineState?, launched: Set<Int32>, launches: Int)
        -> StepWithoutSupervisor
    {
        if let state, launched.contains(state.supervisorPID) {
            switch state.phase {
            case .failed: return .failedToStart(state.lastExitReason ?? "unknown reason")
            case .stopped: return .stoppedWhileStarting
            default: break
            }
        }
        return launches < 2 ? .launch : .gaveUp
    }

    /// Launches `micropod machine serve` in its own session (so it outlives
    /// this process and its terminal) and waits for it to take the
    /// supervisor lock. nil when another starter's supervisor got there
    /// first.
    private func launchSupervisor(until deadline: ContinuousClock.Instant) async throws -> Int32? {
        // `machine install` holds install.lock (and start.lock) for its whole
        // run: refuse at once rather than queue behind minutes of unpacking.
        var acquired: HVFFileLock?
        while acquired == nil {
            if layout.installInProgress { throw layout.installInProgressError() }
            acquired = try HVFFileLock.acquire(layout.startLock, wait: .zero)
            guard acquired == nil else { break }
            guard ContinuousClock.now < deadline else {
                throw MicropodError.message("deadlineExceeded: timed out waiting for \(layout.startLock.path)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let start = acquired else { return nil }
        defer { start.release() }
        if HVFFileLock.isHeld(layout.supervisorLock) { return nil }
        if layout.installInProgress { throw layout.installInProgressError() }
        guard let executable = Self.supervisorExecutable(environment: environment) else {
            throw MicropodError.message(
                "failedPrecondition: cannot find the micropod CLI that runs the hvf machine supervisor "
                    + "(set MICROPOD_CLI to its path)")
        }
        try FileManager.default.createDirectory(at: layout.logsDirectory, withIntermediateDirectories: true)
        try HVFRotatingLog.rotateIfLarger(layout.supervisorLog, than: HVFMachineSupervisor.supervisorLogMaxBytes)
        let output = open(layout.supervisorLog.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw HVFFiles.posixError("open \(layout.supervisorLog.path)") }
        defer { close(output) }
        var childEnvironment = environment
        childEnvironment["MICROPOD_HVF_ROOT"] = layout.root.path
        childEnvironment[ParentDeathWatch.parentPIDEnv] = nil
        let pid = try HVFSpawn.spawn(
            executable: executable.path, arguments: ["machine", "serve"], environment: childEnvironment,
            output: output, newSession: true)
        let child = HVFReapedChild(pid: pid)
        while ContinuousClock.now < deadline {
            if HVFFileLock.isHeld(layout.supervisorLock) { return pid }
            if let outcome = child.outcome {
                if HVFFileLock.isHeld(layout.supervisorLock) { return pid }
                throw MicropodError.message(
                    "unavailable: hvf machine supervisor (\(executable.path) machine serve) \(outcome) "
                        + "before taking \(layout.supervisorLock.path)" + supervisorLogTail())
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MicropodError.message("deadlineExceeded: hvf machine supervisor pid \(pid) never took its lock")
    }

    static func lock(_ url: URL, until deadline: ContinuousClock.Instant) async throws -> HVFFileLock? {
        while true {
            if let lock = try HVFFileLock.acquire(url, wait: .zero) { return lock }
            guard ContinuousClock.now < deadline else { return nil }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The executable with the `machine serve` entry point, found the way
    /// the MCP server finds the CLI: `MICROPOD_CLI`, then this executable
    /// or its siblings (`micropod-cli` in the app bundle, `micropod` in a
    /// SwiftPM build directory), then the installed links.
    public static func supervisorExecutable(environment: [String: String]) -> URL? {
        var candidates: [URL] = []
        if let configured = environment["MICROPOD_CLI"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        let current = CLIInstall.currentExecutable()
        if ["micropod", "micropod-cli"].contains(current.lastPathComponent) { candidates.append(current) }
        let directory = current.deletingLastPathComponent()
        candidates += [directory.appendingPathComponent("micropod-cli"), directory.appendingPathComponent("micropod")]
        candidates += [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/micropod"),
            URL(fileURLWithPath: "/usr/local/bin/micropod"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Stop

    /// How long `stop` waits for an in-flight start to hand over to its
    /// supervisor (spawn + lock, normally well under a second).
    static let startHandoverWait: Duration = .seconds(10)

    /// Asks the supervisor to power the guest off and waits for it to exit.
    /// False when no supervisor was running. A machine another process is
    /// starting right now is waited for and stopped, not reported as not
    /// running. The default `timeout` outlasts the configured guest
    /// poweroff budget plus the supervisor's SIGKILL escalation, and does
    /// not depend on machine.json still being valid: the running
    /// supervisor loaded its configuration when it started.
    @discardableResult
    public func stop(timeout: Duration? = nil) async throws -> Bool {
        // Nothing under this root has ever started (and nothing is created).
        guard FileManager.default.fileExists(atPath: layout.runDirectory.path) else { return false }
        // A starter holds start.lock until its supervisor holds the
        // supervisor lock, so once start.lock is ours that supervisor is
        // visible. Proceed regardless if a starter is wedged.
        var start = try await Self.lock(layout.startLock, until: ContinuousClock.now + Self.startHandoverWait)
        defer { start?.release() }
        guard HVFFileLock.isHeld(layout.supervisorLock) else { return false }
        let grace =
            (try? HVFMachineConfig.load(from: layout.config))?.stopGrace
            ?? HVFMachineConfig(shutdownTimeoutSeconds: 600).stopGrace
        let timeout = timeout ?? grace + .seconds(30)
        let pid = try await supervisorPID()
        if let failure = inspector.signal(pid, SIGTERM), inspector.isAlive(pid) {
            throw MicropodError.message("internal: hvf: cannot signal supervisor pid \(pid): \(failure)")
        }
        // Signalled: other starters may queue behind the stop now.
        start?.release()
        start = nil
        let deadline = ContinuousClock.now + timeout
        while HVFFileLock.isHeld(layout.supervisorLock) {
            guard ContinuousClock.now < deadline else {
                throw MicropodError.message(
                    "deadlineExceeded: hvf supervisor pid \(pid) still running \(timeout) after SIGTERM")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    public func restart(timeout: Duration = .seconds(180)) async throws {
        try await stop()
        try await ensureRunning(timeout: timeout)
    }

    /// The live supervisor's pid, proven by its lock record and, when the
    /// state file names the same pid, its recorded start time.
    private func supervisorPID() async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            if let pid = HVFFileLock.recordedPID(layout.supervisorLock), pid > 1 {
                // An unreadable state file only skips the recycled-pid check.
                let state = try? HVFMachineState.load(from: layout.state)
                if let state, state.supervisorPID == pid, let recorded = state.supervisorStartSeconds,
                    let actual = inspector.facts(pid)?.startSeconds, recorded != actual
                {
                    throw MicropodError.message(
                        "internal: hvf: supervisor pid \(pid) was recycled by another process; refusing to signal it")
                }
                return pid
            }
            guard ContinuousClock.now < deadline else {
                throw MicropodError.message(
                    "internal: hvf: the supervisor holds \(layout.supervisorLock.path) but recorded no pid")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Logs

    /// The last lines of `logs/supervisor.log`, for error messages.
    func supervisorLogTail(lines: Int = 6) -> String {
        guard let data = try? Data(contentsOf: layout.supervisorLog), !data.isEmpty else { return "" }
        let text = String(decoding: data.suffix(4096), as: UTF8.self)
        let tail = text.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return tail.isEmpty ? "" : "\n\(layout.supervisorLog.path):\n\(tail)"
    }
}

/// A spawned child reaped on a parked thread, so a long-lived caller (the
/// API server) never accumulates zombie supervisors.
final class HVFReapedChild: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var ended: String?

    init(pid: pid_t) {
        self.pid = pid
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
            let outcome: String
            if reaped == pid {
                let (code, signal) = HVFSpawn.describe(status: status)
                outcome = code.map { "exited with status \($0)" } ?? "was killed by signal \(signal ?? 0)"
            } else {
                outcome = "could not be waited for: \(String(cString: strerror(errno)))"
            }
            lock.withLock { ended = outcome }
        }
    }

    /// How the child ended; nil while it runs.
    var outcome: String? { lock.withLock { ended } }
}
