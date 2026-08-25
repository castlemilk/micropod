import Foundation

public protocol ContainerServing: Sendable {
    func list() async throws -> [Micropod_V1_Container]
    func inspect(_ id: String) async throws -> Data
    /// Docker-style `create`: prepare the container without starting it.
    func create(_ request: ContainerRunRequest) async throws -> String
    func run(_ request: ContainerRunRequest) async throws -> String
    func exec(_ request: ContainerExecRequest) async throws -> String
    func start(_ id: String) async throws
    func stop(_ id: String, timeout: Int) async throws
    /// Docker-style restart: stop (with grace) then start.
    func restart(_ id: String) async throws
    func stopAll() async throws
    func kill(_ id: String, signal: String) async throws
    func delete(_ id: String, force: Bool) async throws
    func deleteAll(force: Bool) async throws
    /// Prunes stopped containers; returns the freed-space report text.
    func prune() async throws -> String
    func export(_ id: String, to outputPath: String) async throws
    func copy(from: String, to: String) async throws
}

public actor ContainerService: ContainerServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func list() async throws -> [Micropod_V1_Container] {
        let output = try await client.run(ContainerCommandFactory.listContainers(all: true), timeout: .seconds(30))
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: Data(output.utf8), context: "container list")
        return entries.map(ModelMapper.container(from:))
    }

    public func inspect(_ id: String) async throws -> Data {
        let output = try await client.run(ContainerCommandFactory.inspectContainers([id]), timeout: .seconds(15))
        return Data(output.utf8)
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        let output = try await client.run(ContainerCommandFactory.run(request), timeout: .seconds(120))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        let output = try await client.run(ContainerCommandFactory.create(request), timeout: .seconds(120))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        let output = try await client.run(ContainerCommandFactory.exec(request), timeout: .seconds(60))
        return output
    }

    public func start(_ id: String) async throws {
        _ = try await client.run(ContainerCommandFactory.startContainer(id), timeout: .seconds(60))
    }

    public func stop(_ id: String, timeout: Int = 10) async throws {
        _ = try await client.run(ContainerCommandFactory.stopContainer(id, timeout: timeout), timeout: .seconds(90))
    }

    public func restart(_ id: String) async throws {
        try await stop(id, timeout: 10)
        try await start(id)
    }

    public func stopAll() async throws {
        _ = try await client.run(ContainerCommandFactory.stopAllContainers(), timeout: .seconds(120))
    }

    public func kill(_ id: String, signal: String = "KILL") async throws {
        _ = try await client.run(
            ContainerCommandFactory.killContainer(id, signal: signal), timeout: .seconds(30))
    }

    public func delete(_ id: String, force: Bool = false) async throws {
        _ = try await client.run(ContainerCommandFactory.deleteContainer(id, force: force), timeout: .seconds(30))
    }

    public func deleteAll(force: Bool = false) async throws {
        _ = try await client.run(ContainerCommandFactory.deleteAllContainers(force: force), timeout: .seconds(120))
    }

    public func prune() async throws -> String {
        let output = try await client.run(ContainerCommandFactory.pruneContainers(), timeout: .seconds(60))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func export(_ id: String, to outputPath: String) async throws {
        _ = try await client.run(ContainerCommandFactory.exportContainer(id, to: outputPath), timeout: .seconds(120))
    }

    public func copy(from: String, to: String) async throws {
        _ = try await client.run(ContainerCommandFactory.copyFile(from: from, to: to), timeout: .seconds(120))
    }
}
