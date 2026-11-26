import Darwin
import Foundation
import MicropodCore
import Synchronization

// MARK: - VMM process seam

/// How a micropod-vmm process ended.
public struct HVFVMMExit: Sendable, Equatable, CustomStringConvertible {
    public var code: Int32?
    public var signal: Int32?
    /// `exit_reason` from the VMM's `--json-summary` line, when it printed one.
    public var summary: String?
    /// What guest init reported before stopping (`MICROPOD_VMM_GUEST_STATUS`).
    public var guestStatus: String?
    /// The process never started.
    public var launchError: String?

    public init(
        code: Int32? = nil, signal: Int32? = nil, summary: String? = nil, guestStatus: String? = nil,
        launchError: String? = nil
    ) {
        self.code = code
        self.signal = signal
        self.summary = summary
        self.guestStatus = guestStatus
        self.launchError = launchError
    }

    /// micropod-vmm's exit codes (`vmm/crates/vmm-core/src/exit.rs`).
    static func meaning(ofExitCode code: Int32) -> String? {
        switch code {
        case 0: return "orderly guest poweroff"
        case 1: return "VMM error"
        case 2: return "invalid command line"
        case 3: return "the guest crashed or reset"
        case 4: return "guest init or the container engine failed"
        case 5: return "timeout elapsed"
        case 6: return "stopped without an orderly guest poweroff"
        case 7: return "its supervisor exited"
        default: return nil
        }
    }

    /// What micropod-vmm says the status means.
    public var meaning: String? { code.flatMap(Self.meaning(ofExitCode:)) }

    /// A launch failure, an invalid command line, or a VMM error (status 1:
    /// unusable kernel/disk/socket, hypervisor refusal): relaunching the
    /// same configuration cannot help.
    public var isConfigurationFailure: Bool { launchError != nil || code == 1 || code == 2 }

    public var description: String {
        if let launchError { return "could not be launched: \(launchError)" }
        var text =
            if let code {
                "exited with status \(code)" + (Self.meaning(ofExitCode: code).map { ": \($0)" } ?? "")
            } else if let signal {
                "was killed by signal \(signal)\(signal == SIGKILL ? " (SIGKILL)" : "")"
            } else { "ended for an unknown reason" }
        if let summary { text += " (exit_reason=\(summary))" }
        if let guestStatus { text += "; guest reported: \(guestStatus)" }
        return text
    }
}

public protocol HVFVMMProcess: Sendable {
    var pid: Int32 { get }
    func waitForExit() async -> HVFVMMExit
    /// Delivers `signal` unless the process has already exited (its pid is
    /// never signalled after it could have been recycled).
    func signal(_ signal: Int32)
}

public protocol HVFVMMLaunching: Sendable {
    func launch(executable: URL, arguments: [String]) throws -> any HVFVMMProcess
}

// MARK: - Policy

public struct HVFSupervisorPolicy: Sendable, Equatable {
    /// Launch → Docker `_ping` deadline before the boot counts as failed.
    public var readinessTimeout: Duration
    public var readinessInterval: Duration
    /// SIGTERM → exit deadline before SIGKILL (graceful guest poweroff).
    public var stopTimeout: Duration
    public var backoffBase: Duration
    public var backoffMax: Duration
    /// An exit before readiness, or within this long of launch, is rapid.
    public var rapidFailureWindow: Duration
    /// Consecutive rapid failures that end supervision in `failed`.
    public var maxRapidFailures: Int
    /// How long to retry the supervisor lock (readers probe it briefly).
    public var lockWait: Duration

    public init(
        readinessTimeout: Duration = .seconds(120), readinessInterval: Duration = .milliseconds(100),
        stopTimeout: Duration = .seconds(15), backoffBase: Duration = .seconds(1), backoffMax: Duration = .seconds(30),
        rapidFailureWindow: Duration = .seconds(60), maxRapidFailures: Int = 5, lockWait: Duration = .milliseconds(500)
    ) {
        self.readinessTimeout = readinessTimeout
        self.readinessInterval = readinessInterval
        self.stopTimeout = stopTimeout
        self.backoffBase = backoffBase
        self.backoffMax = backoffMax
        self.rapidFailureWindow = rapidFailureWindow
        self.maxRapidFailures = maxRapidFailures
        self.lockWait = lockWait
    }

    /// Delay before relaunch number `failures` (1-based): base·2ⁿ⁻¹, capped.
    public func backoff(afterFailures failures: Int) -> Duration {
        var delay = backoffBase
        for _ in 1..<max(failures, 1) {
            delay *= 2
            if delay >= backoffMax { return backoffMax }
        }
        return min(delay, backoffMax)
    }
}

public enum HVFSupervisorOutcome: Sendable, Equatable {
    /// Stopped on request (SIGTERM/SIGINT).
    case stopped
    /// Gave up after repeated rapid failures.
    case failed(String)
    /// Another supervisor owns this root.
    case alreadyRunning(Int32?)
}

// MARK: - Supervisor

/// The one process that owns a root's micropod-vmm. It holds
/// `run/supervisor.lock` for its lifetime, launches the VMM with
/// `--parent-pid` of itself (so the VMM dies with it), publishes every
/// transition to `run/state.json`, relaunches after unexpected exits with
/// backoff, and powers the guest off gracefully when asked to stop.
///
/// Everything with a side effect outside the root — launching and
/// signalling processes, readiness probes — is injected, so the state
/// machine runs under test without a VM.
public actor HVFMachineSupervisor {
    public nonisolated let layout: HVFMachineLayout
    let config: HVFMachineConfig
    let policy: HVFSupervisorPolicy
    let launcher: any HVFVMMLaunching
    let inspector: any HVFProcessInspecting
    let readiness: @Sendable (URL) async -> Bool
    let log: @Sendable (String) -> Void
    let pid: Int32

    enum Event: Sendable {
        case exited(generation: Int, HVFVMMExit)
        case ready(generation: Int)
        case notReady(generation: Int)
        case backoffElapsed(generation: Int)
        case stopTimeout(generation: Int)
        case stopRequested
    }

    private let events: AsyncStream<Event>
    private nonisolated let continuation: AsyncStream<Event>.Continuation
    /// Set by `requestStop`, so `run` sees a stop that arrived during
    /// start-up before it launches anything.
    private nonisolated let stopRequestedEarly = Mutex(false)

    private var state: HVFMachineState
    /// Bumped per launch; events from an earlier launch are ignored.
    private var generation = 0
    private var process: (any HVFVMMProcess)?
    private var launchedAt: ContinuousClock.Instant?
    private var ready = false
    private var stopping = false
    /// The generation already sent SIGTERM: micropod-vmm treats a second
    /// SIGTERM as a forced stop, so one VMM gets at most one.
    private var terminatedGeneration: Int?
    private var pendingFailure: String?
    private var rapidFailures = 0
    private var tasks: [Task<Void, Never>] = []
    private var readinessTask: Task<Void, Never>?

    public init(
        layout: HVFMachineLayout, config: HVFMachineConfig, policy: HVFSupervisorPolicy = HVFSupervisorPolicy(),
        launcher: any HVFVMMLaunching, inspector: any HVFProcessInspecting = HVFDarwinProcessInspector(),
        readiness: @escaping @Sendable (URL) async -> Bool, log: @escaping @Sendable (String) -> Void,
        pid: Int32 = getpid()
    ) {
        self.layout = layout
        self.config = config
        self.policy = policy
        self.launcher = launcher
        self.inspector = inspector
        self.readiness = readiness
        self.log = log
        self.pid = pid
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        self.continuation = continuation
        state = HVFMachineState(
            phase: .starting, supervisorPID: pid, supervisorStartSeconds: inspector.facts(pid)?.startSeconds)
    }

    /// Asks a running supervisor to power the guest off and return. Safe
    /// from a signal handler's queue and before `run()` starts.
    public nonisolated func requestStop() {
        stopRequestedEarly.withLock { $0 = true }
        continuation.yield(.stopRequested)
    }

    /// Supervises until stopped or given up. Throws only for setup
    /// failures (lock I/O, an orphaned VMM that will not die, an install
    /// in progress).
    public func run() async throws -> HVFSupervisorOutcome {
        guard let lock = try HVFFileLock.acquire(layout.supervisorLock, wait: policy.lockWait) else {
            let owner = try? HVFMachineState.load(from: layout.state)
            return .alreadyRunning(owner?.supervisorPID)
        }
        defer {
            for task in tasks { task.cancel() }
            readinessTask?.cancel()
            continuation.finish()
            // Released last: a reader that sees the lock free reads the
            // final state.
            lock.release()
        }
        try lock.record(pid: pid)
        // `machine install` holds install.lock while it swaps the disk and
        // binaries; it checks this lock after taking its own, so one of the
        // two always sees the other.
        if layout.installInProgress {
            log("not starting: `micropod machine install` is running on \(layout.root.path)")
            throw layout.installInProgressError()
        }
        try FileManager.default.createDirectory(at: layout.logsDirectory, withIntermediateDirectories: true)
        try await reapOrphans()
        log("supervising \(layout.root.path) (pid \(pid), \(config.cpus) vCPU, \(config.memoryMiB) MiB)")
        if stopRequestedEarly.withLock({ $0 }) {
            log("stop requested before the first launch")
            return finishStopped(reason: "stopped before launch")
        }
        persist()
        launch()
        for await event in events {
            if let outcome = handle(event) { return outcome }
        }
        return .stopped
    }

    // MARK: Transitions

    private func handle(_ event: Event) -> HVFSupervisorOutcome? {
        switch event {
        case .ready(let g):
            guard g == generation, process != nil, !stopping, !ready else { return nil }
            ready = true
            state.phase = .running
            state.readyAt = Date()
            persist()
            log("ready: Docker API answering on \(layout.dockerSocket.path)")
        case .notReady(let g):
            guard g == generation, let process, !stopping, !ready else { return nil }
            let failure = "the Docker API did not answer within \(policy.readinessTimeout)"
            pendingFailure = failure
            log("\(failure); stopping micropod-vmm pid \(process.pid)")
            terminate(process)
        case .exited(let g, let exit):
            guard g == generation else { return nil }
            return exited(exit)
        case .backoffElapsed(let g):
            guard g == generation, process == nil, !stopping else { return nil }
            launch()
        case .stopTimeout(let g):
            guard g == generation, let process else { return nil }
            log("micropod-vmm pid \(process.pid) still running \(policy.stopTimeout) after SIGTERM; sending SIGKILL")
            process.signal(SIGKILL)
        case .stopRequested:
            guard !stopping else { return nil }
            stopping = true
            state.phase = .stopping
            persist()
            guard let process else {
                log("stop requested between launches")
                return finishStopped(reason: "stopped before relaunch")
            }
            if terminatedGeneration == generation {
                // A readiness timeout already asked this VMM to power off; a
                // second SIGTERM would force it. The scheduled SIGKILL stays.
                log("stop requested: micropod-vmm pid \(process.pid) is already powering off")
            } else {
                log("stop requested: SIGTERM to micropod-vmm pid \(process.pid) for a graceful guest poweroff")
                terminate(process)
            }
        }
        return nil
    }

    private func exited(_ exit: HVFVMMExit) -> HVFSupervisorOutcome? {
        let pid = process?.pid
        process = nil
        readinessTask?.cancel()
        readinessTask = nil
        state.vmmPID = nil
        state.vmmStartSeconds = nil
        state.lastExitCode = exit.code
        state.lastExitMeaning = exit.meaning
        if stopping {
            log("micropod-vmm\(pid.map { " pid \($0)" } ?? "") \(exit)")
            return finishStopped(reason: "stopped on request; micropod-vmm \(exit)")
        }
        let reason = [pendingFailure, "micropod-vmm \(exit)"].compactMap { $0 }.joined(separator: "; ")
        pendingFailure = nil
        state.lastExitReason = reason
        removeSocket()
        // A first launch that fails on its configuration fails the same way
        // every time. On a relaunch (the configuration has worked before) the
        // same failure may be transient — posix_spawn EAGAIN, a full disk for
        // the console log — so it backs off like any rapid failure, which
        // still gives up after `maxRapidFailures`.
        if exit.isConfigurationFailure, !ready, state.restartCount == 0 {
            state.phase = .failed
            persist()
            log("not relaunching after a configuration failure: \(reason)")
            return .failed(reason)
        }
        // Everything else (a guest crash or engine failure, a forced stop, a
        // kill, or a poweroff nobody asked for) is relaunched with backoff.
        let elapsed = launchedAt.map { ContinuousClock.now - $0 } ?? .zero
        let rapid = !ready || elapsed < policy.rapidFailureWindow
        rapidFailures = rapid ? rapidFailures + 1 : 1
        if rapidFailures >= policy.maxRapidFailures {
            state.phase = .failed
            persist()
            log("giving up after \(rapidFailures) rapid failures: \(reason)")
            return .failed(reason)
        }
        state.phase = .starting
        state.restartCount += 1
        persist()
        let delay = policy.backoff(afterFailures: rapidFailures)
        log("unexpected exit: \(reason); relaunching in \(delay) (restart \(state.restartCount))")
        schedule(.backoffElapsed(generation: generation), after: delay)
        return nil
    }

    private func finishStopped(reason: String) -> HVFSupervisorOutcome {
        state.phase = .stopped
        state.lastExitReason = reason
        persist()
        removeSocket()
        return .stopped
    }

    // MARK: Actions

    private func launch() {
        generation += 1
        let g = generation
        ready = false
        pendingFailure = nil
        launchedAt = .now
        removeSocket()
        let process: any HVFVMMProcess
        do {
            let arguments = try HVFVMMCommand.arguments(layout: layout, config: config, parentPID: pid)
            process = try launcher.launch(executable: layout.vmm, arguments: arguments)
        } catch {
            continuation.yield(.exited(generation: g, HVFVMMExit(launchError: error.localizedDescription)))
            return
        }
        self.process = process
        state.phase = .starting
        state.vmmPID = process.pid
        state.vmmStartSeconds = inspector.facts(process.pid)?.startSeconds
        state.startedAt = Date()
        state.readyAt = nil
        persist()
        log("launched micropod-vmm pid \(process.pid)")
        let continuation = self.continuation
        tasks.append(
            Task {
                let exit = await process.waitForExit()
                continuation.yield(.exited(generation: g, exit))
            })
        let readiness = self.readiness
        let socket = layout.dockerSocket
        let policy = self.policy
        readinessTask = Task {
            let deadline = ContinuousClock.now + policy.readinessTimeout
            while !Task.isCancelled {
                if await readiness(socket) {
                    continuation.yield(.ready(generation: g))
                    return
                }
                if ContinuousClock.now >= deadline {
                    continuation.yield(.notReady(generation: g))
                    return
                }
                do {
                    try await Task.sleep(for: policy.readinessInterval)
                } catch {
                    return  // cancelled: the launch it watched is over
                }
            }
        }
    }

    /// SIGTERM now, SIGKILL if the process outlives `stopTimeout`.
    private func terminate(_ process: any HVFVMMProcess) {
        terminatedGeneration = generation
        process.signal(SIGTERM)
        schedule(.stopTimeout(generation: generation), after: policy.stopTimeout)
    }

    private func schedule(_ event: Event, after delay: Duration) {
        let continuation = self.continuation
        tasks.append(
            Task {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return  // supervision ended
                }
                continuation.yield(event)
            })
    }

    private func persist() {
        state.updatedAt = Date()
        do {
            try state.save(to: layout.state)
        } catch {
            log("ERROR: could not write \(layout.state.path): \(error.localizedDescription)")
        }
    }

    /// Both exposed sockets: a VMM killed outright leaves its listeners'
    /// files behind (an orderly exit removes them itself).
    private func removeSocket() {
        for socket in [layout.dockerSocket, layout.buildkitSocket] where unlink(socket.path) != 0 && errno != ENOENT {
            log("ERROR: could not remove stale socket \(socket.path): \(String(cString: strerror(errno)))")
        }
    }

    // MARK: Orphans

    /// A micropod-vmm a dead supervisor left running holds the disk; two
    /// VMMs on one ext4 image would corrupt it. Only processes proven to be
    /// this root's VMM binary on this root's disk are signalled.
    private func reapOrphans() async throws {
        let recorded: HVFMachineState?
        do {
            recorded = try HVFMachineState.load(from: layout.state)
        } catch {
            log("WARNING: ignoring unreadable previous state: \(error.localizedDescription)")
            recorded = nil
        }
        var candidates: [HVFProcessFacts] = []
        if let vmm = recorded?.vmmPID, let facts = inspector.facts(vmm) { candidates.append(facts) }
        for other in inspector.processes(executable: HVFMachineLayout.canonicalPath(layout.vmm.path))
        where !candidates.contains(where: { $0.pid == other }) {
            if let facts = inspector.facts(other) { candidates.append(facts) }
        }
        for orphan in Self.orphans(among: candidates, layout: layout, supervisorPID: pid) {
            log("reaping orphaned micropod-vmm pid \(orphan) left by a previous supervisor")
            try await stopOrphan(orphan)
        }
    }

    /// The candidates that are this root's micropod-vmm: the exact binary
    /// under the root, booted from the root's disk. Name matches never count.
    static func orphans(among candidates: [HVFProcessFacts], layout: HVFMachineLayout, supervisorPID: Int32)
        -> [Int32]
    {
        let binary = HVFMachineLayout.canonicalPath(layout.vmm.path)
        let disk = HVFMachineLayout.canonicalPath(layout.disk.path)
        return candidates.filter { facts in
            guard facts.pid > 1, facts.pid != supervisorPID,
                let path = facts.executablePath, HVFMachineLayout.canonicalPath(path) == binary,
                let flag = facts.arguments.firstIndex(of: "--disk"), flag + 1 < facts.arguments.count
            else { return false }
            return HVFMachineLayout.canonicalPath(facts.arguments[flag + 1]) == disk
        }.map(\.pid)
    }

    private func stopOrphan(_ orphan: Int32) async throws {
        if let failure = inspector.signal(orphan, SIGTERM) {
            guard inspector.isAlive(orphan) else { return }
            throw MicropodError.message("internal: hvf: cannot signal orphaned micropod-vmm \(orphan): \(failure)")
        }
        let graceful = ContinuousClock.now + policy.stopTimeout
        while inspector.isAlive(orphan), ContinuousClock.now < graceful {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard inspector.isAlive(orphan) else { return }
        log("orphaned micropod-vmm pid \(orphan) ignored SIGTERM for \(policy.stopTimeout); sending SIGKILL")
        if let failure = inspector.signal(orphan, SIGKILL), inspector.isAlive(orphan) {
            throw MicropodError.message("internal: hvf: cannot kill orphaned micropod-vmm \(orphan): \(failure)")
        }
        let killed = ContinuousClock.now + .seconds(5)
        while inspector.isAlive(orphan), ContinuousClock.now < killed {
            try await Task.sleep(for: .milliseconds(50))
        }
        if inspector.isAlive(orphan) {
            throw MicropodError.message(
                "unavailable: hvf: orphaned micropod-vmm \(orphan) is still running on \(layout.disk.path)")
        }
    }
}

// MARK: - Foreground entry point

extension HVFMachineSupervisor {
    public static let consoleLogMaxBytes = 8 << 20
    public static let supervisorLogMaxBytes = 2 << 20

    /// `micropod machine serve`: supervise `layout` in this process until
    /// SIGTERM/SIGINT. Logs go to stderr (the detached launcher points that
    /// at `logs/supervisor.log`).
    public static func serve(layout: HVFMachineLayout, environment: [String: String]) async throws
        -> HVFSupervisorOutcome
    {
        let missing = layout.missingAssets()
        guard missing.isEmpty else {
            throw MicropodError.message(
                "failedPrecondition: hvf machine not installed under \(layout.root.path): missing "
                    + "\(missing.joined(separator: ", ")); run `micropod machine install`")
        }
        if let problem = layout.configurationProblem() { throw MicropodError.message("failedPrecondition: \(problem)") }
        let config = try HVFMachineConfig.load(from: layout.config)
        let log: @Sendable (String) -> Void = { stderrLog($0) }
        var childEnvironment = environment
        childEnvironment[ParentDeathWatch.parentPIDEnv] = nil
        var policy = HVFSupervisorPolicy()
        policy.stopTimeout = config.stopGrace
        let supervisor = HVFMachineSupervisor(
            layout: layout, config: config, policy: policy,
            launcher: HVFDarwinLauncher(
                consoleLog: layout.consoleLog, maxBytes: consoleLogMaxBytes, environment: childEnvironment,
                report: log),
            readiness: { await HVFMachineClient.ping($0) }, log: log)
        signal(SIGPIPE, SIG_IGN)
        var sources: [any DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { supervisor.requestStop() }
            source.resume()
            sources.append(source)
        }
        defer { for source in sources { source.cancel() } }
        return try await supervisor.run()
    }

    /// The foreground supervisor's log sink: one timestamped line to stderr
    /// (`logs/supervisor.log` when detached). A failed write — a full disk,
    /// a closed pipe — loses the line and never aborts supervision.
    static func stderrLog(_ line: String, to fd: Int32 = STDERR_FILENO) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        HVFFiles.writeBestEffort(Data("\(stamp) hvf-supervisor: \(line)\n".utf8), to: fd)
    }
}

// MARK: - Real VMM processes

/// Launches micropod-vmm in its own process group with stdout+stderr
/// captured into the capped console log.
public struct HVFDarwinLauncher: HVFVMMLaunching {
    public let consoleLog: URL
    public let maxBytes: Int
    public let environment: [String: String]
    let report: @Sendable (String) -> Void

    public init(
        consoleLog: URL, maxBytes: Int, environment: [String: String], report: @escaping @Sendable (String) -> Void
    ) {
        self.consoleLog = consoleLog
        self.maxBytes = maxBytes
        self.environment = environment
        self.report = report
    }

    public func launch(executable: URL, arguments: [String]) throws -> any HVFVMMProcess {
        let log = try HVFRotatingLog(url: consoleLog, maxBytes: maxBytes)
        let quoted = arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        do {
            // A header the log cannot take must not keep the machine down.
            try log.append(Data("\n=== \(Date()) launching \(executable.path) \(quoted)\n".utf8))
        } catch {
            report("WARNING: console log: \(error.localizedDescription)")
        }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw HVFFiles.posixError("pipe") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let pid: pid_t
        do {
            pid = try HVFSpawn.spawn(
                executable: executable.path, arguments: arguments, environment: environment, output: fds[1],
                newSession: false)
        } catch {
            close(fds[0])
            close(fds[1])
            throw error
        }
        close(fds[1])
        return HVFDarwinVMMProcess(pid: pid, output: fds[0], log: log, report: report)
    }
}

/// A spawned micropod-vmm: a reader thread drains its output into the
/// console log; a waiter thread observes the exit with `WNOWAIT` first, so
/// `signal` can never hit a recycled pid, then reaps it.
final class HVFDarwinVMMProcess: HVFVMMProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var exited = false
    private var result: HVFVMMExit?
    private var waiters: [CheckedContinuation<HVFVMMExit, Never>] = []
    private var summary: String?
    private var guestStatus: String?
    private let drained = DispatchSemaphore(value: 0)

    init(pid: Int32, output: Int32, log: HVFRotatingLog, report: @escaping @Sendable (String) -> Void) {
        self.pid = pid
        Thread.detachNewThread { [self] in drain(output, into: log, report: report) }
        Thread.detachNewThread { [self] in awaitExit(report: report) }
    }

    func waitForExit() async -> HVFVMMExit {
        await withCheckedContinuation { continuation in
            let ready: HVFVMMExit? = lock.withLock {
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func signal(_ signal: Int32) {
        lock.withLock {
            guard !exited else { return }
            _ = kill(pid, signal)
        }
    }

    private func drain(_ fd: Int32, into log: HVFRotatingLog, report: @Sendable (String) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var line = Data()
        var logFailed = false
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            let chunk = Data(buffer[0..<n])
            do {
                try log.append(chunk)
            } catch {
                if !logFailed { report("ERROR: console log: \(error.localizedDescription)") }
                logFailed = true
            }
            for byte in chunk {
                if byte == 0x0A {
                    noteSummary(line)
                    line.removeAll(keepingCapacity: true)
                } else if line.count < 16384 {
                    line.append(byte)
                }
            }
        }
        noteSummary(line)
        close(fd)
        log.close()
        drained.signal()
    }

    /// The `--json-summary` line micropod-vmm prints as it exits, and the
    /// failure guest init reports before it stops.
    private func noteSummary(_ line: Data) {
        if let status = Self.guestStatus(in: line) {
            lock.withLock { guestStatus = status }
            return
        }
        guard line.starts(with: Data(#"{"exit_reason""#.utf8)),
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let reason = object["exit_reason"] as? String
        else { return }
        let failure = (object["guest_failure"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        lock.withLock {
            summary = reason
            if guestStatus == nil { guestStatus = failure }
        }
    }

    static let guestStatusMarker = "MICROPOD_VMM_GUEST_STATUS "

    /// `MICROPOD_VMM_GUEST_STATUS <kind> <detail>` anywhere on a console line.
    static func guestStatus(in line: Data) -> String? {
        let text = String(decoding: line, as: UTF8.self)
        guard let range = text.range(of: guestStatusMarker) else { return nil }
        let detail = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? nil : String(detail.prefix(200))
    }

    private func awaitExit(report: @Sendable (String) -> Void) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        // Still a zombie: the pid cannot be reused until the waitpid below.
        lock.withLock { exited = true }
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        if reaped < 0 { report("ERROR: waitpid \(pid): \(String(cString: strerror(errno)))") }
        // A grandchild holding the pipe must not wedge exit handling.
        if drained.wait(timeout: .now() + 2) == .timedOut {
            report("WARNING: micropod-vmm output still open 2s after exit")
        }
        let (code, signal) = reaped < 0 ? (nil, nil) : HVFSpawn.describe(status: status)
        let (exit, waiting) = lock.withLock { () -> (HVFVMMExit, [CheckedContinuation<HVFVMMExit, Never>]) in
            let exit = HVFVMMExit(code: code, signal: signal, summary: summary, guestStatus: guestStatus)
            result = exit
            defer { waiters.removeAll() }
            return (exit, waiters)
        }
        for waiter in waiting { waiter.resume(returning: exit) }
    }
}
