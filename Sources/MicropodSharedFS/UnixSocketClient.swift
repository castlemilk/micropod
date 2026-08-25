import Foundation
import Network

/// Unix-socket client for `SharedFSServer`. One connection per call — the
/// protocol is request/response (newline-delimited JSON), so we open, write,
/// read until newline, close. Cheap and simple; avoids actor-isolation
/// concerns around long-lived connections.
public final class UnixSocketClient: SharedFSClient, @unchecked Sendable {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func mount(src: URL, readonly: Bool) async throws -> MountInfo {
        let result = try await call(
            method: "mount", params: ["src": src.path, "readonly": readonly])
        return MountInfo(dictionary: result as? [String: Any] ?? [:])
    }

    public func mountShared(src: URL, readonly: Bool) async throws -> MountInfo {
        let result = try await call(
            method: "mountShared", params: ["src": src.path, "readonly": readonly])
        return MountInfo(dictionary: result as? [String: Any] ?? [:])
    }

    public func unmount(id: ViewID) async throws {
        _ = try await call(method: "unmount", params: ["id": id.value])
    }

    public func refresh(id: ViewID) async throws -> MountInfo {
        let result = try await call(
            method: "refresh", params: ["id": id.value])
        return MountInfo(dictionary: result as? [String: Any] ?? [:])
    }

    public func inspect(id: ViewID) async throws -> MountInfo {
        let result = try await call(
            method: "inspect", params: ["id": id.value])
        return MountInfo(dictionary: result as? [String: Any] ?? [:])
    }

    public func sync(id: ViewID) async throws -> SyncResult {
        let result = try await call(
            method: "sync", params: ["id": id.value])
        return SyncResult(dictionary: result as? [String: Any] ?? [:])
    }

    public func list() async throws -> [MountInfo] {
        let result = try await call(method: "list", params: [:])
        return ((result as? [Any]) ?? []).map { entry in
            MountInfo(dictionary: (entry as? [String: Any]) ?? [:])
        }
    }

    public func gc() async throws -> GCResult {
        let result = try await call(method: "gc", params: [:])
        return GCResult(dictionary: result as? [String: Any] ?? [:])
    }

    // MARK: - Transport

    private func call(method: String, params: [String: Any]) async throws -> Any {
        let envelope = IPCRequest(
            id: UUID().uuidString,
            method: method,
            params: params.mapValues { AnyCodable($0) })
        let request = try JSONEncoder().encode(envelope) + Data("\n".utf8)
        let response = try await send(request: request)
        guard let decoded = try? JSONDecoder().decode(IPCResponse.self, from: response) else {
            throw SharedFSError.invalidResponse("malformed response")
        }
        guard decoded.ok else {
            throw SharedFSError.invalidResponse(decoded.error ?? "unknown")
        }
        return decoded.result?.value ?? ()
    }

    private final class OnceContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let cont: CheckedContinuation<Data, Error>
        init(_ cont: CheckedContinuation<Data, Error>) { self.cont = cont }
        func resume(returning value: Data) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            lock.unlock()
            cont.resume(returning: value)
        }
        func resume(throwing error: Error) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            lock.unlock()
            cont.resume(throwing: error)
        }
    }

    private func send(request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = OnceContinuation(cont)
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(
                to: .unix(path: socketPath), using: parameters)
            let queue = DispatchQueue(label: "sharedfs-client", qos: .userInitiated)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: request,
                        completion: .contentProcessed { error in
                            if let error {
                                once.resume(throwing: error)
                                return
                            }
                            Self.recvAll(connection: connection, once: once)
                        })
                case .failed(let err):
                    once.resume(throwing: err)
                case .cancelled:
                    once.resume(throwing: SharedFSError.daemonUnavailable)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func recvAll(
        connection: NWConnection,
        once: OnceContinuation,
        buffer: Data = Data()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil {
                once.resume(throwing: SharedFSError.daemonUnavailable)
                connection.cancel()
                return
            }
            if let nl = buffer.firstIndex(of: 0x0A) {
                let response = buffer.subdata(in: 0..<nl)
                once.resume(returning: response)
                connection.cancel()
                return
            }
            if isComplete {
                once.resume(throwing: SharedFSError.invalidResponse("truncated"))
                connection.cancel()
                return
            }
            Self.recvAll(connection: connection, once: once, buffer: buffer)
        }
    }
}

extension MountInfo {
    public init(dictionary: [String: Any]) {
        let rawId = dictionary["id"] as? String ?? ""
        let src = dictionary["src"] as? String ?? ""
        let viewPath = dictionary["viewPath"] as? String ?? ""
        let sizeBytes =
            (dictionary["sizeBytes"] as? UInt64)
            ?? UInt64(
                (dictionary["sizeBytes"] as? Int) ?? 0)
        let readonly = dictionary["readonly"] as? Bool ?? false
        let createdStr = dictionary["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdStr) ?? Date()
        self.init(
            id: ViewID(rawId), src: src,
            viewPath: viewPath,
            sizeBytes: sizeBytes, readonly: readonly, createdAt: createdAt)
    }
}

extension SyncResult {
    public init(dictionary: [String: Any]) {
        let id = dictionary["id"] as? String ?? ""
        let synced = (dictionary["synced"] as? [String]) ?? []
        let bytes =
            (dictionary["bytesWritten"] as? UInt64)
            ?? UInt64((dictionary["bytesWritten"] as? Int) ?? 0)
        self.init(id: ViewID(id), synced: synced, bytesWritten: bytes)
    }
}

extension GCResult {
    public init(dictionary: [String: Any]) {
        let chunksRemoved = (dictionary["chunksRemoved"] as? Int) ?? 0
        let bytesReclaimed =
            (dictionary["bytesReclaimed"] as? UInt64)
            ?? UInt64((dictionary["bytesReclaimed"] as? Int) ?? 0)
        self.init(chunksRemoved: chunksRemoved, bytesReclaimed: bytesReclaimed)
    }
}
