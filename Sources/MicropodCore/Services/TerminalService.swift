import CPtyShim
import Foundation

/// A live interactive terminal session into a container (`container exec -it`).
public struct TerminalSession: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let containerID: String

    public init(id: UUID = UUID(), containerID: String) {
        self.id = id
        self.containerID = containerID
    }
}

/// An opened terminal connection: the session id (for writes) + the output stream.
public struct TerminalConnection: Sendable {
    public let sessionID: UUID
    public let stream: AsyncThrowingStream<Data, Error>

    public init(sessionID: UUID, stream: AsyncThrowingStream<Data, Error>) {
        self.sessionID = sessionID
        self.stream = stream
    }
}

public protocol TerminalServing: Sendable {
    func open(containerID: String, shell: String) async throws -> TerminalConnection
    func write(_ data: Data, to sessionID: UUID) async throws
    func close(sessionID: UUID) async throws
}

/// PTY-backed interactive shell into a container, spawned via the C shim
/// (setsid + TIOCSCTTY for correct job control).
public actor TerminalService: TerminalServing {
    private struct LiveSession: Sendable {
        let pid: pid_t
        let masterFD: Int32
        let reader: TerminalReaderControl
    }

    private let client: ContainerCLIClient
    private var sessions: [UUID: LiveSession] = [:]
    private var streams: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    public init(client: ContainerCLIClient) {
        self.client = client
    }

    var activeSessionCount: Int { sessions.count }

    public func open(containerID: String, shell: String = "/bin/sh") async throws -> TerminalConnection {
        let sessionID = UUID()
        var argv: [String] = ["container", "exec", "-it", containerID, shell]
        // The CLI is resolved by the client's executableURL.
        argv[0] = client.executableURL.path

        let env = ProcessInfo.processInfo.environment
        var envp: [String] = env.map { "\($0.key)=\($0.value)" }
        envp.append("TERM=xterm-256color")

        var masterFD: Int32 = -1
        let pid = argv.withUnsafeMutableBufferPointer { argvPtr -> Int32 in
            var cargv: [UnsafeMutablePointer<CChar>?] = argvPtr.map { strdup($0) }
            var cenvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) }
            defer {
                for p in cargv { free(p) }
                for p in cenvp { free(p) }
            }
            cargv.append(nil)
            cenvp.append(nil)
            let cwd: UnsafePointer<CChar>? = nil
            return micropod_spawn_pty(&cargv, &cenvp, cwd, &masterFD)
        }
        guard pid > 0 else {
            throw MicropodError.message("Failed to start terminal session (pid \(pid), errno \(errno))")
        }

        // The session owns the writable master; the reader owns a duplicate.
        // Closing one descriptor cannot double-close a reused descriptor on EOF.
        let readerFD = Darwin.dup(masterFD)
        guard readerFD >= 0 else {
            kill(pid, SIGKILL)
            Darwin.close(masterFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            throw MicropodError.message("Failed to open terminal output reader")
        }
        let control = TerminalReaderControl()
        sessions[sessionID] = LiveSession(pid: pid, masterFD: masterFD, reader: control)
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(256)) { continuation in
            streams[sessionID] = continuation
            continuation.onTermination = { [weak self] _ in
                control.cancel()
                Task { [weak self] in try? await self?.close(sessionID: sessionID) }
            }
            let reader = Thread { [weak self] in
                defer {
                    Darwin.close(readerFD)
                    reapTerminalProcess(pid)
                    Task { [weak self] in try? await self?.close(sessionID: sessionID) }
                }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while !control.isCancelled {
                    var descriptor = pollfd(fd: readerFD, events: Int16(POLLIN), revents: 0)
                    let available = Darwin.poll(&descriptor, 1, 100)
                    if available == 0 { continue }
                    if available < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(readerFD, $0.baseAddress, $0.count) }
                    if count <= 0 {
                        if count < 0, errno == EINTR { continue }
                        break
                    }
                    switch continuation.yield(Data(bytes.prefix(count))) {
                    case .enqueued:
                        continue
                    case .dropped:
                        continuation.finish(
                            throwing: MicropodError.message(
                                "Terminal output exceeded its 1 MiB delivery buffer; the shell was detached."))
                        return
                    case .terminated:
                        return
                    @unknown default:
                        return
                    }
                }
                continuation.finish()
            }
            reader.name = "micropod-pty-\(sessionID)"
            reader.start()
        }

        return TerminalConnection(sessionID: sessionID, stream: stream)
    }

    public func write(_ data: Data, to sessionID: UUID) async throws {
        guard let session = sessions[sessionID] else {
            throw MicropodError.message("Terminal session not found")
        }
        try data.withUnsafeBytes { raw in
            let wrote = Darwin.write(session.masterFD, raw.baseAddress, raw.count)
            guard wrote == raw.count else {
                throw MicropodError.message("Failed to write to terminal (errno \(errno))")
            }
        }
    }

    public func close(sessionID: UUID) async throws {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        session.reader.cancel()
        kill(-session.pid, SIGTERM)
        streams.removeValue(forKey: sessionID)?.finish()
        Darwin.close(session.masterFD)
    }
}

private final class TerminalReaderControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// The reader is the sole child reaper. A shell that ignores termination cannot
/// leave a reader thread or zombie behind after the view has detached.
private func reapTerminalProcess(_ pid: pid_t) {
    var status: Int32 = 0
    let deadline = Date().addingTimeInterval(0.5)
    while Date() < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno == ECHILD) { return }
        Thread.sleep(forTimeInterval: 0.01)
    }
    kill(-pid, SIGKILL)
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
}
