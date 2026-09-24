import Foundation
import Network

/// Minimal newline-delimited JSON client for the desktop app's control
/// socket (`~/.micropod/app-control.sock`). The app owns Sparkle, so
/// update triggers from the API server and MCP reach it through here.
///
/// Wire shape mirrors the shared-fs protocol: request
/// `{"id","method","params"}` → response `{"id","ok","result","error"}`.
public enum AppControlError: Error, LocalizedError {
    case unavailable(String)
    case callFailed(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return detail
        case .callFailed(let detail): return detail
        case .malformedResponse: return "malformed response from app control socket"
        }
    }
}

public struct AppControlClient: Sendable {
    public let socketPath: String
    /// Upper bound on a single request round-trip — a listener that
    /// accepts but never answers fails the call instead of hanging it.
    public let requestTimeout: TimeInterval

    public init(
        socketPath: String = AppControlClient.defaultSocketPath,
        requestTimeout: TimeInterval = 15
    ) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
    }

    public static var defaultSocketPath: String {
        ProcessInfo.processInfo.environment["MICROPOD_APP_CONTROL_SOCKET"]
            ?? NSHomeDirectory() + "/.micropod/app-control.sock"
    }

    /// Whether the control socket is present (app is running).
    public var isReachable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Trigger a background update check in the app. Returns the app's
    /// status snapshot (state may still be "checking" — poll `status`).
    public func checkForUpdates() async throws -> [String: Any] {
        try await call("update.check")
    }

    /// Last-known updater status from the app.
    public func updateStatus() async throws -> [String: Any] {
        try await call("update.status")
    }

    /// Quit the app so Sparkle installs the downloaded update and
    /// relaunches on the new version. Throws `callFailed` when no
    /// update has been downloaded yet — poll `updateStatus` until
    /// `downloaded` is true first.
    public func applyUpdate() async throws -> [String: Any] {
        try await call("update.apply")
    }

    public func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        let body = try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)
        let response = try await send(body)
        guard
            let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any],
            let ok = decoded["ok"] as? Bool
        else { throw AppControlError.malformedResponse }
        guard ok else {
            throw AppControlError.callFailed(decoded["error"] as? String ?? "unknown")
        }
        return (decoded["result"] as? [String: Any]) ?? [:]
    }

    private func send(_ body: Data) async throws -> Data {
        // Pre-flight: NWConnection to a nonexistent unix path can behave
        // poorly in bundle-less hosts — fail cheaply instead.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw AppControlError.unavailable("no control socket at \(socketPath)")
        }
        return try await withCheckedThrowingContinuation { cont in
            let once = Once(cont)
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(to: .unix(path: socketPath), using: parameters)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: body,
                        completion: .contentProcessed { error in
                            if let error {
                                once.resume(throwing: error)
                                return
                            }
                            Self.recv(connection: connection, once: once, buffer: Data())
                        })
                case .waiting(let error):
                    // A unix socket that can't connect has no listener —
                    // don't sit on NWConnection's retry loop.
                    once.resume(
                        throwing: AppControlError.unavailable(
                            "no listener on control socket: \(error.localizedDescription)"))
                    connection.cancel()
                case .failed(let error):
                    once.resume(throwing: error)
                case .cancelled:
                    once.resume(throwing: AppControlError.unavailable("connection cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "app-control-client"))
            // A listener that accepts but never answers would hang the
            // caller forever — bound the whole exchange.
            Task {
                try? await Task.sleep(for: .seconds(requestTimeout))
                once.resume(
                    throwing: AppControlError.unavailable("control socket timed out"))
                connection.cancel()
            }
        }
    }

    private static func recv(
        connection: NWConnection, once: Once, buffer: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let error {
                once.resume(throwing: error)
                connection.cancel()
                return
            }
            if let nl = buffer.firstIndex(of: 0x0A) {
                once.resume(returning: buffer.subdata(in: 0..<nl))
                connection.cancel()
                return
            }
            if isComplete {
                once.resume(throwing: AppControlError.unavailable("truncated response"))
                connection.cancel()
                return
            }
            recv(connection: connection, once: once, buffer: buffer)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let cont: CheckedContinuation<Data, Error>
        init(_ cont: CheckedContinuation<Data, Error>) { self.cont = cont }
        func resume(returning value: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            cont.resume(returning: value)
        }
        func resume(throwing error: Error) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            cont.resume(throwing: error)
        }
    }
}
