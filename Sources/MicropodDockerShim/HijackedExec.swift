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
        return { [weak self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                return
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

    func killChild() {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// Runs the process with output discarded (POST /exec/{id}/start detach).
    func startDetached() throws {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let exitCodeCapture = state
        let idCapture = execID
        Task.detached(priority: .utility) { [process] in
            process.waitUntilExit()
            await exitCodeCapture.finishExec(id: idCapture, exitCode: Int(process.terminationStatus))
        }
    }

    private func awaitExit(connection: ShimConnection) {
        process.waitUntilExit()
        ExecRegistry.shared.remove(self)
        fputs("[shim] exec \(execID) exited \(process.terminationStatus)\n", stderr)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let code = Int(process.terminationStatus)
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
