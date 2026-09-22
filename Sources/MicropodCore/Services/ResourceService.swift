import Foundation

public protocol VolumeServing: Sendable {
    func list() async throws -> [Micropod_V1_Volume]
    func create(name: String, size: String?, labels: [String], options: [String]) async throws
    func delete(_ name: String) async throws
    func prune() async throws -> String
}

public protocol NetworkServing: Sendable {
    func list() async throws -> [Micropod_V1_Network]
    func create(
        name: String, internal: Bool, subnet: String?, subnetV6: String?, driver: String?,
        options: [String], labels: [String]
    ) async throws
    func delete(_ name: String) async throws
    func prune() async throws -> String
}

public protocol RegistryServing: Sendable {
    func list() async throws -> [Micropod_V1_RegistryLogin]
    func login(server: String, username: String, password: String) async throws
    func logout(_ server: String) async throws
}

public struct VolumeService: VolumeServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func list() async throws -> [Micropod_V1_Volume] {
        let output = try await client.run(ContainerCommandFactory.listVolumes(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(
            VolumeListEntry.self, from: Data(output.utf8), context: "volume list")
        return entries.map(ModelMapper.volume(from:))
    }

    public func create(
        name: String, size: String? = nil, labels: [String] = [], options: [String] = []
    ) async throws {
        _ = try await client.run(
            ContainerCommandFactory.createVolume(name, size: size, labels: labels, options: options),
            timeout: .seconds(30))
    }

    public func delete(_ name: String) async throws {
        _ = try await client.run(ContainerCommandFactory.deleteVolume(name), timeout: .seconds(30))
    }

    public func prune() async throws -> String {
        let output = try await client.run(ContainerCommandFactory.pruneVolumes(), timeout: .seconds(60))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NetworkService: NetworkServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func list() async throws -> [Micropod_V1_Network] {
        let output = try await client.run(ContainerCommandFactory.listNetworks(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(
            NetworkListEntry.self, from: Data(output.utf8), context: "network list")
        return entries.map(ModelMapper.network(from:))
    }

    public func create(
        name: String,
        internal internalNetwork: Bool = false,
        subnet: String? = nil,
        subnetV6: String? = nil,
        driver: String? = nil,
        options: [String] = [],
        labels: [String] = []
    ) async throws {
        _ = try await client.run(
            ContainerCommandFactory.createNetwork(
                name, internal: internalNetwork, subnet: subnet, subnetV6: subnetV6, driver: driver,
                options: options, labels: labels),
            timeout: .seconds(30))
    }

    public func delete(_ name: String) async throws {
        _ = try await client.run(ContainerCommandFactory.deleteNetwork(name), timeout: .seconds(30))
    }

    public func prune() async throws -> String {
        let output = try await client.run(ContainerCommandFactory.pruneNetworks(), timeout: .seconds(60))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RegistryService: RegistryServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func list() async throws -> [Micropod_V1_RegistryLogin] {
        let output = try await client.run(ContainerCommandFactory.registryList(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(
            RegistryEntry.self, from: Data(output.utf8), context: "registry list")
        return entries.map { entry in
            var login = Micropod_V1_RegistryLogin()
            login.server = entry.server ?? entry.name ?? ""
            login.username = entry.username ?? ""
            login.scheme = entry.scheme ?? ""
            return login
        }
    }

    public func login(server: String, username: String, password: String) async throws {
        _ = try await client.run(
            ContainerCommandFactory.registryLogin(server: server, username: username, password: password),
            timeout: .seconds(30))
    }

    public func logout(_ server: String) async throws {
        _ = try await client.run(ContainerCommandFactory.registryLogout(server), timeout: .seconds(15))
    }
}
