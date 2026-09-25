import Foundation

public protocol VolumeServing: Sendable {
    func list() async throws -> [Micropod_V1_Volume]
    func create(name: String, size: String?, labels: [String], options: [String]) async throws
    func delete(_ name: String) async throws
    func prune() async throws -> String
    /// Creates `name` (size defaulting to the source's provisioned size,
    /// labels gaining `com.micropod.clone-of=<source>`) and clonefiles the
    /// source's backing image over the new volume's. `not_found` when the
    /// source does not exist; `failed_precondition` when a running or
    /// stopping container has it attached read-write (the clone would be
    /// crash-consistent).
    func clone(source: String, name: String, size: String?, labels: [String]) async throws -> Micropod_V1_Volume
    /// Promotes container `containerID`'s clone of `volume` to be the golden
    /// image (fsync + atomic rename under the per-volume lock). The
    /// container must be `stopped` and the golden not attached read-write
    /// (`failed_precondition`); a missing container, clone or volume is
    /// `not_found`. Returns the promoted image's allocated bytes.
    func commitClone(containerID: String, volume: String) async throws -> UInt64
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
    /// Attachment checks read the container list.
    private let containers: ContainerService

    public init(client: ContainerCLIClient) {
        self.client = client
        self.containers = ContainerService(client: client)
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

    /// Under the volume's lock, so a delete never lands between a
    /// `CommitVolumeClone`'s checks and its rename into this volume's dir.
    public func delete(_ name: String) async throws {
        try await VolumeLocks.shared.withLock(name) {
            _ = try await client.run(ContainerCommandFactory.deleteVolume(name), timeout: .seconds(30))
        }
    }

    /// Under every volume's lock (taken in sorted order), so the prune can
    /// neither remove a golden's directory between a `CommitVolumeClone`'s
    /// checks and its rename nor take away a golden it just promoted. The
    /// native backend delegates here too — `volume prune` has no XPC route.
    public func prune() async throws -> String {
        let names = try await list().map(\.id)
        return try await VolumeLocks.shared.withLocks(names) {
            let output = try await client.run(ContainerCommandFactory.pruneVolumes(), timeout: .seconds(60))
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func clone(source: String, name: String, size: String?, labels: [String]) async throws
        -> Micropod_V1_Volume
    {
        // Absence is a plain "not in the list": the CLI's own inspect error
        // text carries no code the Connect table could classify.
        let golden = try VolumeClone.requireVolume(try await volume(named: source), named: source)
        try VolumeClone.requireBackingImage(golden)
        try VolumeClone.requireQuiescent(
            golden, attachments: VolumeAttachments(entries: try await containers.entries()))
        try await create(
            name: name,
            size: VolumeClone.cloneSize(requested: size, source: golden),
            labels: VolumeClone.cloneLabels(labels, source: source),
            options: [])
        do {
            let created = try VolumeClone.requireVolume(try await volume(named: name), named: name)
            try VolumeClone.cloneImage(from: golden.source, to: created.source)
            return VolumeClone.withAllocatedBytes(created)
        } catch {
            // Never leave a half-made volume behind (an empty image under the
            // clone's name would masquerade as a cache miss forever).
            try? await delete(name)
            throw error
        }
    }

    public func commitClone(containerID: String, volume: String) async throws -> UInt64 {
        try await VolumeLocks.shared.withLock(volume) {
            let entries = try await containers.entries()
            try VolumeClone.requireStopped(containerID: containerID, in: entries)
            let clone = try VolumeClone.requireClone(containerID: containerID, volume: volume)
            let golden = try VolumeClone.requireVolume(try await self.volume(named: volume), named: volume)
            try VolumeClone.requireBackingImage(golden)
            try VolumeClone.requireQuiescent(golden, attachments: VolumeAttachments(entries: entries))
            return try VolumeClone.commit(clonePath: clone, goldenPath: golden.source)
        }
    }

    private func volume(named name: String) async throws -> Micropod_V1_Volume? {
        try await list().first { $0.id == name }
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
