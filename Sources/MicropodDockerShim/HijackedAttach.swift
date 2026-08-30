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
/// **stdin is drained, not forwarded.** `--interactive` exists but the shim has
/// no duplex path to it here; we consume the hijacked inbound stream so the
/// client never blocks on a full send buffer, and drop it.
final class AttachRegistry: @unchecked Sendable {
    static let shared = AttachRegistry()
    private let lock = NSLock()
    private var pending: [String: ShimConnection] = [:]

    /// Parks a hijacked connection until `/start` claims it.
    func park(containerID: String, connection: ShimConnection) {
        lock.lock()
        pending[containerID] = connection
        lock.unlock()
    }

    /// Removes and returns the parked connection, if any.
    func claim(containerID: String) -> ShimConnection? {
        lock.lock()
        let connection = pending.removeValue(forKey: containerID)
        lock.unlock()
        return connection
    }

    func discard(containerID: String) {
        lock.lock()
        pending.removeValue(forKey: containerID)
        lock.unlock()
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
final class AttachSession: @unchecked Sendable {
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

    /// Launches the attached run and streams it to `connection`. Returns once
    /// the process is spawned — the pump and exit bookkeeping continue in the
    /// background so `/start` can answer 204 immediately, as Docker does.
    func launchAndPump(connection: ShimConnection) throws {
        AttachRegistry.shared.markRunning(containerID: containerID)
        do {
            try process.run()
        } catch {
            AttachRegistry.shared.clearRunning(containerID: containerID)
            throw error
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = makePump(
            connection: connection, frameType: 1)
        stderrPipe.fileHandleForReading.readabilityHandler = makePump(
            connection: connection, frameType: 2)

        let watcher = Thread { [self] in
            process.waitUntilExit()
            let code = Int(process.terminationStatus)
            // Drain whatever the handlers had not picked up before closing;
            // a fast container can exit before the first readability event.
            let restOut = stdoutPipe.fileHandleForReading.availableData
            let restErr = stderrPipe.fileHandleForReading.availableData
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task.detached { [self] in
                if !restOut.isEmpty {
                    _ = await connection.write(Self.encode(restOut, frameType: 1, tty: tty))
                }
                if !restErr.isEmpty {
                    _ = await connection.write(Self.encode(restErr, frameType: 2, tty: tty))
                }
                // Recorded before the socket closes: the client's `/wait` is
                // already blocked and will read this the moment it sees the
                // container stop.
                await state.noteExit(id: containerID, code: code)
                AttachRegistry.shared.clearRunning(containerID: containerID)
                // Close first: the client is waiting on end-of-stream, and
                // AutoRemove deletion is a runtime round-trip.
                connection.close()
                await onExit(code)
            }
        }
        watcher.name = "shim-attach-wait"
        watcher.start()
    }

    private static func encode(_ data: Data, frameType: UInt8, tty: Bool) -> Data {
        tty ? data : ExecSession.frame(type: frameType, payload: data)
    }

    private func makePump(connection: ShimConnection, frameType: UInt8)
        -> @Sendable (FileHandle) -> Void
    {
        let isTTY = tty
        return { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            let payload = AttachSession.encode(data, frameType: frameType, tty: isTTY)
            Task { _ = await connection.write(payload) }
        }
    }
}
