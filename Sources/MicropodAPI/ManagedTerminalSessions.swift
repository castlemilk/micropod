import Foundation
import MicropodCore

actor ManagedTerminalSessions {
    private let terminal: TerminalService
    private var connections: [UUID: TerminalConnection] = [:]
    init(client: ContainerCLIClient) { terminal = TerminalService(client: client) }
    func open(container: String, shell: String) async throws -> UUID {
        guard !container.isEmpty, !container.hasPrefix("-"), container.utf8.count <= 256,
            shell.hasPrefix("/"), shell.utf8.count <= 1024
        else { throw MicropodError.message("Invalid terminal request") }
        let connection = try await terminal.open(containerID: container, shell: shell)
        connections[connection.sessionID] = connection
        return connection.sessionID
    }
    func take(_ id: UUID) throws -> TerminalConnection {
        guard let connection = connections.removeValue(forKey: id) else {
            throw MicropodError.message("Terminal session not found")
        }
        return connection
    }
    func write(_ bytes: Data, id: UUID) async throws { try await terminal.write(bytes, to: id) }
    func close(_ id: UUID) async throws {
        connections.removeValue(forKey: id)
        try await terminal.close(sessionID: id)
    }
}
