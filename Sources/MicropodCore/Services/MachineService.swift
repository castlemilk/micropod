import Foundation

public protocol MachineServing: Sendable {
    func list() async throws -> [MachineEntry]
    func create(image: String, name: String?, cpus: String?, memory: String?) async throws
    func delete(_ name: String) async throws
    func properties() async throws -> SystemPropertyListResponse
}

/// `container machine` + `container system property` surface.
public actor MachineService: MachineServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func list() async throws -> [MachineEntry] {
        let output = try await client.run(ContainerCommandFactory.listMachines(), timeout: .seconds(15))
        return try MicropodJSON.decodeArray(
            MachineEntry.self, from: Data(output.utf8), context: "machine list")
    }

    public func create(image: String, name: String?, cpus: String?, memory: String?) async throws {
        _ = try await client.run(
            ContainerCommandFactory.createMachine(image, name: name, cpus: cpus, memory: memory),
            timeout: .seconds(120))
    }

    public func delete(_ name: String) async throws {
        _ = try await client.run(
            ContainerCommandFactory.deleteMachine(name), timeout: .seconds(120))
    }

    public func properties() async throws -> SystemPropertyListResponse {
        let output = try await client.run(ContainerCommandFactory.listProperties(), timeout: .seconds(15))
        return try MicropodJSON.decode(
            SystemPropertyListResponse.self, from: Data(output.utf8), context: "system property list")
    }
}
