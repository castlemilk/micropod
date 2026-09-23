import AppKit
import Foundation
import MicropodCore
import Network

/// Newline-JSON control socket the app serves at
/// `~/.micropod/app-control.sock` (overridable via
/// `MICROPOD_APP_CONTROL_SOCKET`). Lets the API server and MCP reach
/// app-process features — starting with the Sparkle updater:
///
///   {"method":"update.check"}   → trigger a background check; returns status
///   {"method":"update.status"}  → last-known updater status
///   {"method":"ping"}           → {"pong":true} liveness
///
/// Same wire shape as the shared-fs socket: `{"id","method","params"}` →
/// `{"id","ok","result","error"}`.
final class AppControlServer: @unchecked Sendable {
    static let shared = AppControlServer()

    let socketPath: String
    private var listener: NWListener?

    init(socketPath: String = AppControlClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func start() {
        guard listener == nil else { return }
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: DispatchQueue(label: "app-control-server"))
        self.listener = listener
        // Remove the socket file on quit so clients see "app not running"
        // instead of a stale endpoint.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "app-control-conn"))
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let message = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                self.dispatch(message, on: connection)
            }
            self.receive(connection: connection, buffer: buffer)
        }
    }

    private func dispatch(_ data: Data, on connection: NWConnection) {
        guard
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = request["method"] as? String
        else { return }
        let id = request["id"] as? String ?? ""
        Task { @MainActor in
            let result = self.route(method)
            self.respond(id: id, result: result, on: connection)
        }
    }

    @MainActor
    private func route(_ method: String) -> (ok: Bool, result: [String: Any], error: String?) {
        switch method {
        case "ping":
            return (true, ["pong": true], nil)
        case "update.check":
            let updates = UpdateController.shared
            guard updates.status != .unavailable else {
                return (false, [:], "no update feed configured (not a packaged build)")
            }
            updates.checkForUpdatesInBackground()
            return (true, updates.statusReport, nil)
        case "update.status":
            return (true, UpdateController.shared.statusReport, nil)
        default:
            return (false, [:], "unknown method: \(method)")
        }
    }

    private func respond(
        id: String, result: (ok: Bool, result: [String: Any], error: String?),
        on connection: NWConnection
    ) {
        var envelope: [String: Any] = ["id": id, "ok": result.ok]
        if result.ok { envelope["result"] = result.result } else { envelope["error"] = result.error }
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        connection.send(content: body + Data("\n".utf8), completion: .contentProcessed { _ in })
    }
}
