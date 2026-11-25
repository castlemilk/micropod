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

    public var installed: Bool { missing.isEmpty }

    /// One line for `machine status` and engine probes.
    public var summary: String {
        if !installed { return "not installed: missing \(missing.joined(separator: ", "))" }
        if let problem { return problem }
        if let stateError { return "\(phase.rawValue) (\(stateError))" }
        switch phase {
        case .running:
            return "running (vmm pid \(state?.vmmPID.map(String.init) ?? "?"), restarts \(state?.restartCount ?? 0))"
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
        return HVFMachineStatus(
            root: layout.root.path, socket: layout.dockerSocket.path, missing: missing,
            problem: missing.isEmpty ? layout.configurationProblem() : nil, supervisorAlive: alive, phase: phase,
            state: state, stateError: stateError)
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
    /// supervisor first when none is running.
    public func ensureRunning(timeout: Duration = .seconds(180)) async throws {
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
                if let state, launched.contains(state.supervisorPID), state.phase == .failed {
                    throw MicropodError.message(
                        "unavailable: hvf machine failed to start: \(state.lastExitReason ?? "unknown reason") "
                            + "(see \(layout.consoleLog.path))")
                }
                guard launches < 2 else {
                    throw MicropodError.message(
                        "unavailable: hvf machine supervisor exited before the machine became ready"
                            + (state.map { " (phase \($0.phase.rawValue): \($0.lastExitReason ?? "no reason"))" } ?? "")
                            + supervisorLogTail())
                }
                launches += 1
                if let pid = try await launchSupervisor(until: deadline) { launched.insert(pid) }
                continue
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

    /// Launches `micropod machine serve` in its own session (so it outlives
    /// this process and its terminal) and waits for it to take the
    /// supervisor lock. nil when another starter's supervisor got there
    /// first.
    private func launchSupervisor(until deadline: ContinuousClock.Instant) async throws -> Int32? {
        guard let start = try await Self.lock(layout.startLock, until: deadline) else {
            throw MicropodError.message("deadlineExceeded: timed out waiting for \(layout.startLock.path)")
        }
        defer { start.release() }
        if HVFFileLock.isHeld(layout.supervisorLock) { return nil }
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

    /// Asks the supervisor to power the guest off and waits for it to exit.
    /// False when no supervisor was running.
    @discardableResult
    /// The default `timeout` outlasts the configured guest poweroff budget
    /// plus the supervisor's SIGKILL escalation.
    public func stop(timeout: Duration? = nil) async throws -> Bool {
        guard HVFFileLock.isHeld(layout.supervisorLock) else { return false }
        let timeout = try timeout ?? HVFMachineConfig.load(from: layout.config).stopGrace + .seconds(30)
        let pid = try await supervisorPID()
        if let failure = inspector.signal(pid, SIGTERM), inspector.isAlive(pid) {
            throw MicropodError.message("internal: hvf: cannot signal supervisor pid \(pid): \(failure)")
        }
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
                let state = try HVFMachineState.load(from: layout.state)
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
