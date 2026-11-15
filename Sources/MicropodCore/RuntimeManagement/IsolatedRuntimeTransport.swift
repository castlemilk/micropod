import Darwin
import Foundation

/// Desktop commands use the private account's API. There is no sudo, shell,
/// runtime fallback or helper-supplied executable path on this data plane.
public actor IsolatedRuntimeTransport {
    public static let shared = IsolatedRuntimeTransport()
    private var capability: IsolatedRuntimeAPISession?
    private var pending: Task<IsolatedRuntimeAPISession, Error>?

    public func session() async throws -> IsolatedRuntimeAPISession {
        if let capability, capability.expiresAt > Date().addingTimeInterval(60),
            try RuntimeProcessBirth.read(getpid()) == capability.subject
        {
            return capability
        }
        if let pending { return try await pending.value }
        let pending = Task {
            let reply = try await IsolatedRuntimeClient().call(.init(action: .session))
            guard let session = reply.session else {
                throw MicropodError.message(reply.error ?? "The managed runtime did not issue an API session")
            }
            return session
        }
        self.pending = pending
        defer { self.pending = nil }
        let value = try await pending.value
        capability = value
        return value
    }

    public func request(path: String, body: Data, timeout: Duration = .seconds(60)) async throws -> Data {
        let session = try await session()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let fd = try Self.connect(session, path: path, body: body, timeout: timeout)
                        defer { close(fd) }
                        var result = Data()
                        try Self.read(fd) { bytes in
                            result.append(bytes)
                            guard result.count <= 64 * 1024 * 1024 else {
                                throw MicropodError.message("Managed API response exceeded its limit")
                            }
                        }
                        return result
                    })
            }
        }
    }

    public nonisolated func stream(path: String, body: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let socket = ManagedClientSocket()
            let task = Task {
                do {
                    let session = try await self.session()
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            done.resume(
                                with: Result {
                                    let fd = try Self.connect(session, path: path, body: body, timeout: .seconds(600))
                                    socket.set(fd)
                                    defer { socket.close() }
                                    try Self.read(fd) { continuation.yield($0) }
                                })
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in
                task.cancel()
                socket.cancel()
            }
        }
    }

    private static func connect(_ session: IsolatedRuntimeAPISession, path: String, body: Data, timeout: Duration)
        throws -> Int32
    {
        let identity = try IsolatedRuntimeIdentity.readRootOwned()
        guard identity.instance == session.instance, identity.ownerUID == getuid(), path.hasPrefix("/"),
            !path.contains("\r"), !path.contains("\n"), body.count <= 32 * 1024 * 1024
        else {
            throw MicropodError.message("The managed API request is invalid")
        }
        let fd = try RuntimeUnixSocket.connect(session.socketPath, expectedUID: identity.serviceUID)
        do {
            try RuntimeUnixSocket.timeout(fd, seconds: max(1, min(600, Int(timeout.components.seconds))))
            let head =
                "POST \(path) HTTP/1.1\r\nHost: localhost:45454\r\nConnection: close\r\nContent-Type: application/json\r\nAuthorization: \(session.authorization)\r\nContent-Length: \(body.count)\r\n\r\n"
            try RuntimeUnixSocket.write(Data(head.utf8) + body, to: fd)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
    private static func read(_ fd: Int32, chunk: (Data) throws -> Void) throws {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        var length: Int?
        var received = 0
        var headerReceived = false
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw MicropodError.message("The managed API outcome is unknown; check status before retrying")
            }
            if count == 0 {
                guard headerReceived, length == nil || received == length else {
                    throw MicropodError.message("The managed API response ended before the operation was confirmed")
                }
                return
            }
            buffer.append(contentsOf: bytes.prefix(count))
            if !headerReceived {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= 65536 else { throw MicropodError.message("Invalid managed API response") }
                    continue
                }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                guard
                    head.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }).map({
                        (200..<300).contains($0)
                    }) == true
                else {
                    throw MicropodError.message(
                        "The managed API refused this operation; check runtime maintenance and readiness")
                }
                length = head.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap {
                    Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces))
                }
                buffer.removeSubrange(..<end.upperBound)
                headerReceived = true
            }
            if !buffer.isEmpty {
                received += buffer.count
                guard length == nil || received <= length! else {
                    throw MicropodError.message("Invalid managed API response framing")
                }
                try chunk(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if received == length { return }
        }
    }
}

private final class ManagedClientSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    func set(_ value: Int32) {
        lock.withLock {
            fd = value
            if cancelled { shutdown(value, SHUT_RDWR) }
        }
    }
    func cancel() {
        lock.withLock {
            cancelled = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }
    func close() {
        lock.withLock {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }
}

public struct IsolatedRuntimeCLIRequest: Codable, Sendable {
    public let arguments: [String]
    public let stdin: Data?
    public let timeoutSeconds: Int
    public let acceptingExitCodes: Set<Int32>
    public let reportExitCode: Bool?
    public init(
        command: ContainerCommand, timeout: Duration, acceptingExitCodes: Set<Int32> = [0], reportExitCode: Bool? = nil
    ) throws {
        guard command.environment.isEmpty, command.stdinFile == nil else {
            throw MicropodError.message(
                "Managed runtime commands do not accept host environment overrides or file stdin; send an explicit stdin payload"
            )
        }
        arguments = command.arguments
        stdin = command.stdinData
        timeoutSeconds = max(1, min(600, Int(timeout.components.seconds)))
        self.acceptingExitCodes = acceptingExitCodes
        self.reportExitCode = reportExitCode
    }
    public func command() throws -> ContainerCommand {
        let roots: Set<String> = [
            "list", "ls", "inspect", "run", "create", "start", "stop", "restart", "kill", "delete", "rm", "exec",
            "logs", "stats", "events", "image", "volume", "network", "machine", "registry", "build", "builder",
            "--version", "--help",
        ]
        let status =
            arguments.starts(with: ["system", "status"]) || arguments.starts(with: ["system", "version"])
            || arguments.starts(with: ["system", "df"]) || arguments.starts(with: ["system", "logs"])
        guard arguments.count <= 1024, arguments.reduce(0, { $0 + $1.utf8.count }) <= 1024 * 1024,
            arguments.first.map(roots.contains) == true || status,
            !arguments.contains(where: {
                ["--app-root", "--install-root", "--config", "--plugin-dir"].contains(
                    $0.split(separator: "=").first.map(String.init) ?? "")
            }),
            (1...600).contains(timeoutSeconds), acceptingExitCodes.isSubset(of: [0, 1]),
            (stdin?.count ?? 0) <= 16 * 1024 * 1024
        else {
            throw MicropodError.message(
                "This command is unavailable through the managed runtime; lifecycle changes belong to Micropod's runtime controls"
            )
        }
        return .init(arguments: arguments, stdinData: stdin)
    }
}
