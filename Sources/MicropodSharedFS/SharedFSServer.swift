import Foundation
import Network

/// Unix-socket server that fronts `SharedFSDaemon` with the JSON line
/// protocol defined in `SharedFSClient`. One connection at a time is
/// sufficient (the daemon is designed for low concurrency); multiple
/// concurrent connections could deadlock if a long sync holds the actor —
/// we serialize per connection with a single in-flight Task.
public final class SharedFSServer: @unchecked Sendable {
    public let socketPath: String
    private let daemon: SharedFSDaemon

    public init(socketPath: String, daemon: SharedFSDaemon) {
        self.socketPath = socketPath
        self.daemon = daemon
    }

    public func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // NWListener doesn't have a `.unix` parameter family — use the
        // default parameters and pin the unix path via requiredLocalEndpoint.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.handle(connection)
        }
        let queue = DispatchQueue(label: "sharedfs-server", qos: .userInitiated)
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private var listener: NWListener?

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "sharedfs-conn"))
        receiveLoop(connection: connection, buffer: Data())
    }

    private func receiveLoop(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            // Process all newline-delimited messages in the buffer.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let message = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                self.process(message, on: connection)
            }
            self.receiveLoop(connection: connection, buffer: buffer)
        }
    }

    private func process(_ data: Data, on connection: NWConnection) {
        guard !data.isEmpty,
            let envelope = try? JSONDecoder().decode(IPCRequest.self, from: data)
        else { return }
        Task {
            let response = await self.dispatch(envelope)
            self.respond(response, on: connection)
        }
    }

    private func dispatch(_ req: IPCRequest) async -> IPCResponse {
        let params = req.params
        do {
            switch req.method {
            case "mount":
                guard let src = params["src"]?.value as? String else {
                    return .init(
                        id: req.id, ok: false, result: nil,
                        error: "missing src")
                }
                let url = URL(fileURLWithPath: src)
                let readonly = (params["readonly"]?.value as? Bool) ?? false
                let info = try await daemon.mount(src: url, readonly: readonly)
                return .init(
                    id: req.id, ok: true,
                    result: AnyCodable(info.toDictionary()),
                    error: nil)
            case "mountShared":
                guard let src = params["src"]?.value as? String else {
                    return .init(
                        id: req.id, ok: false, result: nil,
                        error: "missing src")
                }
                let url = URL(fileURLWithPath: src)
                let readonly = (params["readonly"]?.value as? Bool) ?? false
                let info = try await daemon.mountShared(src: url, readonly: readonly)
                return .init(
                    id: req.id, ok: true,
                    result: AnyCodable(info.toDictionary()),
                    error: nil)
            case "unmount":
                guard let id = params["id"]?.value as? String else {
                    return .init(id: req.id, ok: false, result: nil, error: "missing id")
                }
                try await daemon.unmount(id: ViewID(id))
                return .init(
                    id: req.id, ok: true, result: AnyCodable([:] as [String: Any]),
                    error: nil)
            case "refresh":
                guard let id = params["id"]?.value as? String else {
                    return .init(id: req.id, ok: false, result: nil, error: "missing id")
                }
                let info = try await daemon.refresh(id: ViewID(id))
                return .init(
                    id: req.id, ok: true,
                    result: AnyCodable(info.toDictionary()),
                    error: nil)
            case "inspect":
                guard let id = params["id"]?.value as? String else {
                    return .init(id: req.id, ok: false, result: nil, error: "missing id")
                }
                let info = try await daemon.inspect(id: ViewID(id))
                return .init(
                    id: req.id, ok: true,
                    result: AnyCodable(info.toDictionary()),
                    error: nil)
            case "sync":
                guard let id = params["id"]?.value as? String else {
                    return .init(id: req.id, ok: false, result: nil, error: "missing id")
                }
                let result = try await daemon.sync(id: ViewID(id))
                return .init(
                    id: req.id, ok: true,
                    result: AnyCodable(result.toDictionary()),
                    error: nil)
            case "list":
                let infos = try await daemon.list()
                return .init(
                    id: req.id, ok: true,
                    result: AnyCodable(infos.map { $0.toDictionary() }),
                    error: nil)
            case "gc":
                let result = try await daemon.gc()
                return .init(
                    id: req.id, ok: true,
                    result: AnyCodable(result.toDictionary()),
                    error: nil)
            default:
                return .init(
                    id: req.id, ok: false, result: nil,
                    error: "unknown method \(req.method)")
            }
        } catch {
            return .init(id: req.id, ok: false, result: nil, error: "\(error)")
        }
    }

    private func respond(_ response: IPCResponse, on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        connection.send(
            content: data + Data("\n".utf8),
            completion: .contentProcessed { _ in })
    }
}

extension MountInfo {
    func toDictionary() -> [String: Any] {
        [
            "id": id.value, "src": src, "viewPath": viewPath,
            "sizeBytes": sizeBytes, "readonly": readonly,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
        ]
    }
}

extension SyncResult {
    func toDictionary() -> [String: Any] {
        ["id": id.value, "synced": synced, "bytesWritten": bytesWritten]
    }
}

extension GCResult {
    func toDictionary() -> [String: Any] {
        ["chunksRemoved": chunksRemoved, "bytesReclaimed": bytesReclaimed]
    }
}
