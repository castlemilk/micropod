import Darwin
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

    /// A volume whose options a template reproduces (size and journal) is
    /// created from one (``VolumeTemplates``): at the apiserver's minimum
    /// size, then its image is replaced with a clone of the template, so the
    /// apiserver's volumes actor never formats a full-size image for it.
    /// Anything else, or any failure to use a template, formats as before.
    public func create(name: String, size: String?, labels: [String], options: [String]) async throws {
        var driverOpts = Self.keyValues(options)
        if let size, !size.isEmpty {
            // Same contract as `container volume create -s`: the size string
            // goes to the local driver as the `size` option.
            driverOpts["size"] = size
        }
        let labelMap = Self.keyValues(labels)
        if VolumeTemplates.enabledByEnvironment, let key = VolumeTemplates.Key(driverOpts: driverOpts),
            VolumeClone.isSafeVolumeName(name),
            let template = try? await VolumeTemplates.shared.template(for: key, format: formatTemplate(key))
        {
            try await VolumeLocks.shared.withLock(name) {
                try await createFromTemplate(name: name, key: key, template: template, labels: labelMap)
            }
            return
        }
        _ = try await api.volumeCreate(name: name, driverOpts: driverOpts, labels: labelMap)
    }

    /// The placeholder volume, then its image replaced with a clone of
    /// `template`. If the clone cannot be placed the placeholder is deleted
    /// and the volume is created the ordinary way, so a caller never gets a
    /// volume of the placeholder's size.
    private func createFromTemplate(name: String, key: VolumeTemplates.Key, template: String, labels: [String: String])
        async throws
    {
        var labels = labels
        labels[VolumeTemplates.templateLabel] = key.description
        labels[VolumeTemplates.sizeLabel] = String(VolumeClone.fileLength(atPath: template))
        let created = try await api.volumeCreate(
            name: name, driverOpts: VolumeTemplates.placeholderOpts, labels: labels)
        do {
            guard let entry = try VolumeTransform.entry(created) else {
                throw MicropodError.message("volumeCreate for '\(name)' returned an unexpected reply")
            }
            let volume = try VolumeClone.requireVolume(ModelMapper.volume(from: entry), named: name)
            try VolumeClone.cloneImage(from: template, to: volume.source)
        } catch {
            await VolumeTemplates.shared.invalidate(key)
            try? await api.volumeDelete(name: name)
            labels[VolumeTemplates.templateLabel] = nil
            labels[VolumeTemplates.sizeLabel] = nil
            _ = try await api.volumeCreate(name: name, driverOpts: key.driverOpts, labels: labels)
        }
    }

    /// Builds `key`'s template: the apiserver formats a scratch volume with
    /// the template's options (exactly the image it would make for such a
    /// volume), its image is cloned to `destination`, and the scratch volume
    /// is deleted.
    private func formatTemplate(_ key: VolumeTemplates.Key) -> @Sendable (String) async throws -> Void {
        { [api] destination in
            let scratch = "micropod-template-\(UUID().uuidString.prefix(8).lowercased())"
            let created = try await api.volumeCreate(
                name: scratch, driverOpts: key.driverOpts, labels: [VolumeTemplates.templateLabel: "scratch"])
            let cloned = Result {
                guard let entry = try VolumeTransform.entry(created) else {
                    throw MicropodError.message("volumeCreate for template '\(scratch)' returned an unexpected reply")
                }
                let volume = try VolumeClone.requireVolume(ModelMapper.volume(from: entry), named: scratch)
                guard copyfile(volume.source, destination, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                    throw MicropodError.message(
                        "could not clone template image \(volume.source): \(String(cString: strerror(errno)))")
                }
            }
            try? await api.volumeDelete(name: scratch)
            try cloned.get()
        }
    }

    /// Under the volume's lock, so a delete never lands between a
    /// `CommitVolumeClone`'s checks and its rename into this volume's dir.
    ///
    /// The apiserver removes the volume's directory while it holds both its
    /// volumes lock and its containers lock; a second name for the backing
    /// image makes that removal O(1), and the reclaimer frees the image
    /// afterwards. A refused delete (the volume is attached) keeps the image
    /// under its own name, so the second name is just dropped.
    public func delete(_ name: String) async throws {
        try await VolumeLocks.shared.withLock(name) {
            let image = api.volumeImagePath(name: name).flatMap { PayloadReclaimer.shared.stage($0) }
            defer { if let image { PayloadReclaimer.shared.settle(image) } }
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
            var cloneLabels = Self.keyValues(VolumeClone.cloneLabels(labels, source: source))
            if VolumeTemplates.enabledByEnvironment, size?.isEmpty ?? true {
                // The image is replaced with the golden's clone below, so the
                // apiserver need not format a full-size one first.
                driverOpts = VolumeTemplates.placeholderOpts
                cloneLabels[VolumeTemplates.sizeLabel] = String(VolumeClone.fileLength(atPath: golden.source))
            } else if let sizeSpec = VolumeClone.cloneSize(requested: size, source: golden) {
                driverOpts["size"] = sizeSpec
            }
            let created = try await api.volumeCreate(name: name, driverOpts: driverOpts, labels: cloneLabels)
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

    /// Every create that clones this golden waits for its lock, so the slow
    /// parts stay outside it: the clone's dirty pages are flushed first (the
    /// commit's own fsync under the lock then has little left to write), and
    /// the golden's configuration comes from ``APIServerClient/volumeConfig(name:)``
    /// rather than a `volumeInspect` that queues behind the apiserver's
    /// volume formats and deletes.
    public func commitClone(containerID: String, volume: String) async throws -> UInt64 {
        await NativeLifecycleOperations.shared.reconcileKnownExit(containerID)
        return try await Self.withCommitClaim(containerID: containerID) {
            if let clone = try? VolumeClone.clonePath(containerID: containerID, volume: volume) {
                VolumeClone.flush(clone.path)
            }
            return try await VolumeLocks.shared.withLock(volume) {
                let entries = try await entries()
                try VolumeClone.requireStopped(containerID: containerID, in: entries)
                let clone = try VolumeClone.requireClone(containerID: containerID, volume: volume)
                try VolumeClone.requireMounted(clone: clone, containerID: containerID, volume: volume, in: entries)
                let golden = try VolumeClone.requireVolume(try await self.golden(named: volume), named: volume)
                try VolumeClone.requireBackingImage(golden)
                try VolumeClone.requireQuiescent(golden, attachments: VolumeAttachments(entries: entries))
                return try VolumeClone.commit(clonePath: clone, goldenPath: golden.source)
            }
        }
    }

    /// Keep the stopped check and cache replacement under the same per-ID
    /// ownership as native start/create/delete. Lock order is ID then volume.
    static func withCommitClaim<T>(
        containerID: String, claims: ContainerLifecycleClaims = .shared,
        unstarted: @Sendable (String) async -> Bool = { await UnstartedCreates.shared.contains($0) },
        body: () async throws -> T
    ) async throws -> T {
        guard let claim = await claims.claimIfIdle(containerID, kind: .cleanup) else {
            throw MicropodError.message(
                "failedPrecondition: container \(containerID) has unfinished lifecycle work; cannot commit its cache")
        }
        do {
            try Task.checkCancellation()
            guard await !unstarted(containerID) else {
                throw MicropodError.message(
                    "failedPrecondition: container \(containerID) has not started; cannot commit its cache")
            }
            let result = try await body()
            await claims.finish(claim)
            return result
        } catch {
            await claims.finish(claim)
            throw error
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

    /// A golden's configuration for a commit: remembered while its backing
    /// image exists (``APIServerClient/volumeConfig(name:)``), inspected
    /// otherwise; nil when the volume is absent.
    private func golden(named name: String) async throws -> Micropod_V1_Volume? {
        guard let raw = try await api.volumeConfig(name: name), let entry = try VolumeTransform.entry(raw)
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
