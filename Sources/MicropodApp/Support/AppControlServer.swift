import AppKit
import Foundation
import MicropodCore
import MicropodRuntime
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
    private let updateController: @MainActor () -> UpdateController
    private let runtimeController: @MainActor () -> ManagedRuntimeController

    init(
        socketPath: String = AppControlClient.defaultSocketPath,
        updateController: @escaping @MainActor () -> UpdateController = { .shared },
        runtimeController: @escaping @MainActor () -> ManagedRuntimeController = { .shared }
    ) {
        self.socketPath = socketPath
        self.updateController = updateController
        self.runtimeController = runtimeController
    }

    func start() {
        guard listener == nil else { return }
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: URL(fileURLWithPath: socketPath).deletingLastPathComponent().path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.stateUpdateHandler = { [socketPath] state in
            if case .ready = state {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)
            }
        }
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
            if error != nil || isComplete || buffer.count > 1024 * 1024 {
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
            let result = await self.route(method)
            self.respond(id: id, result: result, on: connection)
        }
    }

    @MainActor
    private func route(_ method: String) async -> (ok: Bool, result: [String: Any], error: String?) {
        let managed = runtimeController()
        switch method {
        case "runtime.status":
            await managed.refresh()
            return (true, managed.statusReport, nil)
        case "runtime.cancel":
            await managed.cancel()
            return (true, managed.statusReport, nil)
        case "runtime.recover":
            do {
                try await managed.recover()
                return (true, managed.statusReport, nil)
            } catch { return (false, [:], error.localizedDescription) }
        case "runtime.install", "runtime.repair", "runtime.start", "runtime.stop", "runtime.restart":
            let action = String(method.dropFirst("runtime.".count))
            guard let action = RuntimeLifecycleAction(rawValue: action) else {
                return (false, [:], "Unknown runtime action")
            }
            do {
                _ = try await managed.begin(action)
                return (true, managed.statusReport, nil)
            } catch { return (false, [:], error.localizedDescription) }
        case "ping":
            return (true, ["pong": true], nil)
        case "update.check":
            let updates = updateController()
            guard updates.status != .unavailable else {
                return (false, [:], "no update feed configured (not a packaged build)")
            }
            updates.checkForUpdatesInBackground()
            return (true, updates.statusReport, nil)
        case "update.apply":
            // Runs Sparkle's staged installer: terminates the app,
            // swaps in the update, relaunches on the new version.
            let updates = updateController()
            guard await updates.applyStagedUpdate() else {
                return (false, [:], updates.restartBlockedReason ?? "no staged update ready to install")
            }
            return (true, updates.statusReport, nil)
        case "update.status":
            return (true, updateController().statusReport, nil)
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
