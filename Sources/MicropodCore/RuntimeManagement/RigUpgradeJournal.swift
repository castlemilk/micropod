import Darwin
import Foundation

/// Where a disruptive rig upgrade keeps its state and finds what it replaces.
/// Everything is the desktop account's own: the root runtime helper, the
/// dedicated API and the Apple engine are never in this layout.
public struct RigUpgradeLayout: Sendable, Equatable {
    public var home: URL
    /// The installed desktop app the upgrade replaces in place.
    public var appPath: URL

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        appPath: URL = URL(fileURLWithPath: "/Applications/Micropod.app")
    ) {
        self.home = home
        self.appPath = appPath
    }

    public var micropod: URL { home.appendingPathComponent(".micropod") }
    public var root: URL { micropod.appendingPathComponent("rig-upgrade") }
    public var journalURL: URL { root.appendingPathComponent("journal.json") }
    public var lockURL: URL { root.appendingPathComponent("engine.lock") }
    public var policyURL: URL { root.appendingPathComponent("policy.json") }
    public var helperLog: URL { root.appendingPathComponent("helper.log") }
    public var operationsRoot: URL { root.appendingPathComponent("ops") }
    public func operationDirectory(_ operation: UUID) -> URL {
        operationsRoot.appendingPathComponent(operation.uuidString)
    }
    /// Verified release bundles: the one staged next and the one replaced last.
    public var releasesRoot: URL { micropod.appendingPathComponent("releases") }
    public func releaseDirectory(_ identity: RigBundleIdentity) -> URL {
        releasesRoot.appendingPathComponent(identity.key)
    }
    public var servicesRoot: URL { micropod.appendingPathComponent("services") }
    public var payloadsRoot: URL { servicesRoot.appendingPathComponent("payloads") }
    public var launchAgents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    /// The independently installed Connect API (`dev.micropod.api`).
    public var connectRoot: URL { micropod.appendingPathComponent("connect") }
    public var connectBinary: URL { connectRoot.appendingPathComponent("bin/MicropodAPI") }
    public static let connectLabel = "dev.micropod.api"
    public var connectPlist: URL { launchAgents.appendingPathComponent(Self.connectLabel + ".plist") }
    public static let helperLabel = "com.skunkworq.micropod.rig-upgrade"
    public var helperPlist: URL { launchAgents.appendingPathComponent(Self.helperLabel + ".plist") }
    /// The helper binary copied for one operation.
    public func helperExecutable(_ operation: UUID) -> URL {
        operationDirectory(operation).appendingPathComponent("micropod")
    }
    /// The Sparkle updater's durable transaction (UpdateContinuityStore).
    public var desktopUpdates: UpdateContinuityStore { .init(root: micropod.appendingPathComponent("updates")) }
}

/// What a bundle is: its release, build, source revision and the digest of
/// its main executable. Two bundles are the same build only when all agree.
public struct RigBundleIdentity: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let revision: String
    public let executable: String
    public let executableSHA256: String

    public init(version: String, build: String, revision: String, executable: String, executableSHA256: String) {
        self.version = version
        self.build = build
        self.revision = revision
        self.executable = executable
        self.executableSHA256 = executableSHA256
    }

    /// `<version>-<revision prefix>`: the release directory's name.
    public var key: String { version + "-" + String(revision.prefix(12)) }

    public static func read(_ bundle: URL) throws -> Self {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw MicropodError.message("\(bundle.path) has no readable Info.plist") }
        guard let version = info["CFBundleShortVersionString"] as? String,
            version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
            let executable = info["CFBundleExecutable"] as? String, !executable.contains("/")
        else { throw MicropodError.message("\(bundle.path) does not declare a Micropod release") }
        let revision = info["MicropodSourceRevision"] as? String ?? ""
        guard revision.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil else {
            throw MicropodError.message("\(bundle.path) does not declare its source revision")
        }
        let main = bundle.appendingPathComponent("Contents/MacOS/" + executable)
        return Self(
            version: version, build: info["CFBundleVersion"] as? String ?? version, revision: revision,
            executable: executable, executableSHA256: try UpdateServiceWitness.digest(main))
    }

    /// Whether `bundle` is this build; false when it is absent or unreadable.
    public func matches(_ bundle: URL) -> Bool { (try? Self.read(bundle)) == self }
}

/// The marker a verified, unpacked release leaves beside its bundle in
/// `~/.micropod/releases/<version>-<revision>/`.
public struct RigStagedRelease: Codable, Equatable, Sendable {
    public static let fileName = "staged.json"
    public let schema: Int
    public let identity: RigBundleIdentity
    public let artifactURL: String
    public let artifactSHA256: String
    public let stagedAt: Date

    public init(identity: RigBundleIdentity, artifactURL: String, artifactSHA256: String, stagedAt: Date = Date()) {
        schema = 1
        self.identity = identity
        self.artifactURL = artifactURL
        self.artifactSHA256 = artifactSHA256
        self.stagedAt = stagedAt
    }

    public func bundle(in layout: RigUpgradeLayout) -> URL {
        layout.releaseDirectory(identity).appendingPathComponent("Micropod.app")
    }

    public static func read(_ directory: URL) -> Self? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? RuntimeDurableFile.read(url, maximumBytes: 16384),
            let marker = try? JSONDecoder().decode(Self.self, from: data), marker.schema == 1
        else { return nil }
        return marker
    }

    /// The newest release staged under `layout`, if any.
    public static func newest(in layout: RigUpgradeLayout) -> Self? {
        let directories =
            (try? FileManager.default.contentsOfDirectory(
                at: layout.releasesRoot, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap(read).max { isOlder($0, than: $1) }
    }

    /// Release order, then staging time for the same release.
    static func isOlder(_ left: Self, than right: Self) -> Bool {
        let a = ReleaseVersion(left.identity.version)
        let b = ReleaseVersion(right.identity.version)
        if let a, let b, a != b { return a < b }
        return left.stagedAt < right.stagedAt
    }

    /// Whether this release is newer than `version`; false when either is unparsable.
    public func isNewer(than version: String) -> Bool {
        guard let mine = ReleaseVersion(identity.version), let other = ReleaseVersion(version) else { return false }
        return mine > other
    }
}

/// One file the upgrade replaces: where it is installed, its previous bytes
/// (absent when it did not exist) and the bytes it gets. Install and restore
/// compare digests first, so either can run again after a crash.
public struct RigFileReplacement: Codable, Equatable, Sendable {
    public let installed: String
    public let backup: String?
    public let backupSHA256: String?
    public let replacement: String
    public let replacementSHA256: String
    public let mode: UInt16

    public init(
        installed: String, backup: String?, backupSHA256: String?, replacement: String, replacementSHA256: String,
        mode: UInt16
    ) {
        self.installed = installed
        self.backup = backup
        self.backupSHA256 = backupSHA256
        self.replacement = replacement
        self.replacementSHA256 = replacementSHA256
        self.mode = mode
    }
}

/// A user launchd job the upgrade stops and starts.
public struct RigServiceSnapshot: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `com.skunkworq.micropod.service.<id>`, run from a retained payload.
        case retained
        /// `dev.micropod.api`, run from `~/.micropod/connect/bin`.
        case connect
    }
    public let id: String
    public let kind: Kind
    public let label: String
    public let plist: String
    /// Loaded before the upgrade; only those are started again.
    public let wasLoaded: Bool

    public init(id: String, kind: Kind, label: String, plist: String, wasLoaded: Bool) {
        self.id = id
        self.kind = kind
        self.label = label
        self.plist = plist
        self.wasLoaded = wasLoaded
    }
}

/// What the health gate must see, captured while the previous release was
/// still running so a gate never asks for more than was there before.
public struct RigHealthBaseline: Codable, Equatable, Sendable {
    /// Unix sockets that accepted connections before the upgrade.
    public var sockets: [String]
    /// Whether a Connect API answered Ping before the upgrade.
    public var connectAnswered: Bool
    /// Whether that API is one this upgrade replaces, so it must report the
    /// target release afterwards (a foreign dev server is only pinged).
    public var connectReplaced: Bool
    /// Components whose retained records this upgrade replaces.
    public var retainedComponents: [String]
    /// The smoke container ran on the previous release; it must run after.
    public var smokeImage: String?

    public init(
        sockets: [String] = [], connectAnswered: Bool = false, connectReplaced: Bool = false,
        retainedComponents: [String] = [], smokeImage: String? = nil
    ) {
        self.sockets = sockets
        self.connectAnswered = connectAnswered
        self.connectReplaced = connectReplaced
        self.retainedComponents = retainedComponents
        self.smokeImage = smokeImage
    }
}

public struct RigUpgradeOptions: Codable, Equatable, Sendable {
    /// Longest wait for Cuttlefish to drain before stopping anyway.
    public var drainTimeout: TimeInterval
    /// Longest wait for the new release to pass its health gate.
    public var healthTimeout: TimeInterval
    /// Image for the `run --rm` smoke container; nil skips it.
    public var smokeImage: String?
    public var connectPort: UInt16
    public var dockerShimSocket: String
    public var sharedFSSocket: String
    public var appControlSocket: String
    /// Go ahead when a configured rig coordinator did not drain (refused,
    /// incompatible or unreachable). Without it the upgrade is refused.
    public var forceUndrained: Bool

    public init(
        drainTimeout: TimeInterval = 120, healthTimeout: TimeInterval = 120,
        smokeImage: String? = "docker.io/library/alpine:3.23.2", connectPort: UInt16 = 45454,
        dockerShimSocket: String, sharedFSSocket: String, appControlSocket: String, forceUndrained: Bool = false
    ) {
        self.forceUndrained = forceUndrained
        self.drainTimeout = drainTimeout
        self.healthTimeout = healthTimeout
        self.smokeImage = smokeImage
        self.connectPort = connectPort
        self.dockerShimSocket = dockerShimSocket
        self.sharedFSSocket = sharedFSSocket
        self.appControlSocket = appControlSocket
    }

    public static func standard(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Self
    {
        Self(
            connectPort: UInt16(environment["MICROPOD_API_PORT"] ?? "") ?? 45454,
            dockerShimSocket: environment["MICROPOD_SHIM_SOCKET"]
                ?? home.appendingPathComponent(".micropod/docker.sock").path,
            sharedFSSocket: environment["MICROPOD_SHAREDFS_SOCKET"]
                ?? home.appendingPathComponent("micropod/share-cache/socket").path,
            appControlSocket: environment["MICROPOD_APP_CONTROL_SOCKET"]
                ?? home.appendingPathComponent(".micropod/app-control.sock").path)
    }
}

/// The durable record of one disruptive upgrade. Written before every step;
/// any process that holds the engine lock can resume it from its phase.
public struct RigUpgradeJournal: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Phase: String, Codable, Sendable, CaseIterable {
        /// Recorded and snapshotted; nothing has changed.
        case prepared
        /// Asking Cuttlefish to stop taking work; nothing has changed.
        case draining
        /// Quitting the app and booting out its user services.
        case stopping
        /// Swapping the app bundle and replacing service files.
        case swapping
        /// Bootstrapping the services and relaunching the app.
        case starting
        /// Health-gating the new release.
        case verifying
        /// Verified: keeping the previous bundle, releasing the drain, GC.
        case completing
        /// Restoring the previous release after a failure.
        case rollingBack
        case completed
        case rolledBack
        /// Refused before anything changed.
        case refused
        /// Rollback could not finish within its attempts; files are retained.
        case recoveryRequired

        public var isTerminal: Bool { [.completed, .rolledBack, .refused, .recoveryRequired].contains(self) }
        /// Phases in which services the desktop app also manages are replaced.
        public var replacesServices: Bool { [.stopping, .swapping, .starting, .rollingBack].contains(self) }
    }

    public enum DrainOutcome: String, Codable, Sendable {
        /// No Cuttlefish rig coordinator is configured on this host.
        case skipped
        case drained
        /// Cuttlefish held the rig, but work was still handing back when the
        /// bounded wait ended; the upgrade went ahead.
        case timedOut
        /// The coordinator could not be reached.
        case unavailable
        /// Cuttlefish answered and declined.
        case refused
        /// The coordinator does not speak rig-upgrade drains.
        case incompatible

        /// The rig is held (or there is none to hold).
        public var isDrained: Bool { [.skipped, .drained, .timedOut].contains(self) }
    }

    public let schema: Int
    public let operation: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var phase: Phase
    /// Engine runs in the current phase; reset when the phase changes.
    public var attempts: Int
    public let source: RigBundleIdentity
    public let target: RigBundleIdentity
    public let appPath: String
    /// The verified target bundle; after the swap it holds the previous app.
    public let stagedBundle: String
    /// Where the previous app is kept once the upgrade completes.
    public let previousBundle: String
    /// A copy of the target the retained services run from.
    public let targetPayload: String
    public let appWasRunning: Bool
    /// The dedicated runtime is in use; it is left unchanged.
    public let dedicatedRuntime: Bool
    public let services: [RigServiceSnapshot]
    public let files: [RigFileReplacement]
    public let baseline: RigHealthBaseline
    public let options: RigUpgradeOptions
    /// The drain every call names.
    public let drainSpec: RigDrainSpec
    public var drain: DrainOutcome?
    public var drainStartedAt: Date?
    public var drainRequested: Bool
    public var drainReleased: Bool
    public var failure: String?
    public var reason: String?
    public var notes: [String]

    public init(
        operation: UUID, createdAt: Date, source: RigBundleIdentity, target: RigBundleIdentity, appPath: String,
        stagedBundle: String, previousBundle: String, targetPayload: String, appWasRunning: Bool,
        dedicatedRuntime: Bool, services: [RigServiceSnapshot], files: [RigFileReplacement],
        baseline: RigHealthBaseline, options: RigUpgradeOptions, notes: [String] = []
    ) {
        schema = Self.schemaVersion
        self.operation = operation
        self.createdAt = createdAt
        updatedAt = createdAt
        phase = .prepared
        attempts = 0
        self.source = source
        self.target = target
        self.appPath = appPath
        self.stagedBundle = stagedBundle
        self.previousBundle = previousBundle
        self.targetPayload = targetPayload
        self.appWasRunning = appWasRunning
        self.dedicatedRuntime = dedicatedRuntime
        self.services = services
        self.files = files
        self.baseline = baseline
        self.options = options
        drainSpec = RigDrainSpec(operation: operation, createdAt: createdAt)
        drainRequested = false
        drainReleased = false
        self.notes = notes
    }
}

/// The engine's journal and the kernel lock only a running engine holds.
public struct RigUpgradeStore: Sendable {
    public let layout: RigUpgradeLayout
    public init(layout: RigUpgradeLayout) { self.layout = layout }

    public func read() throws -> RigUpgradeJournal? {
        guard FileManager.default.fileExists(atPath: layout.journalURL.path) else { return nil }
        let journal = try JSONDecoder().decode(
            RigUpgradeJournal.self, from: RuntimeDurableFile.read(layout.journalURL, maximumBytes: 1 << 20))
        guard journal.schema == RigUpgradeJournal.schemaVersion else {
            throw MicropodError.message("Unsupported rig upgrade journal schema \(journal.schema)")
        }
        return journal
    }

    public func write(_ journal: RigUpgradeJournal) throws {
        try RuntimeDurableFile.write(journal, to: layout.journalURL)
    }

    /// The engine lock; throws when another engine holds it.
    public func lock() throws -> RigUpgradeLock {
        try FileManager.default.createDirectory(
            at: layout.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(layout.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MicropodError.message("Cannot open the rig upgrade lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw MicropodError.message("Another rig upgrade engine is running")
        }
        return RigUpgradeLock(fd: fd)
    }

    /// Whether an engine holds the lock now. A crashed engine never does.
    public var engineIsRunning: Bool {
        let fd = open(layout.lockURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}

/// Held for an engine's whole run; released when it is closed or the process ends.
public final class RigUpgradeLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    init(fd: Int32) { self.fd = fd }
    public func release() {
        lock.withLock {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }
    deinit { release() }
}

/// The desktop app leaves its retained services alone while a live engine
/// replaces them, so the two never register different payloads at once.
public enum RigUpgradeFence {
    public static func isReplacingServices(layout: RigUpgradeLayout = .init()) -> Bool {
        let store = RigUpgradeStore(layout: layout)
        guard let journal = try? store.read(), journal.phase.replacesServices else { return false }
        return store.engineIsRunning
    }

    /// Whether `journal` describes an upgrade that is under way. Before any
    /// disruption (prepared, draining) it is only while an engine runs or
    /// this operation's helper is loaded in launchd: a journal whose helper
    /// never started, or a plist left behind, is stale. `helperProgram` is
    /// the program launchd has loaded for a label.
    public static func isActive(
        _ journal: RigUpgradeJournal, layout: RigUpgradeLayout,
        helperProgram: (String) -> String? = RigLaunchctl.loadedProgramNow
    ) -> Bool {
        guard !journal.phase.isTerminal else { return false }
        guard [.prepared, .draining].contains(journal.phase) else { return true }
        if RigUpgradeStore(layout: layout).engineIsRunning { return true }
        guard FileManager.default.fileExists(atPath: layout.helperPlist.path),
            let loaded = helperProgram(RigUpgradeLayout.helperLabel)
        else { return false }
        let mine = layout.helperExecutable(journal.operation).resolvingSymlinksInPath().path
        return URL(fileURLWithPath: loaded).resolvingSymlinksInPath().path == mine
    }

    /// A disruptive upgrade under way.
    public static func inFlight(
        layout: RigUpgradeLayout = .init(), helperProgram: (String) -> String? = RigLaunchctl.loadedProgramNow
    ) -> RigUpgradeJournal? {
        guard let journal = try? RigUpgradeStore(layout: layout).read(),
            isActive(journal, layout: layout, helperProgram: helperProgram)
        else { return nil }
        return journal
    }

    /// A non-terminal journal, active or stale.
    public static func unfinished(layout: RigUpgradeLayout = .init()) -> RigUpgradeJournal? {
        guard let journal = try? RigUpgradeStore(layout: layout).read(), !journal.phase.isTerminal else { return nil }
        return journal
    }
}

/// How this host takes Micropod releases. Rigs choose `disruptive`: `micropod
/// update apply` replaces everything at once and the app stops installing
/// Sparkle updates by itself. Desktops keep the default, `guarded`.
public enum RigUpgradePolicy: String, Codable, Sendable, CaseIterable {
    case guarded
    case disruptive

    public static func read(layout: RigUpgradeLayout = .init()) -> Self {
        guard let data = try? RuntimeDurableFile.read(layout.policyURL, maximumBytes: 4096),
            let value = try? JSONDecoder().decode([String: String].self, from: data)["policy"]
        else { return .guarded }
        return Self(rawValue: value) ?? .guarded
    }

    public func write(layout: RigUpgradeLayout = .init()) throws {
        try RuntimeDurableFile.write(["policy": rawValue], to: layout.policyURL)
    }
}
