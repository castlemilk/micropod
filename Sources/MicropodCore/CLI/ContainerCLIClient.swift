import Darwin
import Foundation
import OSLog

/// Executes `container` CLI commands.
///
/// Short-lived commands run to completion with output captured in temp files
/// (pipe deadlock avoidance — the storagesentry lesson), while long-lived
/// commands (`logs -f`, builds, pulls) stream through pipes.
///
/// A struct (not an actor): every call spawns its own `Process` and touches
/// no shared mutable state, so concurrent callers run their CLIs in parallel
/// instead of queueing behind a single actor mailbox. This is what lets the
/// Docker shim serve concurrent lifecycles without serialising them.
public struct ContainerCLIClient: Sendable {
    public let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/local/bin/container")) {
        self.executableURL = executableURL
    }

    /// Instruments signposts so `xctrace record --template "os_signpost"`
    /// splits CLI spawn+XPC+run time from caller overhead (perf workstream).
    private static let signposter = OSSignposter(
        subsystem: "com.micropod.cli", category: .pointsOfInterest)

    /// Whether the `container` binary exists on disk.
    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// Runs a command to completion and returns its stdout.
    /// Stderr is captured and surfaced only on failure.
    public func run(_ command: ContainerCommand, timeout: Duration = .seconds(60)) async throws -> String {
        try Task.checkCancellation()
        let started = Date()
        let signpostState = Self.signposter.beginInterval(
            "cli", "\(command.displayName, privacy: .public)")
        defer {
            Self.signposter.endInterval("cli", signpostState)
        }
        var metricStatus = 0
        defer {
            CLIMetrics.record(
                command: command.metricLabel, status: metricStatus,
                duration: Date().timeIntervalSince(started))
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-out-\(UUID().uuidString)")
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-err-\(UUID().uuidString)")
        // FileHandle(forWritingTo:) opens an existing file — create them first.
        guard
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
            let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
            let stderrHandle = try? FileHandle(forWritingTo: stderrURL)
        else {
            throw MicropodError.cliUnavailable(executableURL.path)
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        if let stdinData = command.stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                // The process may have exited before consuming stdin; ignore.
            }
        }

        // Process is not Sendable; run off the cooperative pool at
        // userInitiated priority (utility QoS starves under load and adds
        // hundreds of ms of launch latency).
        let cancellation = ProcessCancellationController()
        let gate = FinishGate()
        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try cancellation.launch(process)
                        } catch {
                            gate.runOnce { continuation.resume(throwing: error) }
                            return
                        }
                        // Instant exit detection — no polling latency.
                        process.terminationHandler = { _ in
                            let outcome = cancellation.outcome(
                                exitCode: process.terminationStatus,
                                cancelledWhileRunning: cancellation.cancelTerminated,
                                timedOut: cancellation.timeoutTerminated)
                            switch outcome {
                            case .cancelled:
                                gate.runOnce { continuation.resume(throwing: CancellationError()) }
                            case .timedOut:
                                gate.runOnce {
                                    continuation.resume(
                                        throwing: MicropodError.message(
                                            "`container` command timed out after \(timeout): \(command.displayName)"))
                                }
                            case .exited(let code):
                                gate.runOnce { continuation.resume(returning: code) }
                            }
                        }
                        // Exceptional-exit watchdog only: cancellation or timeout
                        // must terminate the process; natural exits are handled
                        // by the termination handler above.
                        let components = timeout.components
                        let deadline = Date().addingTimeInterval(
                            Double(components.seconds) + Double(components.attoseconds) / 1e18)
                        Thread.detachNewThread {
                            while process.isRunning {
                                if cancellation.shouldCancel(process) {
                                    cancellation.cancelTerminated = true
                                    terminateAndReap(process)
                                    return
                                }
                                if Date() >= deadline, process.isRunning {
                                    cancellation.timeoutTerminated = true
                                    terminateAndReap(process)
                                    return
                                }
                                Thread.sleep(forTimeInterval: 0.02)
                            }
                        }
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            metricStatus = Int(exitCode)
        } catch {
            // Timeout and cancellation are classified by the cancellation
            // controller's flags (504/499); anything else is a launch/run
            // failure (status 1).
            if cancellation.timeoutTerminated {
                metricStatus = 504
            } else if cancellation.cancelTerminated {
                metricStatus = 499
            } else {
                metricStatus = 1
            }
            throw error
        }

        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        guard exitCode == 0 else {
            throw MicropodError.cliFailure(
                command: command.displayName, exitCode: exitCode, stderr: stderr)
        }
        return stdout
    }

    /// Runs a long-lived command and streams its combined stdout+stderr output.
    /// The stream terminates when the process exits or the task is cancelled.
    ///
    /// - Parameter reportExitCode: when true, a non-zero exit surfaces as
    ///   `MicropodError.cliFailure` at stream end instead of a clean finish.
    ///   Opt-in because log tails (`logs -f`) treat process end as data end,
    ///   while pull/push/build progress must not report success when the CLI
    ///   failed (the exit status is otherwise invisible — both pipes merge
    ///   into yielded chunks).
    public func stream(_ command: ContainerCommand, reportExitCode: Bool = false)
        -> AsyncThrowingStream<Data, Error>
    {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = command.arguments
            process.environment = ProcessInfo.processInfo.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let cancellation = ProcessCancellationController()
            let callerWasCancelled = withUnsafeCurrentTask { task in
                task?.isCancelled ?? false
            }
            if callerWasCancelled { cancellation.cancel() }
            let gate = FinishGate()
            continuation.onTermination = { _ in
                cancellation.cancel()
            }

            func pump(_ handle: FileHandle) {
                // Blocking reads on detached threads never observe data written
                // to a long-lived pipe (verified against the real runtime);
                // readabilityHandler is the reliable async callback.
                handle.readabilityHandler = { h in
                    let data = h.availableData
                    if data.isEmpty {
                        h.readabilityHandler = nil
                        try? h.close()
                    } else {
                        continuation.yield(data)
                    }
                }
            }

            let stdoutFd = stdoutPipe.fileHandleForReading
            let stderrFd = stderrPipe.fileHandleForReading
            pump(stdoutFd)
            pump(stderrFd)

            do {
                try cancellation.launch(process)
            } catch {
                let launchError = error
                gate.runOnce { continuation.finish(throwing: launchError) }
                return
            }

            // The watcher is the sole process reaper. Cancellation only flips
            // the controller flag; the watcher owns TERM, KILL, wait, and finish.
            Thread.detachNewThread {
                var cancelledWhileRunning = false
                while process.isRunning {
                    if cancellation.shouldCancel(process) {
                        cancelledWhileRunning = true
                        terminateAndReap(process)
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if !cancelledWhileRunning { process.waitUntilExit() }
                let wasCancelledWhileRunning = cancelledWhileRunning
                let exitCode = process.terminationStatus
                let displayName = command.displayName
                gate.runOnce {
                    if wasCancelledWhileRunning {
                        continuation.finish(throwing: CancellationError())
                    } else if reportExitCode, exitCode != 0 {
                        continuation.finish(
                            throwing: MicropodError.cliFailure(
                                command: displayName, exitCode: exitCode, stderr: ""))
                    } else {
                        continuation.finish()
                    }
                }
            }
        }
    }
}

final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelTerminatedFlag = false
    private var timeoutTerminatedFlag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var cancelTerminated: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cancelTerminatedFlag
        }
        set {
            lock.lock()
            cancelTerminatedFlag = newValue
            lock.unlock()
        }
    }

    var timeoutTerminated: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return timeoutTerminatedFlag
        }
        set {
            lock.lock()
            timeoutTerminatedFlag = newValue
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func shouldCancel(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled && process.isRunning
    }

    /// Holds the cancellation lock across the pre-check and process launch so a
    /// cancellation request can never slip between those two operations.
    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func outcome(
        exitCode: Int32,
        cancelledWhileRunning: Bool,
        timedOut: Bool
    ) -> ProcessRunOutcome {
        if cancelledWhileRunning { return .cancelled }
        if timedOut { return .timedOut }
        return .exited(exitCode)
    }
}

enum ProcessRunOutcome: Equatable {
    case exited(Int32)
    case cancelled
    case timedOut
}

private func terminateAndReap(_ process: Process) {
    if process.isRunning { process.terminate() }

    let graceDeadline = Date().addingTimeInterval(0.15)
    while process.isRunning, Date() < graceDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}

/// Runs a side effect exactly once, thread-safely.
private final class FinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func runOnce(_ action: @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        action()
    }
}
