import Foundation
import MicropodCore

/// Docker's `POST /containers/{id}/attach` hijack, backed by
/// `container start --attach`.
///
/// This is the endpoint `docker run` (foreground) and `docker start -a` need —
/// without it the CLI fails with "unable to upgrade to tcp, received 404", so
/// any caller that shells out to the docker CLI rather than using an SDK
/// cannot run a container through the shim at all.
///
/// **Why `start --attach` and not the log follow.** The Apple runtime exposes
/// no exit code on a stopped container — `container inspect` reports only
/// `state: "stopped"`. The one place the runtime *does* surface it is the exit
/// status of an attached foreground run. Synthesizing attach from
/// `container logs --follow` therefore reports every container as exit 0,
/// which in CI turns a failing build green. `container start --attach` streams
/// stdout/stderr *and* exits with the container's code, so it gives us both.
///
/// **Ordering.** Docker's model is attach-then-start: the client hijacks the
/// connection first and issues `/start` after. The runtime's model is the
/// opposite — the attach *is* the start. So `/attach` only parks the hijacked
/// connection here, and `/start` claims it and launches the attached run. A
/// `/start` with no parked connection is an ordinary detached start.
///
/// **The start must settle before `/start` answers.** `container start
/// --attach` is the start: when the runtime refuses it (a volume image another
/// VM holds, the RW multi-attach guard's `failedPrecondition`) the CLI prints
/// its `Error:` line and exits without the container ever running. dockerd
/// answers `/start` only once the container runs, so the router holds the
/// response until the container is seen to have run, or the CLI has exited
/// without it running — a refusal, which the start response reports and the
/// attach stream ends on. Until then the session holds the run's output: it
/// may be nothing but the CLI's refusal, which is not the container's output.
///
/// **stdin is drained, not forwarded.** `--interactive` exists but the shim has
/// no duplex path to it here; we consume the hijacked inbound stream so the
/// client never blocks on a full send buffer, and drop it.
final class AttachRegistry: @unchecked Sendable {
    static let shared = AttachRegistry()
    private let lock = NSLock()
    private var pending: [String: (connection: ShimConnection, parkedAt: Date)] = [:]
    /// Parked attaches expire: a client that hijacks /attach but never
    /// follows with /start (crashed between the calls) must not pin the
    /// connection — and its file descriptor — forever.
    private static let parkTTL: TimeInterval = 120

    /// Parks a hijacked connection until `/start` claims it.
    func park(containerID: String, connection: ShimConnection) {
        lock.lock()
        sweepLocked()
        pending[containerID] = (connection, Date())
        lock.unlock()
    }

    /// Removes and returns the parked connection, if any (expired entries
    /// are treated as absent and closed).
    func claim(containerID: String) -> ShimConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard let parked = pending.removeValue(forKey: containerID) else { return nil }
        if Date().timeIntervalSince(parked.parkedAt) > Self.parkTTL {
            parked.connection.close()
            return nil
        }
        return parked.connection
    }

    func discard(containerID: String) {
        lock.lock()
        defer { lock.unlock() }
        if let parked = pending.removeValue(forKey: containerID) {
            parked.connection.close()
        }
    }

    /// Drops expired parks (lock must be held).
    private func sweepLocked() {
        let now = Date()
        for (id, parked) in pending where now.timeIntervalSince(parked.parkedAt) > Self.parkTTL {
            parked.connection.close()
            pending.removeValue(forKey: id)
        }
    }

    // MARK: - In-flight attached runs

    private var inFlight: Set<String> = []

    func markRunning(containerID: String) {
        lock.lock()
        inFlight.insert(containerID)
        lock.unlock()
    }

    func clearRunning(containerID: String) {
        lock.lock()
        inFlight.remove(containerID)
        lock.unlock()
    }

    /// Whether an attached run is still resolving this container's exit code.
    ///
    /// The container reaches "stopped" fractionally before
    /// `container start --attach` exits and reports its status, so a `/wait`
    /// polling on state alone returns 0 for a container that actually failed —
    /// a green CI run for a red build. `/wait` consults this to hold until the
    /// real code is recorded.
    func isRunning(containerID: String) -> Bool {
        lock.lock()
        let running = inFlight.contains(containerID)
        lock.unlock()
        return running
    }
}

/// Runs `container start --attach <id>` and pumps its output into a hijacked
/// Docker connection, recording the real exit code when it finishes.
///
/// The router settles the start (`admit` once the container has run, `refuse`
/// when the runtime would not start it); until then output is held, and the
/// exit bookkeeping waits for the verdict.
final class AttachSession: @unchecked Sendable {
    /// How the start settled, as the router decided it.
    enum Disposition: Sendable {
        /// The container ran: stream its output, record its exit code.
        case started
        /// The runtime refused the start: drop the held output, record no
        /// exit code, end the attach stream.
        case refused
    }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let containerID: String
    private let tty: Bool
    private let state: ShimState
    /// Run after the exit code is recorded and before the socket closes —
    /// where AutoRemove is honored. The events loop cannot do it: it gates
    /// reaping on this run being finished, and by the time it is, the
    /// container is no longer a state *transition* the loop would notice.
    private let onExit: @Sendable (Int) async -> Void

    /// Guards everything below.
    private let lock = NSLock()
    private var connection: ShimConnection?
    private enum OutputGate {
        /// Start not settled: framed output accumulates in `held`.
        case holding
        /// `held` has been handed to the connection; output goes straight out.
        case open
        /// The start was refused: output is discarded.
        case dropped
    }
    private var gate = OutputGate.holding
    private var held = Data()
    /// The CLI's stderr, bounded: where its `Error:` line for a refused start
    /// is (an attached run's stderr is otherwise the guest's).
    private var capturedStderr = Data()
    private static let stderrCaptureLimit = 64 * 1024
    private var exitStatus: Int32?
    private var disposition: Disposition?
    private var dispositionWaiters: [CheckedContinuation<Disposition, Never>] = []

    init(
        cliPath: String, containerID: String, tty: Bool, state: ShimState,
        onExit: @escaping @Sendable (Int) async -> Void
    ) {
        self.containerID = containerID
        self.tty = tty
        self.state = state
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["start", "--attach", containerID]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
    }

    /// Launches the attached run, pumping it towards `connection`. Returns
    /// once the process is spawned; the router then settles the start
    /// (`admit` / `refuse`) and the pump and exit bookkeeping continue in the
    /// background.
    func launchAndPump(connection: ShimConnection) throws {
        lock.lock()
        self.connection = connection
        lock.unlock()
        AttachRegistry.shared.markRunning(containerID: containerID)
        do {
            try process.run()
        } catch {
            AttachRegistry.shared.clearRunning(containerID: containerID)
            throw error
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = makePump(frameType: 1)
        stderrPipe.fileHandleForReading.readabilityHandler = makePump(frameType: 2)

        let watcher = Thread { [self] in
            process.waitUntilExit()
            let code = process.terminationStatus
            // Detach handlers first, then drain without blocking: the parent
            // still holds the pipes' write ends open, so a blocking read
            // on an empty pipe waits forever (EOF never arrives) and the
            // client's `docker start -a` hangs despite the container
            // having exited.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let restOut = Self.drainWithoutBlocking(stdoutPipe.fileHandleForReading)
            let restErr = Self.drainWithoutBlocking(stderrPipe.fileHandleForReading)
            // Best-effort trailing output: `deliver` never waits on the
            // connection, so it cannot gate the close. (Awaiting a write
            // group here once wedged the close forever — `withTaskGroup`
            // joins all children, so a stuck write outlives the timeout
            // despite `cancelAll`.)
            deliver(restOut, frameType: 1)
            deliver(restErr, frameType: 2)
            // Recorded only after all of stderr is captured: a refused start
            // is classified from the CLI's complete `Error:` line.
            lock.lock()
            exitStatus = code
            lock.unlock()
            Task.detached { [self] in
                switch await settled() {
                case .refused:
                    // `refuse` already ended the stream; no exit code is
                    // recorded for a container that never ran.
                    AttachRegistry.shared.clearRunning(containerID: containerID)
                    closeSessionPipes()
                case .started:
                    // Drain window for the trailing output, then close
                    // unconditionally: the client is waiting on end-of-stream
                    // to exit.
                    try? await Task.sleep(for: .seconds(2))
                    // Recorded before the socket closes: the client's `/wait`
                    // is already blocked and will read this the moment it sees
                    // the container stop.
                    await state.noteExit(id: containerID, code: Int(code))
                    AttachRegistry.shared.clearRunning(containerID: containerID)
                    // Close first: the client is waiting on end-of-stream, and
                    // AutoRemove deletion is a runtime round-trip.
                    connection.close()
                    closeSessionPipes()
                    await onExit(Int(code))
                }
            }
        }
        watcher.name = "shim-attach-wait"
        watcher.start()
    }

    /// The CLI's exit status once it has exited (and all its output has been
    /// pumped), nil while it runs.
    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    /// The CLI's failure as the runtime worded it: its exit status and stderr.
    func failure(exitCode: Int32) -> MicropodError {
        lock.lock()
        let stderr = String(decoding: capturedStderr, as: UTF8.self)
        lock.unlock()
        return .cliFailure(
            command: "container start --attach \(containerID)", exitCode: exitCode, stderr: stderr)
    }

    /// The start went through: hand the held output to the client, in order,
    /// then stream live. Never waits on the client — the handover runs in its
    /// own task, and output arriving meanwhile queues behind it.
    func admit() {
        settle(.started)
        lock.lock()
        let connection = self.connection
        lock.unlock()
        Task.detached { [self] in
            while let chunk = takeHeldOrOpen() {
                _ = await connection?.write(chunk)
            }
        }
    }

    /// The output held so far (emptying the hold), or nil — with the gate
    /// opened — once nothing is left to hand over.
    private func takeHeldOrOpen() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !held.isEmpty else {
            gate = .open
            return nil
        }
        let chunk = held
        held = Data()
        return chunk
    }

    /// The runtime refused the start: drop the held output (it is the CLI's
    /// refusal, not the container's) and end the attach stream now.
    func refuse() {
        lock.lock()
        gate = .dropped
        held = Data()
        let connection = self.connection
        lock.unlock()
        settle(.refused)
        connection?.close()
    }

    /// Stops a CLI whose start never settled (see the router's settle bound).
    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func settle(_ outcome: Disposition) {
        lock.lock()
        guard disposition == nil else {
            lock.unlock()
            return
        }
        disposition = outcome
        let waiters = dispositionWaiters
        dispositionWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    private func settled() async -> Disposition {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let disposition {
                lock.unlock()
                continuation.resume(returning: disposition)
                return
            }
            dispositionWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Routes one chunk of the run's output by the gate, capturing stderr.
    private func deliver(_ data: Data, frameType: UInt8) {
        guard !data.isEmpty else { return }
        let payload = Self.encode(data, frameType: frameType, tty: tty)
        lock.lock()
        if frameType == 2, capturedStderr.count < Self.stderrCaptureLimit {
            capturedStderr.append(data.prefix(Self.stderrCaptureLimit - capturedStderr.count))
        }
        switch gate {
        case .holding:
            held.append(payload)
            lock.unlock()
        case .open:
            let connection = self.connection
            lock.unlock()
            Task { _ = await connection?.write(payload) }
        case .dropped:
            lock.unlock()
        }
    }

    private static func encode(_ data: Data, frameType: UInt8, tty: Bool) -> Data {
        tty ? data : ExecSession.frame(type: frameType, payload: data)
    }

    /// Deterministic pipe teardown (see ExecSession.closePipes): the session
    /// may outlive its usefulness on long-lived threads whose
    /// autoreleasepools drain late, showing up as pipe-fd creep under load.
    /// Called after the trailing flush is queued; the flush holds its own
    /// Data copies, so closing here cannot truncate it.
    private func closeSessionPipes() {
        for handle in [
            stdoutPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting,
            stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting,
        ] {
            try? handle.close()
        }
    }

    /// Non-blocking pipe drain: returns buffered bytes if any, empty
    /// otherwise — never waits. A blocking read on an empty pipe whose
    /// write end we still hold never returns (no EOF), hanging the watcher
    /// thread and with it the client's `docker start -a`.
    private static func drainWithoutBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let orig = Darwin.fcntl(fd, F_GETFL)
        // If flags cannot be read or non-blocking cannot be set, return
        // empty rather than risk a blocking read on a live pipe.
        guard orig >= 0, Darwin.fcntl(fd, F_SETFL, orig | O_NONBLOCK) != -1 else {
            return Data()
        }
        defer {
            _ = Darwin.fcntl(fd, F_SETFL, orig)
        }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
                if n < buffer.count { break }
            } else {
                break
            }
        }
        return out
    }

    private func makePump(frameType: UInt8) -> @Sendable (FileHandle) -> Void {
        { [self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            deliver(data, frameType: frameType)
        }
    }
}
