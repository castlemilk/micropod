import Crypto
import Darwin
import Foundation
import MicropodCore

/// Immutable metadata stamped inside `<root>/versions/<id>/payload-manifest.json`.
public struct HVFPayloadManifest: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public static let fileName = "payload-manifest.json"
    /// The `origin` of the copy of a flat (pre-versioning) install that the
    /// first stage over it makes, so the first update can roll back.
    public static let flatOrigin = "flat"

    public var schema: Int
    public var version: String
    public var revision: String
    public var installedAt: Date
    public var digests: [String: String]
    /// nil for a staged release; `flatOrigin` for an imported flat install.
    public var origin: String?

    public init(
        version: String, revision: String = "unknown", installedAt: Date = Date(), digests: [String: String] = [:],
        origin: String? = nil
    ) {
        schema = Self.currentSchema
        self.version = version
        self.revision = revision
        self.installedAt = installedAt
        self.digests = digests
        self.origin = origin
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func load(from directory: URL) -> HVFPayloadManifest? {
        let file = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(HVFPayloadManifest.self, from: data)
    }

    public func save(to directory: URL) throws {
        try HVFFiles.writeAtomically(
            try Self.encoder.encode(self), to: directory.appendingPathComponent(Self.fileName))
    }
}

/// Where a rootless HVF payload update comes from.
public enum HVFPayloadSource: Sendable, Equatable {
    /// A `.app` bundle (`Contents/MacOS/micropod-vmm` + `Contents/Resources/...`)
    /// or a directory holding `micropod-vmm`, `vmlinux-hvf`/`Image`,
    /// `mp-hvf-init.cpio`, and `micropod-oci-tools`/`tools`.
    case directory(URL)
    case explicit(vmm: URL, kernel: URL, initrd: URL, tools: URL)
}

/// One payload's boot assets, every one derived from a single directory: a
/// version under `<root>/versions/`, or the root itself for the legacy flat
/// layout. A launch built from one value can never mix two versions.
public struct HVFMachinePayload: Sendable, Equatable {
    /// `id` of the legacy flat layout.
    public static let flatID = "flat"

    public let directory: URL
    public let isVersioned: Bool

    public init(directory: URL, isVersioned: Bool) {
        self.directory = directory.standardizedFileURL
        self.isVersioned = isVersioned
    }

    public var vmm: URL { directory.appendingPathComponent("micropod-vmm") }
    public var kernel: URL { directory.appendingPathComponent("Image") }
    public var initrd: URL { directory.appendingPathComponent("mp-hvf-init.cpio") }
    public var tools: URL { directory.appendingPathComponent("tools") }
    /// The version directory's name, or `flat`.
    public var id: String { isVersioned ? directory.lastPathComponent : Self.flatID }
    public var canonicalPath: String { HVFMachineLayout.canonicalPath(directory.path) }
    public func manifest() -> HVFPayloadManifest? { isVersioned ? HVFPayloadManifest.load(from: directory) : nil }

    /// The VMM, kernel and initrd are files and the tool bundle has `runner/start.sh`.
    public var hasBootAssets: Bool {
        [vmm, kernel, initrd].allSatisfy(HVFMachineLayout.isRegularFile)
            && FileManager.default.fileExists(atPath: tools.appendingPathComponent("runner/start.sh").path)
    }

    /// The manifest version, or the id when there is none.
    var label: String { manifest().map { "\($0.version) (\(id))" } ?? id }
}

/// Snapshot of the payload pointers and of what the live machine loaded.
public struct HVFPayloadStatus: Codable, Sendable, Equatable {
    /// What a newly started supervisor boots (absent: the flat layout).
    public var currentPath: String?
    /// What `current` named before the last activation or rollback.
    public var previousPath: String?
    /// Staged and waiting for `update hvf apply`.
    public var stagedPath: String?
    /// The last payload that booted and passed the health probes.
    public var knownGoodPath: String?
    public var current: HVFPayloadManifest?
    public var previous: HVFPayloadManifest?
    public var staged: HVFPayloadManifest?
    public var knownGood: HVFPayloadManifest?
    public var runningPath: String?
    public var runningVersion: String?
    public var runningRevision: String?
    /// An activation would change what runs: a staged payload (or `current`)
    /// differs from the one the live machine loaded or, while it is
    /// stopped, a staged payload differs from `current`.
    public var updatePending: Bool
    public var availableVersions: [String]
    /// Why the last `update hvf apply` of the payload still staged failed;
    /// nil when it has not failed (or something else is staged now).
    public var lastActivationFailure: String?
}

/// The last activation that failed, kept so `status` can say why the
/// payload is still staged (`<root>/activation-failure.json`).
struct HVFActivationFailureRecord: Codable, Equatable {
    var stagedID: String
    var version: String?
    var failure: String
    var at: Date

    static func load(_ layout: HVFMachineLayout) -> HVFActivationFailureRecord? {
        guard let data = try? Data(contentsOf: layout.activationFailureRecord) else { return nil }
        return try? HVFPayloadManifest.decoder.decode(Self.self, from: data)
    }

    func save(_ layout: HVFMachineLayout) throws {
        try HVFFiles.writeAtomically(try HVFPayloadManifest.encoder.encode(self), to: layout.activationFailureRecord)
    }
}

/// Outcome of activating a staged HVF payload, or of a rollback.
public struct HVFActivationResult: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, Equatable {
        /// Nothing to do; nothing was stopped.
        case noop
        /// The target booted, passed the health probes and is now `current`
        /// and known-good.
        case activated
        /// Nothing was stopped: workloads still run, or whether they do
        /// could not be told (the drain check fails closed).
        case deferred
        /// The target failed; the machine was returned to known-good (or a
        /// rollback reached it) and passed the health probes again.
        case rolledBack = "rolled_back"
        /// The rollback boot failed its probes too.
        case failedRollback = "failed_rollback"
        /// The target failed and no known-good payload existed to return to.
        case failed
    }

    public var action: Action
    /// What ran (or, stopped, would boot) before the transaction.
    public var fromVersion: String?
    /// What runs (or, stopped, will boot) after it.
    public var toVersion: String?
    /// Workloads that held off a restart (`deferred`).
    public var activeContainers: Int
    public var detail: String
    /// What the transaction tried to boot.
    public var targetVersion: String?
    /// From the old VMM's exit (or a cold start) to the new guest answering
    /// `_ping`, for a boot that ran.
    public var switchoverMilliseconds: Int?

    public init(
        action: Action, fromVersion: String? = nil, toVersion: String? = nil, activeContainers: Int = 0,
        detail: String, targetVersion: String? = nil, switchoverMilliseconds: Int? = nil
    ) {
        self.action = action
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.activeContainers = activeContainers
        self.detail = detail
        self.targetVersion = targetVersion
        self.switchoverMilliseconds = switchoverMilliseconds
    }
}

// MARK: - What an update transaction drives

/// The machine as an activation or rollback drives it.
public protocol HVFUpdateMachine: Sendable {
    /// A supervisor holds the lock.
    func isRunning() -> Bool
    /// The payload directory the live supervisor loaded; nil when stopped.
    func loadedPayloadPath() -> String?
    /// Powers the guest off and waits for its supervisor to exit.
    func stop() async throws
    /// Starts a supervisor (which resolves its payload once) and returns
    /// once the guest's Docker API answers.
    func start() async throws
}

/// What a restart of the machine would interrupt.
public struct HVFWorkloads: Sendable, Equatable {
    /// Running containers (exec sessions run inside them).
    public var containers: Int
    /// Live Testcontainers reaper sessions.
    public var sessions: Int

    public init(containers: Int, sessions: Int = 0) {
        self.containers = containers
        self.sessions = sessions
    }

    public var total: Int { containers + sessions }

    public var summary: String {
        "\(containers) running container(s)" + (sessions > 0 ? " and \(sessions) live reaper session(s)" : "")
    }
}

/// Decides whether the machine is idle enough to restart.
public protocol HVFDrainCoordinating: Sendable {
    /// What a restart would interrupt now. Throws when that cannot be told;
    /// callers treat an error as busy, never as idle.
    func activeWorkloads() async throws -> HVFWorkloads
}

/// The health gate a boot must pass before its payload counts as known-good.
public protocol HVFHealthProbing: Sendable {
    /// nil when the guest passes every check, else the first that failed.
    func failure() async -> String?
}

/// Everything outside the payload store an activation or rollback uses.
public struct HVFUpdateEnvironment: Sendable {
    public var machine: any HVFUpdateMachine
    public var drain: any HVFDrainCoordinating
    public var probe: any HVFHealthProbing
    public var drainPollInterval: Duration
    /// Reads a payload's files once an activation has decided to boot it,
    /// before it stops the machine (`HVFPayloadStore.warm`).
    public var warm: @Sendable (URL) -> Void

    public init(
        machine: any HVFUpdateMachine, drain: any HVFDrainCoordinating, probe: any HVFHealthProbing,
        drainPollInterval: Duration = .milliseconds(500),
        warm: @escaping @Sendable (URL) -> Void = { HVFPayloadStore.warm(payloadDirectory: $0) }
    ) {
        self.machine = machine
        self.drain = drain
        self.probe = probe
        self.drainPollInterval = drainPollInterval
        self.warm = warm
    }

    /// The machine under `layout`, its guest Docker API for the drain check
    /// and the health probes.
    public static func live(layout: HVFMachineLayout) -> HVFUpdateEnvironment {
        let client = HVFMachineClient(layout: layout)
        return HVFUpdateEnvironment(
            machine: HVFClientUpdateMachine(client: client), drain: HVFGuestWorkloadDrain(client: client),
            probe: HVFGuestHealthProbe(client: client))
    }
}

public struct HVFClientUpdateMachine: HVFUpdateMachine {
    public let client: HVFMachineClient

    public init(client: HVFMachineClient) { self.client = client }

    public func isRunning() -> Bool { HVFFileLock.isHeld(client.layout.supervisorLock) }

    public func loadedPayloadPath() -> String? {
        guard isRunning(), let state = try? HVFMachineState.load(from: client.layout.state) else { return nil }
        return state.loadedPayloadPath.map(HVFMachineLayout.canonicalPath)
    }

    public func stop() async throws { try await client.stop() }

    public func start() async throws { try await client.ensureRunning() }
}

/// Running containers from the guest's `GET /containers/json` and live
/// reaper sessions from `/micropod/metrics`. Any failed, slow or unreadable
/// answer throws: an unknown count is never zero.
public struct HVFGuestWorkloadDrain: HVFDrainCoordinating {
    public let client: HVFMachineClient
    /// Per request; whole seconds (the socket's receive timeout).
    public var timeout: Duration

    public init(client: HVFMachineClient, timeout: Duration = .seconds(3)) {
        self.client = client
        self.timeout = timeout
    }

    public func activeWorkloads() async throws -> HVFWorkloads {
        let docker = client.docker
        let listed = try await docker.request("GET", "/containers/json", timeout: timeout)
        guard listed.status == 200, let containers = (try? listed.json()) as? [[String: Any]] else {
            throw MicropodError.message(
                "unavailable: hvf: GET /containers/json answered HTTP \(listed.status): \(listed.message)")
        }
        let metrics = try await docker.request("GET", "/micropod/metrics", timeout: timeout)
        guard metrics.status == 200, let object = (try? metrics.json()) as? [String: Any] else {
            throw MicropodError.message(
                "unavailable: hvf: GET /micropod/metrics answered HTTP \(metrics.status): \(metrics.message)")
        }
        let sessions = ((object["reaper"] as? [String: Any])?["active_sessions"] as? NSNumber)?.intValue ?? 0
        return HVFWorkloads(containers: containers.count, sessions: max(sessions, 0))
    }
}

/// `/_ping`, `/micropod/metrics` and the cache status (`/micropod/caches`):
/// with `caches.ext4` attached, the guest must have mounted it.
public struct HVFGuestHealthProbe: HVFHealthProbing {
    public let client: HVFMachineClient
    public var timeout: Duration

    public init(client: HVFMachineClient, timeout: Duration = .seconds(5)) {
        self.client = client
        self.timeout = timeout
    }

    public func failure() async -> String? {
        guard await HVFMachineClient.ping(client.layout.dockerSocket, timeout: timeout) else {
            return "GET /_ping did not answer"
        }
        do {
            let metrics = try await client.docker.request("GET", "/micropod/metrics", timeout: timeout)
            guard metrics.status == 200 else { return "GET /micropod/metrics answered HTTP \(metrics.status)" }
        } catch {
            return "GET /micropod/metrics: \(error.localizedDescription)"
        }
        let inventory: HVFCacheInspection
        do {
            inventory = try await client.cacheInspection(includeStats: false, timeout: timeout)
        } catch {
            return "GET /micropod/caches: \(error.localizedDescription)"
        }
        return Self.cacheDiskFailure(
            inventory, attached: HVFMachineLayout.isRegularFile(client.layout.cacheDisk),
            path: client.layout.cacheDisk.path)
    }

    /// Why a guest that answers is still not healthy for its caches, or nil.
    /// `attached`: the root has `caches.ext4`, so micropod-vmm attaches it
    /// and the guest is told to mount it. A machine without one passes: its
    /// stores live on the OS disk by design. A guest that cannot tell (an
    /// engine that predates the report, an unreadable mountinfo) passes too;
    /// only a guest that says the disk is not mounted, or that shared caches
    /// are off, fails.
    static func cacheDiskFailure(_ inventory: HVFCacheInspection, attached: Bool, path: String) -> String? {
        if let why = inventory.sharedCachesOffReason {
            return "GET /micropod/caches: shared caches are off this boot: \(why)"
        }
        guard attached, let disk = inventory.cacheDisk, !disk.mounted, disk.mountInfoError == nil else { return nil }
        return "GET /micropod/caches: the guest did not mount its cache disk (\(path) is attached; guest state "
            + "\(disk.state ?? "unknown"), device \(disk.device ?? "none")); every container would run uncached"
    }
}

// MARK: - Store

/// Rootless versioned payload store for the HVF microVM engine.
///
/// ```
/// <root>/versions/<version>-<shortrev>/   read-only once committed
///   micropod-vmm  Image  mp-hvf-init.cpio  tools/  payload-manifest.json
/// <root>/staged     -> versions/<id>   staged, waiting for an activation
/// <root>/current    -> versions/<id>   what a new supervisor boots
/// <root>/known-good -> versions/<id>   last boot that passed the probes
/// <root>/previous   -> versions/<id>   `current` before the last change
/// <root>/trial      -> versions/<id>   an activation's probe boot
/// <root>/update.lock                   one transaction at a time
/// ```
///
/// Staging writes a new immutable version and the `staged` pointer and
/// nothing else, so no relaunch, `machine start` or crash recovery can boot
/// an unverified payload. Activation drains (failing closed), boots the
/// staged payload through `trial`, probes it, and only then moves `current`
/// and `known-good`; on any failure it returns to known-good and probes that
/// again. Rollback targets known-good by name, so repeating one changes
/// nothing. Stage, activate, rollback and prune each hold `update.lock`; a
/// second caller gets an `unavailable` (busy) error.
public enum HVFPayloadStore {
    public struct ResolvedAssets: Sendable, Equatable {
        public var vmm: URL
        public var kernel: URL
        public var initrd: URL
        public var tools: URL
    }

    /// Resolves HVF asset paths from either a `.app` bundle or a flat directory.
    public static func resolveAssets(from source: HVFPayloadSource) throws -> ResolvedAssets {
        let fm = FileManager.default
        switch source {
        case .explicit(let vmm, let kernel, let initrd, let tools):
            return try validateResolved(
                ResolvedAssets(
                    vmm: canonicalURL(vmm), kernel: canonicalURL(kernel), initrd: canonicalURL(initrd),
                    tools: canonicalURL(tools)))
        case .directory(let rawDir):
            let dir = canonicalURL(rawDir)
            let isApp =
                dir.pathExtension == "app"
                || fm.fileExists(atPath: dir.appendingPathComponent("Contents/MacOS").path)
            let binDir = isApp ? dir.appendingPathComponent("Contents/MacOS") : dir
            let resDir = isApp ? dir.appendingPathComponent("Contents/Resources") : dir

            func firstExisting(_ candidates: [URL]) -> URL? {
                candidates.first { fm.fileExists(atPath: $0.path) }.map(canonicalURL)
            }
            guard let vmm = firstExisting([binDir.appendingPathComponent("micropod-vmm")]) else {
                throw MicropodError.message("invalidArgument: no micropod-vmm found in \(dir.path)")
            }
            guard
                let kernel = firstExisting([
                    resDir.appendingPathComponent("vmlinux-hvf"), resDir.appendingPathComponent("Image"),
                ])
            else {
                throw MicropodError.message("invalidArgument: no vmlinux-hvf or Image found in \(dir.path)")
            }
            guard let initrd = firstExisting([resDir.appendingPathComponent("mp-hvf-init.cpio")]) else {
                throw MicropodError.message("invalidArgument: no mp-hvf-init.cpio found in \(dir.path)")
            }
            guard
                let tools = firstExisting([
                    resDir.appendingPathComponent("micropod-oci-tools"), resDir.appendingPathComponent("tools"),
                ])
            else {
                throw MicropodError.message("invalidArgument: no micropod-oci-tools or tools/ found in \(dir.path)")
            }
            return try validateResolved(ResolvedAssets(vmm: vmm, kernel: kernel, initrd: initrd, tools: tools))
        }
    }

    private static func validateResolved(_ assets: ResolvedAssets) throws -> ResolvedAssets {
        let fm = FileManager.default
        for (name, url) in [
            ("micropod-vmm", assets.vmm), ("Image", assets.kernel), ("mp-hvf-init.cpio", assets.initrd),
        ] {
            guard HVFMachineLayout.isRegularFile(url) else {
                throw MicropodError.message("invalidArgument: \(name) at \(url.path) is not a regular file")
            }
        }
        guard fm.fileExists(atPath: assets.tools.appendingPathComponent("runner/start.sh").path) else {
            throw MicropodError.message(
                "invalidArgument: \(assets.tools.path) is not a valid guest tool bundle (missing runner/start.sh)")
        }
        return assets
    }

    // MARK: Status

    /// Reads the pointers and the live machine's loaded payload without booting anything.
    public static func status(layout: HVFMachineLayout) -> HVFPayloadStatus {
        let current = pointed(layout.currentLink, layout)
        let previous = pointed(layout.previousLink, layout)
        let staged = pointed(layout.stagedLink, layout)
        let knownGood = pointed(layout.knownGoodLink, layout)
        let alive = HVFFileLock.isHeld(layout.supervisorLock)
        let state = alive ? (try? HVFMachineState.load(from: layout.state)) : nil
        // A supervisor that recorded nothing predates versioned payloads: it booted the flat layout.
        let runningPath = alive ? HVFMachineLayout.canonicalPath(state?.loadedPayloadPath ?? layout.root.path) : nil

        let updatePending: Bool
        if let runningPath {
            updatePending = [staged, current].contains { payload in
                payload.map { !runs(runningPath, $0, layout: layout) } ?? false
            }
        } else {
            updatePending = staged.map { $0.canonicalPath != current?.canonicalPath } ?? false
        }

        let versions =
            ((try? FileManager.default.contentsOfDirectory(atPath: layout.versionsDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()

        let failure = HVFActivationFailureRecord.load(layout).flatMap { record in
            record.stagedID == staged?.id ? "\(record.failure) (\(record.at.formatted(.iso8601)))" : nil
        }

        return HVFPayloadStatus(
            currentPath: current?.canonicalPath,
            previousPath: previous?.canonicalPath,
            stagedPath: staged?.canonicalPath,
            knownGoodPath: knownGood?.canonicalPath,
            current: current?.manifest(),
            previous: previous?.manifest(),
            staged: staged?.manifest(),
            knownGood: knownGood?.manifest(),
            runningPath: runningPath,
            runningVersion: state?.loadedPayloadVersion,
            runningRevision: state?.loadedPayloadRevision,
            updatePending: updatePending,
            availableVersions: versions,
            lastActivationFailure: failure)
    }

    // MARK: Stage

    /// Copies a payload into a new immutable `<root>/versions/<id>/`, verifies
    /// its digests (and, with `verifySignature`, the VMM's hypervisor
    /// entitlement), and points `staged` at it. `current` does not move:
    /// nothing boots the payload until `activate` has probed it. Safe while
    /// the machine runs.
    ///
    /// The first stage over a flat install first copies that install into
    /// `versions/legacy-<digest>` and makes it `current` and `known-good`,
    /// so a failed first activation has something to roll back to.
    @discardableResult
    public static func stage(
        from source: HVFPayloadSource,
        version: String,
        revision: String = "unknown",
        layout: HVFMachineLayout,
        verifySignature: Bool = true,
        progress: @Sendable (String) -> Void = { _ in }
    ) throws -> HVFPayloadManifest {
        try layout.validatePaths()
        if layout.installInProgress { throw layout.installInProgressError() }
        let assets = try resolveAssets(from: source)
        if verifySignature {
            try HVFMachineInstaller.verifyHypervisorEntitlement(assets.vmm)
        }
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let lock = try transactionLock(layout)
        defer { lock.release() }

        try migrateLegacyStore(layout: layout, loaded: recordedLoadedPath(layout), progress: progress)
        try importFlatInstallIfNeeded(layout: layout, progress: progress)
        progress("staging HVF payload \(sanitizeVersionID(version: version, revision: revision))…")
        let (name, manifest) = try commit(
            assets, version: version, revision: revision, origin: nil,
            id: sanitizeVersionID(version: version, revision: revision), layout: layout,
            verifySignature: verifySignature)
        try atomicSymlink(destination: "versions/\(name)", at: layout.stagedLink)
        let active = pointed(layout.currentLink, layout)?.id ?? HVFMachinePayload.flatID
        progress("staged \(name); the machine keeps booting \(active) until `micropod update hvf apply` verifies it")
        return manifest
    }

    /// Drops `staged` when it still names `manifest`: an update that staged
    /// a payload and then failed. The directory stays until a prune.
    public static func unstage(layout: HVFMachineLayout, manifest: HVFPayloadManifest) throws {
        guard FileManager.default.fileExists(atPath: layout.root.path) else { return }
        let lock = try transactionLock(layout)
        defer { lock.release() }
        guard let staged = pointed(layout.stagedLink, layout), staged.manifest() == manifest else { return }
        unlink(layout.stagedLink.path)
    }

    /// With no `current` and a complete flat install, copies the flat
    /// assets into `versions/legacy-<digest>` and points `current` and
    /// `known-good` at it. The copies are byte-identical to what a running
    /// flat machine loaded, so nothing that runs changes.
    static func importFlatInstallIfNeeded(layout: HVFMachineLayout, progress: @Sendable (String) -> Void) throws {
        guard pointed(layout.currentLink, layout) == nil, let imported = try importFlat(layout: layout) else { return }
        try atomicSymlink(destination: "versions/\(imported.id)", at: layout.currentLink)
        try atomicSymlink(destination: "versions/\(imported.id)", at: layout.knownGoodLink)
        progress(
            "imported the flat install as \(imported.id) (current and known-good), so this update can roll back to it")
    }

    /// A read-only `versions/legacy-<digest>` copy of a complete flat
    /// install (the same directory again for the same bytes); nil without one.
    private static func importFlat(layout: HVFMachineLayout) throws -> HVFMachinePayload? {
        let flat = HVFMachinePayload(directory: layout.root, isVersioned: false)
        guard flat.hasBootAssets else { return nil }
        var hasher = SHA256()
        for file in [flat.vmm, flat.kernel, flat.initrd] { hasher.update(data: Data(try sha256File(file).utf8)) }
        let short = String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
        let assets = ResolvedAssets(vmm: flat.vmm, kernel: flat.kernel, initrd: flat.initrd, tools: flat.tools)
        let (name, _) = try commit(
            assets, version: "legacy-flat", revision: short, origin: HVFPayloadManifest.flatOrigin,
            id: "legacy-\(short)", layout: layout, verifySignature: false)
        return HVFMachinePayload(directory: layout.versionsDirectory.appendingPathComponent(name), isVersioned: true)
    }

    // MARK: Stores written by the updater before known-good

    /// Brings a store the earlier updater wrote under the current rules.
    /// That updater's `stage` moved `current` straight to the new payload
    /// and kept no `staged` or `known-good`, and its version directories are
    /// writable. Here:
    ///
    /// - every version directory is made read-only;
    /// - a `current` that the machine runs (or, stopped, last ran) becomes
    ///   known-good: it is what the rig serves with;
    /// - a `current` that never booted becomes the staged payload, so only a
    ///   probed `update hvf apply` boots it, and what ran before it (the
    ///   loaded payload, else `previous`, else the flat install, imported)
    ///   becomes `current` and known-good.
    ///
    /// Does nothing once known-good exists, so it runs once. `loaded` is the
    /// payload the machine runs, or last ran; nil when that is not known.
    /// Callers hold `update.lock`.
    static func migrateLegacyStore(
        layout: HVFMachineLayout, loaded: String?, progress: @Sendable (String) -> Void = { _ in }
    ) throws {
        guard pointed(layout.knownGoodLink, layout) == nil, let current = pointed(layout.currentLink, layout),
            current.manifest()?.origin != HVFPayloadManifest.flatOrigin
        else { return }
        for dir in versionDirectories(layout) { setReadOnly(dir, true) }
        if let loaded, runs(loaded, current, layout: layout) {
            try atomicSymlink(destination: "versions/\(current.id)", at: layout.knownGoodLink)
            progress("recorded \(current.label), which the machine runs, as known-good")
            return
        }
        let loadedPayload = loaded.flatMap { payload(atLoadedPath: $0, layout: layout) }
        let previous = pointed(layout.previousLink, layout).flatMap { $0 == current ? nil : $0 }
        guard let fallback = try loadedPayload ?? previous ?? importFlat(layout: layout), fallback != current else {
            // Nothing else to boot: current stays, with no known-good, until
            // an activation passes.
            return
        }
        if pointed(layout.stagedLink, layout) == nil {
            try atomicSymlink(destination: "versions/\(current.id)", at: layout.stagedLink)
        }
        try atomicSymlink(destination: "versions/\(fallback.id)", at: layout.currentLink)
        try atomicSymlink(destination: "versions/\(fallback.id)", at: layout.knownGoodLink)
        progress(
            "\(current.label) was staged by an earlier updater and never verified: it is staged again for "
                + "`micropod update hvf apply`, and \(fallback.label) is current and known-good")
    }

    /// The version directory, or imported flat install, a machine that
    /// loaded `path` booted; nil when it no longer exists.
    private static func payload(atLoadedPath path: String, layout: HVFMachineLayout) -> HVFMachinePayload? {
        let canonical = HVFMachineLayout.canonicalPath(path)
        if canonical == HVFMachineLayout.canonicalPath(layout.root.path) { return try? importFlat(layout: layout) }
        let dir = URL(fileURLWithPath: canonical)
        guard
            HVFMachineLayout.canonicalPath(dir.deletingLastPathComponent().path)
                == HVFMachineLayout.canonicalPath(layout.versionsDirectory.path),
            HVFPayloadManifest.load(from: dir) != nil
        else { return nil }
        return HVFMachinePayload(directory: dir, isVersioned: true)
    }

    private static func versionDirectories(_ layout: HVFMachineLayout) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.versionsDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { layout.versionsDirectory.appendingPathComponent($0) }
    }

    /// What the live supervisor loaded (the flat root for one that predates
    /// the record), else what the last one recorded; nil when unknown.
    static func recordedLoadedPath(_ layout: HVFMachineLayout) -> String? {
        let state = try? HVFMachineState.load(from: layout.state)
        if HVFFileLock.isHeld(layout.supervisorLock) { return state?.loadedPayloadPath ?? layout.root.path }
        return state?.loadedPayloadPath
    }

    /// `migrateLegacyStore` before a supervisor starts, so a payload the
    /// earlier updater staged never boots unprobed. Skipped while another
    /// transaction holds `update.lock`: an activation migrated first.
    public static func migrateLegacyStoreBeforeBoot(layout: HVFMachineLayout) {
        guard FileManager.default.fileExists(atPath: layout.currentLink.path),
            !FileManager.default.fileExists(atPath: layout.knownGoodLink.path),
            let lock = try? HVFFileLock.acquire(layout.updateLock, wait: .zero)
        else { return }
        defer { lock.release() }
        try? migrateLegacyStore(layout: layout, loaded: recordedLoadedPath(layout))
    }

    /// Points `staged` at `previous`, so `activate` boots, probes and
    /// commits it like any other payload: the way back to the release
    /// before the one an activation made known-good.
    @discardableResult
    public static func restagePrevious(layout: HVFMachineLayout) throws -> HVFPayloadManifest {
        let lock = try transactionLock(layout)
        defer { lock.release() }
        guard let previous = pointed(layout.previousLink, layout) else {
            throw MicropodError.message("failedPrecondition: no previous HVF payload under \(layout.root.path)")
        }
        guard previous != pointed(layout.currentLink, layout) else {
            throw MicropodError.message("failedPrecondition: the previous HVF payload \(previous.label) is current")
        }
        try verify(payloadDirectory: previous.directory)
        try atomicSymlink(destination: "versions/\(previous.id)", at: layout.stagedLink)
        return try loadManifest(previous.directory)
    }

    /// Copies `assets` into a fresh directory beside the versions, records
    /// and re-checks their digests, and renames it to `versions/<id>` (or a
    /// digest-suffixed name: an existing directory is never rewritten, and
    /// one with the same digests is reused). The result is read-only.
    private static func commit(
        _ assets: ResolvedAssets, version: String, revision: String, origin: String?, id: String,
        layout: HVFMachineLayout, verifySignature: Bool
    ) throws -> (name: String, manifest: HVFPayloadManifest) {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.versionsDirectory, withIntermediateDirectories: true)
        let stageDir = layout.versionsDirectory.appendingPathComponent(".stage-\(UUID().uuidString)")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        var cleanupStage = true
        defer { if cleanupStage { try? removeTree(stageDir) } }

        let payload = HVFMachinePayload(directory: stageDir, isVersioned: true)
        try cloneOrCopy(assets.vmm, to: payload.vmm)
        try cloneOrCopy(assets.kernel, to: payload.kernel)
        try cloneOrCopy(assets.initrd, to: payload.initrd)
        try cloneOrCopy(assets.tools, to: payload.tools)
        if verifySignature {
            try HVFMachineInstaller.verifyHypervisorEntitlement(payload.vmm)
        }

        var digests: [String: String] = [
            "micropod-vmm": try sha256File(payload.vmm),
            "Image": try sha256File(payload.kernel),
            "mp-hvf-init.cpio": try sha256File(payload.initrd),
            "tools/runner/start.sh": try sha256File(payload.tools.appendingPathComponent("runner/start.sh")),
        ]
        let jobBin = payload.tools.appendingPathComponent("runner/bin/job")
        if HVFMachineLayout.isRegularFile(jobBin) {
            digests["tools/runner/bin/job"] = try sha256File(jobBin)
        }
        try HVFPayloadManifest(version: version, revision: revision, digests: digests, origin: origin).save(
            to: stageDir)
        try verify(payloadDirectory: stageDir)

        let shortDigest = String((digests["micropod-vmm"] ?? "").prefix(8))
        for name in [id, "\(id)-\(shortDigest)"] {
            let existing = layout.versionsDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: existing.path) else {
                guard rename(stageDir.path, existing.path) == 0 else {
                    throw HVFFiles.posixError("commit payload \(existing.path)")
                }
                cleanupStage = false
                setReadOnly(existing, true)
                return (name, try loadManifest(existing))
            }
            if let manifest = HVFPayloadManifest.load(from: existing), manifest.digests == digests,
                manifest.version == version, manifest.revision == revision,
                (try? verify(payloadDirectory: existing)) != nil
            {
                return (name, manifest)
            }
        }
        let name = "\(id)-\(UUID().uuidString.prefix(8).lowercased())"
        let target = layout.versionsDirectory.appendingPathComponent(name)
        guard rename(stageDir.path, target.path) == 0 else {
            throw HVFFiles.posixError("commit payload \(target.path)")
        }
        cleanupStage = false
        setReadOnly(target, true)
        return (name, try loadManifest(target))
    }

    private static func loadManifest(_ directory: URL) throws -> HVFPayloadManifest {
        guard let manifest = HVFPayloadManifest.load(from: directory) else {
            throw MicropodError.message("internal: hvf: unreadable \(HVFPayloadManifest.fileName) in \(directory.path)")
        }
        return manifest
    }

    /// Re-verifies every SHA-256 digest recorded in `payload-manifest.json`.
    public static func verify(payloadDirectory dir: URL) throws {
        guard let manifest = HVFPayloadManifest.load(from: dir) else {
            throw MicropodError.message(
                "failedPrecondition: missing or unreadable payload-manifest.json in \(dir.path)")
        }
        for (rel, expected) in manifest.digests.sorted(by: { $0.key < $1.key }) {
            let file = dir.appendingPathComponent(rel)
            guard HVFMachineLayout.isRegularFile(file) else {
                throw MicropodError.message("failedPrecondition: payload asset missing: \(file.path)")
            }
            let actual = try sha256File(file)
            guard actual == expected else {
                throw MicropodError.message(
                    "failedPrecondition: payload digest mismatch for \(rel) (want \(expected.prefix(12)), got \(actual.prefix(12)))"
                )
            }
        }
    }

    // MARK: Activate

    /// Activates the staged payload.
    ///
    /// 1. Verifies its digests. Nothing staged, or already running it: `noop`.
    /// 2. With the machine running and no `force`: waits up to
    ///    `drainTimeout` for `environment.drain` to report nothing running.
    ///    Busy, or a drain check that fails, is `deferred` and stops nothing.
    ///    It then reads the payload into the page cache (`environment.warm`)
    ///    and checks the drain again, within what is left of `drainTimeout`,
    ///    for work that started during that read.
    /// 3. Points `trial` at it, stops the machine and starts it (the new
    ///    supervisor boots the trial), checks that the machine loaded it and
    ///    runs the health probes.
    /// 4. Passed: `current` and `known-good` name it, `staged` is cleared,
    ///    and a machine that was stopped is stopped again: `activated`.
    /// 5. Failed: `staged` is cleared, `current` names known-good, the
    ///    machine boots known-good and is probed again: `rolledBack`, or
    ///    `failedRollback` when that fails too, or `failed` when there is no
    ///    known-good payload.
    ///
    /// A stopped machine is booted for the probes: nothing is `activated`
    /// without a boot that passed them.
    public static func activate(
        layout: HVFMachineLayout,
        force: Bool = false,
        drainTimeout: Duration = .zero,
        environment: HVFUpdateEnvironment? = nil,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> HVFActivationResult {
        guard FileManager.default.fileExists(atPath: layout.root.path) else {
            return HVFActivationResult(action: .noop, detail: "no HVF machine under \(layout.root.path)")
        }
        let env = environment ?? .live(layout: layout)
        let lock = try transactionLock(layout)
        defer { lock.release() }

        let wasRunning = env.machine.isRunning()
        let loaded = wasRunning ? env.machine.loadedPayloadPath() : nil
        try migrateLegacyStore(
            layout: layout, loaded: wasRunning ? loaded : recordedLoadedPath(layout), progress: progress)
        let current = pointed(layout.currentLink, layout)
        let knownGood = pointed(layout.knownGoodLink, layout)
        let before = describe(running: loaded, current: current)
        guard let target = pointed(layout.stagedLink, layout) else {
            return HVFActivationResult(
                action: .noop, fromVersion: before, toVersion: before,
                detail: "no staged HVF payload (stage one with `micropod update hvf stage`)")
        }
        try verify(payloadDirectory: target.directory)
        // Running, but what it loaded is unknown: not known to run the target.
        let runsTarget = wasRunning ? loaded.map { runs($0, target, layout: layout) } ?? false : true
        if current == target, runsTarget {
            unlink(layout.stagedLink.path)
            return HVFActivationResult(
                action: .noop, fromVersion: before, toVersion: before,
                detail: "\(target.label) is already active", targetVersion: target.label)
        }

        func deferred(_ busy: (count: Int, reason: String)) -> HVFActivationResult {
            HVFActivationResult(
                action: .deferred, fromVersion: before, toVersion: before, activeContainers: busy.count,
                detail: "\(busy.reason); the machine keeps running \(before) (re-run when idle, or pass --force)",
                targetVersion: target.label)
        }
        let drainDeadline = ContinuousClock.now + drainTimeout
        if wasRunning, !force,
            let busy = await busyWorkloads(env, waitingUpTo: drainTimeout, progress: progress)
        {
            return deferred(busy)
        }

        // While the old guest still serves: what the new one reads at boot
        // then comes from the page cache, not the disk, during the switchover.
        env.warm(target.directory)
        // That read takes as long as the disk needs for the whole payload,
        // and the guest refuses no new work meanwhile: a container or reaper
        // session that started during it would be killed by the stop. So
        // the drain is checked again, within what is left of drainTimeout,
        // and only the trial link stands between its last idle answer and
        // the stop.
        if wasRunning, !force,
            let busy = await busyWorkloads(
                env, waitingUpTo: max(.zero, drainDeadline - ContinuousClock.now), progress: progress)
        {
            return deferred(busy)
        }
        progress("booting \(target.label) to verify it…")
        try atomicSymlink(destination: "versions/\(target.id)", at: layout.trialLink)
        defer { unlink(layout.trialLink.path) }
        var switchover: Int?
        var failure: String?
        do {
            if wasRunning { try await env.machine.stop() }
            let stopped = ContinuousClock.now
            try await env.machine.start()
            switchover = milliseconds(ContinuousClock.now - stopped)
            failure = await bootFailure(env, expected: target, layout: layout)
        } catch {
            failure = error.localizedDescription
        }
        // Before anything else boots: the trial is this boot's only.
        unlink(layout.trialLink.path)

        guard let failure else {
            try point(layout.currentLink, at: target, layout: layout)
            try atomicSymlink(destination: "versions/\(target.id)", at: layout.knownGoodLink)
            unlink(layout.stagedLink.path)
            unlink(layout.activationFailureRecord.path)
            var detail = "activated \(target.label): booted and passed the health probes"
            detail += switchover.map { " (switchover \($0) ms)" } ?? ""
            if !wasRunning { detail += await stopAgain(env, force: force) }
            return HVFActivationResult(
                action: .activated, fromVersion: before, toVersion: target.label, detail: detail,
                targetVersion: target.label, switchoverMilliseconds: switchover)
        }

        progress("\(target.label) failed: \(failure)")
        // It stays staged, with why it failed, so the skew between the
        // release that staged it and the payload that runs stays visible
        // (`updatePending`) and a transient failure can be retried.
        try? HVFActivationFailureRecord(
            stagedID: target.id, version: target.manifest()?.version, failure: failure, at: Date()
        ).save(layout)
        guard let fallback = knownGood ?? current else {
            _ = try? await env.machine.stop()
            return HVFActivationResult(
                action: .failed, fromVersion: before, toVersion: nil,
                detail: "\(target.label) failed (\(failure)) and there is no known-good payload to return to; "
                    + "the machine is stopped", targetVersion: target.label)
        }
        try point(layout.currentLink, at: fallback, layout: layout)
        progress("rolling back to known-good \(fallback.label)…")
        // A machine that came up on the fallback (a supervisor that started
        // before `trial` existed) needs no second restart, only the probes.
        let onFallback =
            env.machine.isRunning()
            && (env.machine.loadedPayloadPath().map { runs($0, fallback, layout: layout) } ?? false)
        let rollbackFailure =
            onFallback
            ? await bootFailure(env, expected: fallback, layout: layout)
            : await reboot(env, onto: fallback, layout: layout)
        if let rollbackFailure {
            return HVFActivationResult(
                action: .failedRollback, fromVersion: before, toVersion: nil,
                detail: "\(target.label) failed (\(failure)); the rollback to \(fallback.label) failed too "
                    + "(\(rollbackFailure))", targetVersion: target.label)
        }
        // A store from before known-good was tracked falls back to `current`;
        // having booted and passed the probes, it is known-good now.
        if knownGood == nil { try atomicSymlink(destination: "versions/\(fallback.id)", at: layout.knownGoodLink) }
        var detail =
            "\(target.label) failed (\(failure)); rolled back to known-good \(fallback.label), which passed the "
        detail += "health probes again; it stays staged (`micropod update hvf status` shows why it failed)"
        if !wasRunning { detail += await stopAgain(env, force: force) }
        return HVFActivationResult(
            action: .rolledBack, fromVersion: before, toVersion: fallback.label, detail: detail,
            targetVersion: target.label)
    }

    // MARK: Rollback

    /// Returns the machine to the known-good payload, by name: once there,
    /// repeating it (a replayed request) changes nothing.
    ///
    /// When the running machine loaded something else it is restarted onto
    /// known-good and probed again (`failedRollback` when that fails) —
    /// unless workloads run, or the drain check fails, and `force` is not
    /// set: then nothing changes and the result is `deferred`. A stopped
    /// machine only has `current` moved; its next start boots known-good.
    public static func rollback(
        layout: HVFMachineLayout,
        force: Bool = false,
        environment: HVFUpdateEnvironment? = nil,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> HVFActivationResult {
        guard FileManager.default.fileExists(atPath: layout.root.path) else {
            throw MicropodError.message("failedPrecondition: no HVF machine under \(layout.root.path)")
        }
        let env = environment ?? .live(layout: layout)
        let lock = try transactionLock(layout)
        defer { lock.release() }

        let running = env.machine.isRunning()
        let loaded = running ? env.machine.loadedPayloadPath() : nil
        try migrateLegacyStore(
            layout: layout, loaded: running ? loaded : recordedLoadedPath(layout), progress: progress)
        guard let knownGood = pointed(layout.knownGoodLink, layout) else {
            throw MicropodError.message(
                "failedPrecondition: no known-good HVF payload under \(layout.root.path) to roll back to")
        }
        try verify(payloadDirectory: knownGood.directory)
        let current = pointed(layout.currentLink, layout)
        let before = describe(running: loaded, current: current)
        let restart = running && !(loaded.map { runs($0, knownGood, layout: layout) } ?? false)
        if current == knownGood, !restart {
            return HVFActivationResult(
                action: .noop, fromVersion: before, toVersion: knownGood.label,
                detail: "already on known-good \(knownGood.label); nothing to roll back", targetVersion: knownGood.label
            )
        }
        if restart, !force, let busy = await busyWorkloads(env, waitingUpTo: .zero, progress: progress) {
            return HVFActivationResult(
                action: .deferred, fromVersion: before, toVersion: before, activeContainers: busy.count,
                detail:
                    "\(busy.reason); not restarting the machine onto \(knownGood.label) (pass --force to interrupt it)",
                targetVersion: knownGood.label)
        }
        try point(layout.currentLink, at: knownGood, layout: layout)
        guard restart else {
            return HVFActivationResult(
                action: .rolledBack, fromVersion: before, toVersion: knownGood.label,
                detail: "current -> known-good \(knownGood.label); "
                    + (running ? "the machine already runs it" : "the next start boots it"),
                targetVersion: knownGood.label)
        }
        progress("restarting the HVF machine onto known-good \(knownGood.label)…")
        let started = ContinuousClock.now
        if let failure = await reboot(env, onto: knownGood, layout: layout) {
            return HVFActivationResult(
                action: .failedRollback, fromVersion: before, toVersion: nil,
                detail: "restarting onto \(knownGood.label) failed (\(failure))", targetVersion: knownGood.label)
        }
        return HVFActivationResult(
            action: .rolledBack, fromVersion: before, toVersion: knownGood.label,
            detail: "restarted onto known-good \(knownGood.label), which passed the health probes",
            targetVersion: knownGood.label, switchoverMilliseconds: milliseconds(ContinuousClock.now - started))
    }

    // MARK: Prune

    /// Removes old payload directories, newest `keep` first kept, and never
    /// `current`, `staged`, `known-good`, `previous` or what the running
    /// machine loaded. Also clears what an interrupted stage left behind.
    @discardableResult
    public static func pruneVersions(layout: HVFMachineLayout, keep: Int = 2) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: layout.versionsDirectory.path) else { return [] }
        let lock = try transactionLock(layout)
        defer { lock.release() }

        // Before choosing what to keep: a migrated store protects its known-good.
        try migrateLegacyStore(layout: layout, loaded: recordedLoadedPath(layout))
        let entries = try fm.contentsOfDirectory(atPath: layout.versionsDirectory.path)
        // Under the lock no stage is live, so a stage directory is a leftover.
        for name in entries where name.hasPrefix(".stage-") {
            try? removeTree(layout.versionsDirectory.appendingPathComponent(name))
        }
        var protected = Set(
            [layout.currentLink, layout.stagedLink, layout.knownGoodLink, layout.previousLink]
                .compactMap { pointed($0, layout)?.canonicalPath })
        if HVFFileLock.isHeld(layout.supervisorLock) {
            guard let loaded = (try? HVFMachineState.load(from: layout.state))?.loadedPayloadPath else {
                throw MicropodError.message(
                    "failedPrecondition: the running hvf machine did not record which payload it loaded; "
                        + "stop it (`micropod machine stop`) before pruning")
            }
            protected.insert(HVFMachineLayout.canonicalPath(loaded))
        }
        let candidates =
            entries
            .filter { !$0.hasPrefix(".") }
            .map { layout.versionsDirectory.appendingPathComponent($0) }
            .map { (dir: $0, at: stagedAt($0)) }
            // Newest first; manifests record whole seconds, so names break ties.
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.dir.lastPathComponent > $1.dir.lastPathComponent }
            .map(\.dir)
        var kept = 0
        var removed: [String] = []
        for dir in candidates {
            if protected.contains(HVFMachineLayout.canonicalPath(dir.path)) || kept < max(keep, 1) {
                kept += 1
                continue
            }
            if (try? removeTree(dir)) != nil {
                removed.append(dir.lastPathComponent)
            }
        }
        return removed
    }

    private static func stagedAt(_ dir: URL) -> Date {
        HVFPayloadManifest.load(from: dir)?.installedAt
            ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    // MARK: Transaction steps

    /// `update.lock`, or a busy error. Clears a `trial` a killed activator
    /// left: under the lock no activation is live.
    static func transactionLock(_ layout: HVFMachineLayout) throws -> HVFFileLock {
        // Readers probe the lock with a brief shared flock; ride those out.
        guard let lock = try HVFFileLock.acquire(layout.updateLock, wait: .milliseconds(250)) else {
            throw MicropodError.message(
                "unavailable: another HVF payload update (stage, apply, rollback or prune) is in progress on "
                    + "\(layout.root.path); retry when it finishes")
        }
        unlink(layout.trialLink.path)
        return lock
    }

    /// Nil once nothing would be interrupted, else how many and why not.
    /// A failed check counts as busy.
    static func busyWorkloads(
        _ env: HVFUpdateEnvironment, waitingUpTo timeout: Duration, progress: @Sendable (String) -> Void
    ) async -> (count: Int, reason: String)? {
        let deadline = ContinuousClock.now + timeout
        var announced = false
        while true {
            let busy: (count: Int, reason: String)?
            do {
                let workloads = try await env.drain.activeWorkloads()
                busy = workloads.total > 0 ? (workloads.total, "\(workloads.summary) on the machine") : nil
            } catch {
                busy = (0, "could not confirm the machine is idle (\(error.localizedDescription))")
            }
            guard let busy, ContinuousClock.now < deadline else { return busy }
            if !announced {
                progress("waiting up to \(timeout) while \(busy.reason)…")
                announced = true
            }
            do {
                try await Task.sleep(for: env.drainPollInterval)
            } catch {
                return busy
            }
        }
    }

    /// Why the machine did not come up on `expected`, or nil when it did
    /// and passed the probes.
    static func bootFailure(_ env: HVFUpdateEnvironment, expected: HVFMachinePayload, layout: HVFMachineLayout) async
        -> String?
    {
        guard let loaded = env.machine.loadedPayloadPath() else { return "the machine is not running after the boot" }
        guard runs(loaded, expected, layout: layout) else {
            return "the machine booted \(loaded), not \(expected.directory.path)"
        }
        return await env.probe.failure()
    }

    /// Stop, start on what `current` names now, and check it is `expected`.
    private static func reboot(_ env: HVFUpdateEnvironment, onto expected: HVFMachinePayload, layout: HVFMachineLayout)
        async -> String?
    {
        do {
            try await env.machine.stop()
            try await env.machine.start()
        } catch {
            return error.localizedDescription
        }
        return await bootFailure(env, expected: expected, layout: layout)
    }

    /// Leaves a machine an activation booted only for its probes as it found
    /// it — unless something started using it meanwhile (a runner that saw
    /// the Docker socket answer): then it is left running, unless `force`.
    private static func stopAgain(_ env: HVFUpdateEnvironment, force: Bool) async -> String {
        if !force, let busy = await busyWorkloads(env, waitingUpTo: .zero, progress: { _ in }) {
            return "; the machine was stopped before, but is left running: \(busy.reason)"
        }
        do {
            try await env.machine.stop()
            return "; the machine was stopped and is stopped again"
        } catch {
            return "; the machine was stopped before, but stopping it again failed: \(error.localizedDescription)"
        }
    }

    /// Moves `link` (`current`) to `payload`, keeping what it named at `previous`.
    private static func point(_ link: URL, at payload: HVFMachinePayload, layout: HVFMachineLayout) throws {
        if let old = pointed(link, layout), old != payload {
            try atomicSymlink(destination: "versions/\(old.id)", at: layout.previousLink)
        }
        try atomicSymlink(destination: "versions/\(payload.id)", at: link)
    }

    /// Whether a machine that loaded `loadedPath` runs `payload`. A flat
    /// install and its imported copy are the same bytes.
    static func runs(_ loadedPath: String, _ payload: HVFMachinePayload, layout: HVFMachineLayout) -> Bool {
        let loaded = HVFMachineLayout.canonicalPath(loadedPath)
        if loaded == payload.canonicalPath { return true }
        return loaded == HVFMachineLayout.canonicalPath(layout.root.path)
            && payload.manifest()?.origin == HVFPayloadManifest.flatOrigin
    }

    private static func describe(running loadedPath: String?, current: HVFMachinePayload?) -> String {
        if let loadedPath {
            let url = URL(fileURLWithPath: loadedPath)
            return HVFPayloadManifest.load(from: url).map { "\($0.version) (\(url.lastPathComponent))" }
                ?? HVFMachinePayload.flatID
        }
        return current?.label ?? HVFMachinePayload.flatID
    }

    private static func pointed(_ link: URL, _ layout: HVFMachineLayout) -> HVFMachinePayload? {
        resolveVersion(link, in: layout).map { HVFMachinePayload(directory: $0, isVersioned: true) }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    // MARK: Helpers

    /// The directory `link` names when it is a version directly under
    /// `<root>/versions/`; nil for anything else (dangling, absent, elsewhere).
    static func resolveVersion(_ link: URL, in layout: HVFMachineLayout) -> URL? {
        guard let target = resolveLinkTarget(link), !target.lastPathComponent.hasPrefix(".") else { return nil }
        let parent = HVFMachineLayout.canonicalPath(target.deletingLastPathComponent().path)
        guard parent == HVFMachineLayout.canonicalPath(layout.versionsDirectory.path) else { return nil }
        return target
    }

    static func resolveLinkTarget(_ link: URL) -> URL? {
        guard let rel = readRelativeLink(link) else { return nil }
        let target =
            rel.hasPrefix("/")
            ? URL(fileURLWithPath: rel)
            : link.deletingLastPathComponent().appendingPathComponent(rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return target.standardizedFileURL
    }

    static func readRelativeLink(_ link: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    static func atomicSymlink(destination: String, at link: URL) throws {
        let dir = link.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(link.lastPathComponent).\(getpid()).\(UUID().uuidString)")
        defer { unlink(tmp.path) }
        guard symlink(destination, tmp.path) == 0 else {
            throw HVFFiles.posixError("symlink \(tmp.path) -> \(destination)")
        }
        guard rename(tmp.path, link.path) == 0 else {
            throw HVFFiles.posixError("rename symlink \(link.path)")
        }
    }

    /// Write bits off (`readOnly`) or the owner's back on, for every
    /// directory and regular file under `root`; symlinks are left alone.
    static func setReadOnly(_ root: URL, _ readOnly: Bool) {
        func apply(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            let mode = info.st_mode & 0o7777
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                _ = chmod(path, readOnly ? mode & ~0o222 : mode | 0o200)
            case S_IFDIR:
                // Writable before its entries change, read-only after.
                if !readOnly { _ = chmod(path, mode | 0o200) }
                for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                    apply(path + "/" + name)
                }
                if readOnly { _ = chmod(path, mode & ~0o222) }
            default:
                break  // a symlink is never followed
            }
        }
        apply(root.path)
    }

    /// Removes a tree that may be read-only.
    static func removeTree(_ url: URL) throws {
        setReadOnly(url, false)
        try FileManager.default.removeItem(at: url)
    }

    static func sanitizeVersionID(version: String, revision: String) -> String {
        let clean: (String) -> String = { raw in
            let filtered = raw.map {
                ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")) ? $0 : "-"
            }
            return String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let v = clean(version)
        let r = clean(String(revision.prefix(12)))
        if v.isEmpty { return "release-\(UUID().uuidString.prefix(8).lowercased())" }
        if r.isEmpty || r == "unknown" { return v }
        return "\(v)-\(r)"
    }

    /// Reads every regular file under a payload directory once, so the boot
    /// that follows finds it in the page cache; returns the bytes read.
    ///
    /// A staged payload is a fresh copy: an APFS clone shares its source's
    /// blocks on disk but not their cached pages, and only the files the
    /// manifest digests (the VMM, kernel, initrd, start.sh and the engine)
    /// have been read since. The rest of the tools (containerd alone is
    /// 36 MB) came off the disk while the new guest booted, which cost an
    /// activation's switchover ~50 ms. Read before the machine stops, it
    /// costs no downtime. Best effort: what cannot be read is skipped, and
    /// symbolic links are not followed.
    @discardableResult
    public static func warm(payloadDirectory dir: URL) -> Int64 {
        guard
            let files = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        else { return 0 }
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        for case let file as URL in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            while true {
                let n = read(fd, buffer, size)
                if n <= 0 { break }
                total += Int64(n)
            }
        }
        return total
    }

    static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func cloneOrCopy(_ source: URL, to destination: URL) throws {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
        if isDir.boolValue { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw HVFFiles.posixError("copy \(source.path) to \(destination.path)")
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: HVFMachineLayout.canonicalPath(url.path))
    }
}
