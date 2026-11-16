import Foundation

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
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw AppControlError.unavailable("no control socket at \(socketPath)")
        }
        let cancellation = AppControlSocket.Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Result {
                            try AppControlSocket.exchange(
                                path: socketPath, body: body, timeout: requestTimeout,
                                cancellation: cancellation)
                        })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
