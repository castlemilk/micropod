import Foundation
import MicropodCore

/// `VolumeServing` over `container-apiserver` XPC routes — no process spawn
/// on the cache hot path. List/create/delete/inspect are single round trips;
/// `clone` and `commitClone` add the clonefile/rename work from
/// ``VolumeClone``. `prune` has no XPC route (the CLI composes list + delete
/// itself) and stays on the embedded CLI service.
public struct NativeVolumeService: VolumeServing {
    private let api: APIServerClient
    /// CLI fallback for operations without a native route.
    private let cli: VolumeService

    public init(api: APIServerClient, cli: VolumeService) {
        self.api = api
        self.cli = cli
    }

    /// Polled (the agent's disk manager, the app): a recent answer, never
    /// one from before this process's own last volume write.
    public func list() async throws -> [Micropod_V1_Volume] {
        try VolumeTransform.entries(try await api.volumeList(policy: .polling)).map(ModelMapper.volume(from:))
    }

    public func create(name: String, size: String?, labels: [String], options: [String]) async throws {
        var driverOpts = Self.keyValues(options)
        if let size, !size.isEmpty {
            // Same contract as `container volume create -s`: the size string
            // goes to the local driver as the `size` option.
            driverOpts["size"] = size
        }
        _ = try await api.volumeCreate(name: name, driverOpts: driverOpts, labels: Self.keyValues(labels))
    }

    /// Under the volume's lock, so a delete never lands between a
    /// `CommitVolumeClone`'s checks and its rename into this volume's dir.
    public func delete(_ name: String) async throws {
        try await VolumeLocks.shared.withLock(name) {
            try await api.volumeDelete(name: name)
        }
    }

    public func prune() async throws -> String {
        try await cli.prune()
    }

    /// Under the source's and the new volume's locks (sorted acquisition,
    /// as `prune` takes every volume's), so a concurrent `volume prune` or
    /// `DeleteVolume` can remove neither the golden nor the half-made clone
    /// volume between the checks and the clonefile.
    public func clone(source: String, name: String, size: String?, labels: [String]) async throws
        -> Micropod_V1_Volume
    {
        try VolumeClone.requireDistinct(source: source, name: name)
        return try await VolumeLocks.shared.withLocks([source, name]) {
            let golden = try VolumeClone.requireVolume(try await volume(named: source), named: source)
            try VolumeClone.requireBackingImage(golden)
            try VolumeClone.requireQuiescent(golden, attachments: VolumeAttachments(entries: try await entries()))
            var driverOpts: [String: String] = [:]
            if let sizeSpec = VolumeClone.cloneSize(requested: size, source: golden) {
                driverOpts["size"] = sizeSpec
            }
            let created = try await api.volumeCreate(
                name: name,
                driverOpts: driverOpts,
                labels: Self.keyValues(VolumeClone.cloneLabels(labels, source: source)))
            do {
                guard let entry = try VolumeTransform.entry(created) else {
                    throw MicropodError.message("volumeCreate for '\(name)' returned an unexpected reply")
                }
                let volume = try VolumeClone.requireVolume(ModelMapper.volume(from: entry), named: name)
                try VolumeClone.cloneImage(from: golden.source, to: volume.source)
                return VolumeClone.withAllocatedBytes(volume)
            } catch {
                // Never leave a half-made volume behind (an empty image under the
                // clone's name would masquerade as a cache miss forever). The
                // name's lock is held here, so this goes straight to the route.
                try? await api.volumeDelete(name: name)
                throw error
            }
        }
    }

    public func commitClone(containerID: String, volume: String) async throws -> UInt64 {
        try await VolumeLocks.shared.withLock(volume) {
            let entries = try await entries()
            try VolumeClone.requireStopped(containerID: containerID, in: entries)
            let clone = try VolumeClone.requireClone(containerID: containerID, volume: volume)
            try VolumeClone.requireMounted(clone: clone, containerID: containerID, volume: volume, in: entries)
            let golden = try VolumeClone.requireVolume(try await self.volume(named: volume), named: volume)
            try VolumeClone.requireBackingImage(golden)
            try VolumeClone.requireQuiescent(golden, attachments: VolumeAttachments(entries: entries))
            return try VolumeClone.commit(clonePath: clone, goldenPath: golden.source)
        }
    }

    // MARK: - Internals

    /// `volumeInspect` as the curated model; nil when the volume is absent.
    private func volume(named name: String) async throws -> Micropod_V1_Volume? {
        guard let raw = try await api.volumeInspect(name: name, policy: .patient),
            let entry = try VolumeTransform.entry(raw)
        else { return nil }
        return ModelMapper.volume(from: entry)
    }

    /// The clone and commit guards' container list: fresh, and as patient
    /// as the write it guards.
    private func entries() async throws -> [ContainerListEntry] {
        try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: await api.list(policy: .patient), context: "container list")
    }

    /// `key=value` specs → dictionary (a bare `key` maps to "").
    private static func keyValues(_ specs: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for spec in specs {
            let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            result[String(key)] = parts.count == 2 ? String(parts[1]) : ""
        }
        return result
    }
}
