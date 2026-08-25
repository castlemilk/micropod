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
    }

    private let client: ContainerCLIClient
    private var sessions: [UUID: LiveSession] = [:]
    private var streams: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    public init(client: ContainerCLIClient) {
        self.client = client
    }

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

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            streams[sessionID] = continuation
            let readerFD = masterFD
            let reader = Thread {
                let handle = FileHandle(fileDescriptor: readerFD, closeOnDealloc: true)
                while true {
                    do {
                        let data = try handle.read(upToCount: 4096)
                        if let data, !data.isEmpty {
                            continuation.yield(data)
                        } else {
                            try? handle.close()
                            return
                        }
                    } catch {
                        try? handle.close()
                        return
                    }
                }
            }
            reader.name = "micropod-pty-\(sessionID)"
            reader.start()
        }

        sessions[sessionID] = LiveSession(pid: pid, masterFD: masterFD)
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
        kill(session.pid, SIGTERM)
        streams.removeValue(forKey: sessionID)?.finish()
        Darwin.close(session.masterFD)
    }
}
