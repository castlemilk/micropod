import Foundation
import MicropodCore

struct DockerExecCreate: Codable {
    var AttachStdin: Bool?
    var AttachStdout: Bool?
    var AttachStderr: Bool?
    var DetachKeys: String?
    var Tty: Bool?
    var Env: [String]?
    var Cmd: [String]?
    var Privileged: Bool?
    var User: String?
    var WorkingDir: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        AttachStdin = try? c.decodeIfPresent(Bool.self, forKey: .AttachStdin)
        AttachStdout = try? c.decodeIfPresent(Bool.self, forKey: .AttachStdout)
        AttachStderr = try? c.decodeIfPresent(Bool.self, forKey: .AttachStderr)
        DetachKeys = try? c.decodeIfPresent(String.self, forKey: .DetachKeys)
        Tty = try? c.decodeIfPresent(Bool.self, forKey: .Tty)
        Env = try? c.decodeIfPresent([String].self, forKey: .Env)
        Cmd = try? c.decodeIfPresent([String].self, forKey: .Cmd)
        Privileged = try? c.decodeIfPresent(Bool.self, forKey: .Privileged)
        if let userObject = try? c.nestedContainer(keyedBy: UserKeys.self, forKey: .User) {
            let username = try? userObject.decodeIfPresent(String.self, forKey: .username)
            if let mode = (try? userObject.decodeIfPresent(String.self, forKey: .mode)) ?? nil {
                User = "\(mode):\(username ?? "")"
            } else {
                User = username
            }
        }
        WorkingDir = try? c.decodeIfPresent(String.self, forKey: .WorkingDir)
    }

    enum CodingKeys: String, CodingKey {
        case AttachStdin, AttachStdout, AttachStderr, DetachKeys, Tty, Env, Cmd
        case Privileged, User, WorkingDir
    }

    enum UserKeys: String, CodingKey { case username, mode }
}

/// Tracks live exec sessions so shutdown can kill orphaned CLI children.
final class ExecRegistry: @unchecked Sendable {
    static let shared = ExecRegistry()
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: ExecSession] = [:]

    func add(_ session: ExecSession) {
        lock.lock()
        sessions[ObjectIdentifier(session)] = session
        lock.unlock()
    }

    func remove(_ session: ExecSession) {
        lock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let live = sessions.values
        lock.unlock()
        for session in live {
            session.killChild()
        }
    }
}

/// Runs `container exec` as a raw duplex process for Docker's hijacked
/// POST /exec/{id}/start flow: client bytes → process stdin; process
/// stdout+stderr → client socket, stdcopy-framed unless Tty.
final class ExecSession: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let tty: Bool
    private let attachStdin: Bool
    private let execID: String
    private let state: ShimState
    /// Bounded tail of the child's stderr (for exit-code mapping only —
    /// the full stream still goes to the client).
    private let stderrLock = NSLock()
    private var stderrTail = Data()

    /// Docker-conventional exec exit codes (runc parity): 126 = found but
    /// not executable, 127 = executable not found. The Apple CLI reports
    /// both as process failure (typically exit 1) with distinctive stderr
    /// ("failed to find target executable …" / "… failed to start process …
    /// Permission denied"), so the distinction has to be recovered from the
    /// text. Genuine in-container exits pass through untouched — only a
    /// nonzero CLI status *plus* a start-failure marker remaps. Clients key
    /// behavior off this: testcontainers' port readiness treats 127 as
    /// "no shell, skip the internal check" but retries anything else
    /// forever.
    static func dockerExitCode(cliStatus: Int32, stderr: String) -> Int {
        guard cliStatus != 0 else { return 0 }
        let text = stderr.lowercased()
        if text.contains("failed to find target executable") { return 127 }
        if text.contains("failed to start process")
            && (text.contains("permission denied") || text.contains("code=13"))
        {
            return 126
        }
        return Int(cliStatus)
    }

    init(
        cliPath: String, containerID: String, request: DockerExecCreate,
        execID: String, state: ShimState
    ) throws {
        self.tty = request.Tty == true
        self.attachStdin = request.AttachStdin == true
        self.execID = execID
        self.state = state
        process.executableURL = URL(fileURLWithPath: cliPath)
        var arguments = ["exec"]
        if tty { arguments.append("--tty") }
        if let user = request.User, !user.isEmpty { arguments += ["--user", user] }
        if let workdir = request.WorkingDir, !workdir.isEmpty { arguments += ["--workdir", workdir] }
        for env in request.Env ?? [] { arguments += ["--env", env] }
        arguments.append(containerID)
        arguments.append(contentsOf: request.Cmd ?? [])
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = request.AttachStdin == true ? stdinPipe : FileHandle.nullDevice
    }

    func launchAndPump(connection: ShimConnection) throws {
        try process.run()
        ExecRegistry.shared.add(self)

        let inbound = connection.beginHijack()
        let attachStdin = self.attachStdin
        if attachStdin {
            let writeHandle = stdinPipe.fileHandleForWriting
            Task.detached(priority: .userInitiated) {
                for await data in inbound {
                    do { try writeHandle.write(contentsOf: data) } catch { break }
                }
                try? writeHandle.close()
            }
        } else {
            Task.detached(priority: .utility) {
                for await _ in inbound {}
            }
        }

        let outStream = stdoutPipe.fileHandleForReading
        outStream.readabilityHandler = makePump(connection: connection, frameType: 1)
        let errStream = stderrPipe.fileHandleForReading
        errStream.readabilityHandler = makePump(connection: connection, frameType: 2)

        // Strong capture: the session must outlive the child process.
        let exitWatcher = Thread { [self] in
            awaitExit(connection: connection)
        }
        exitWatcher.name = "shim-exec-wait"
        exitWatcher.start()
    }

    private func makePump(connection: ShimConnection, frameType: UInt8)
        -> @Sendable (FileHandle)
        -> Void
    {
        let isTTY = tty
        // frameType 2 == stderr: retain a bounded tail for exit-code mapping.
        let captureStderr = frameType == 2
        return { [weak self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            if captureStderr {
                self?.appendStderrTail(data)
            }
            let payload = isTTY ? data : ExecSession.frame(type: frameType, payload: data)
            Task {
                if await connection.write(payload) == .failed {
                    // Client went away mid-exec; don't leak the child.
                    self?.killChild()
                }
            }
        }
    }

    private func appendStderrTail(_ data: Data) {
        stderrLock.lock()
        stderrTail.append(data)
        if stderrTail.count > 4096 {
            stderrTail.removeFirst(stderrTail.count - 4096)
        }
        stderrLock.unlock()
    }

    private func stderrText() -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return String(data: stderrTail, encoding: .utf8) ?? ""
    }

    func killChild() {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// Runs the process with output discarded (POST /exec/{id}/start detach).
    /// Stderr is drained into the bounded tail (never forwarded) so the
    /// exit-code mapping still sees start-failure markers — an undrained
    /// 64 KB pipe would wedge a chatty child. The detached task retains the
    /// session until the child exits, so the drain cannot outlive its reader.
    func startDetached() throws {
        process.standardOutput = FileHandle.nullDevice
        // NOTE: standardError stays stderrPipe (wired in init).
        let reader = stderrPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderrTail(data)
        }
        try process.run()
        ExecRegistry.shared.add(self)
        Task.detached(priority: .utility) { [process] in
            process.waitUntilExit()
            ExecRegistry.shared.remove(self)
            await self.completeDetached()
        }
    }

    private func completeDetached() async {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let code = Self.dockerExitCode(
            cliStatus: process.terminationStatus, stderr: stderrText())
        await state.finishExec(id: execID, exitCode: code)
        closePipes()
    }

    /// Deterministic pipe teardown (both ends of all three): FileHandle
    /// deallocation timing is autoreleasepool-dependent on long-lived
    /// threads, which showed up as a slow pipe-fd creep under exec load.
    private func closePipes() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        for handle in [
            stdoutPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting,
            stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting,
            stdinPipe.fileHandleForReading, stdinPipe.fileHandleForWriting,
        ] {
            try? handle.close()
        }
    }

    private func awaitExit(connection: ShimConnection) {
        process.waitUntilExit()
        ExecRegistry.shared.remove(self)
        closePipes()
        let code = Self.dockerExitCode(
            cliStatus: process.terminationStatus, stderr: stderrText())
        fputs("[shim] exec \(execID) exited \(code)\n", stderr)
        let finishState = state
        let id = execID
        Task {
            await finishState.finishExec(id: id, exitCode: code)
            connection.finishInbound()
            connection.close()
            fputs("[shim] exec \(execID) connection closed\n", stderr)
        }
    }

    static func frame(type: UInt8, payload: Data) -> Data {
        var header = Data([type, 0, 0, 0])
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        header.append(payload)
        return header
    }
}
