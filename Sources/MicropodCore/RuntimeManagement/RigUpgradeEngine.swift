import Darwin
import Foundation

// MARK: - What the engine drives

/// The user's launchd domain.
public protocol RigLaunchControlling: Sendable {
    func isLoaded(_ label: String) async -> Bool
    /// The program a loaded job runs as launchd loaded it; nil when not loaded.
    func loadedProgram(_ label: String) async -> String?
    /// Unloads a job; a job that is not loaded is already out.
    func bootout(_ label: String) async throws
    /// Loads the job as `plist` defines it now. A job already loaded with
    /// another program (an older definition launchd reloaded at login) is
    /// booted out first.
    func bootstrap(_ plist: URL, label: String) async throws
    /// Starts a loaded job that is not running.
    func kickstart(_ label: String) async throws
}

/// The desktop app process.
public protocol RigAppControlling: Sendable {
    func isRunning(_ app: URL) async -> Bool
    /// Ends the app and the agents it spawned from its bundle, without
    /// running the app's quit path (Sparkle installs a staged update on quit).
    func stop(_ app: URL, timeout: Duration) async throws
    /// Launches the app when it is not running.
    func launch(_ app: URL) async throws
}

public struct RigHealthExpectation: Sendable, Equatable {
    public let operation: UUID
    public let version: String
    public let revision: String
    public let appRunning: Bool
    public let appControlSocket: String
    public let sockets: [String]
    public let connectPort: UInt16
    /// A Connect API answered before the upgrade, so one must answer after.
    public let connectRequired: Bool
    /// That API is replaced, so it must report `version`.
    public let connectVersionGated: Bool
    /// Components (`docker-shim`, `shared-fs`) whose records were replaced.
    public let retainedComponents: [String]
}

public struct RigHealthReport: Sendable, Equatable {
    public var failures: [String]
    public var notes: [String]
    /// Whether the Apple runtime answered as running.
    public var runtimeAvailable: Bool
    public var healthy: Bool { failures.isEmpty }
    public init(failures: [String] = [], notes: [String] = [], runtimeAvailable: Bool = false) {
        self.failures = failures
        self.notes = notes
        self.runtimeAvailable = runtimeAvailable
    }
}

public protocol RigHealthProbing: Sendable {
    func check(_ expectation: RigHealthExpectation) async -> RigHealthReport
    /// Runs one `run --rm`-style container to completion and removes it.
    func smoke(_ expectation: RigHealthExpectation, image: String) async throws
    func connectAnswers(port: UInt16) async -> Bool
}

public protocol RigBundleVerifying: Sendable {
    /// The app bundle carries Micropod's sealed Developer ID signature.
    func verifyApp(_ bundle: URL) throws
    func verifyExecutable(_ url: URL, identifier: String) throws
}

/// Thrown by a test checkpoint to stop an engine as a crash would: no
/// rollback runs and the journal stays where the crash left it.
public struct RigUpgradeInterruption: Error, Equatable, Sendable {
    public let checkpoint: String
    public init(checkpoint: String) { self.checkpoint = checkpoint }
}

public struct RigUpgradeEnvironment: Sendable {
    public var launch: any RigLaunchControlling
    public var app: any RigAppControlling
    public var drain: any RigDrainCoordinating
    public var health: any RigHealthProbing
    public var verifier: any RigBundleVerifying
    /// Exchanges two paths atomically (`renamex_np(RENAME_SWAP)`).
    public var swap: @Sendable (URL, URL) throws -> Void
    public var dedicatedRuntime: @Sendable () -> Bool
    /// Runtime maintenance holds a runtime admission gate now.
    public var runtimeMaintenance: @Sendable () -> Bool
    /// Maintenance sockets of Cuttlefish agents run by other accounts, which
    /// this upgrade does not ask to drain.
    public var otherCoordinators: @Sendable () -> [String]
    /// A Sparkle installer for this app is running.
    public var desktopInstallerRunning: @Sendable () -> Bool
    /// Throws unless this process may replace apps signed by Micropod's team
    /// (App Management lets a same-team signed process update its apps).
    public var verifySwapper: @Sendable () throws -> Void
    /// Executable paths of running processes; GC never removes one's directory.
    public var runningExecutables: @Sendable () -> [String]
    /// The executable listening on a TCP port, if one is known.
    public var portOwner: @Sendable (UInt16) -> String?
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void
    /// How often the drain is repeated while the rig is held.
    public var heartbeatInterval: Duration
    /// Named points between durable steps. Tests stop the engine at each.
    public var checkpoint: @Sendable (String) throws -> Void
    public var log: @Sendable (String) -> Void

    public init(
        launch: any RigLaunchControlling, app: any RigAppControlling, drain: any RigDrainCoordinating,
        health: any RigHealthProbing, verifier: any RigBundleVerifying,
        swap: @escaping @Sendable (URL, URL) throws -> Void = RigUpgradeEngine.swapItems,
        dedicatedRuntime: @escaping @Sendable () -> Bool,
        runtimeMaintenance: @escaping @Sendable () -> Bool = { false },
        desktopInstallerRunning: @escaping @Sendable () -> Bool = { false },
        otherCoordinators: @escaping @Sendable () -> [String] = { [] },
        verifySwapper: @escaping @Sendable () throws -> Void = {},
        runningExecutables: @escaping @Sendable () -> [String],
        portOwner: @escaping @Sendable (UInt16) -> String?, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        heartbeatInterval: Duration = RigUpgradeEngine.heartbeatInterval,
        checkpoint: @escaping @Sendable (String) throws -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.launch = launch
        self.app = app
        self.drain = drain
        self.health = health
        self.verifier = verifier
        self.swap = swap
        self.dedicatedRuntime = dedicatedRuntime
        self.runtimeMaintenance = runtimeMaintenance
        self.desktopInstallerRunning = desktopInstallerRunning
        self.otherCoordinators = otherCoordinators
        self.verifySwapper = verifySwapper
        self.runningExecutables = runningExecutables
        self.portOwner = portOwner
        self.now = now
        self.sleep = sleep
        self.heartbeatInterval = heartbeatInterval
        self.checkpoint = checkpoint
        self.log = log
    }
}

// MARK: - Engine

/// A disruptive upgrade of the desktop app and the user-level services it
/// leaves running (docker-shim, shared-fs, the Connect API). Jobs may be
/// interrupted.
///
/// Every step is preceded by a journal write and is idempotent by inspection
/// (bundle identity, file digests, launchd definitions), so any engine run
/// resumes an interrupted one: forward phases complete, a failure rolls back
/// to the exact previous bytes. A rollback restores what it can and always
/// restarts the services and the app before it reports anything it could
/// not restore. The root runtime helper, the dedicated API and the Apple
/// runtime are not touched.
public struct RigUpgradeEngine: Sendable {
    /// Engine runs allowed in one phase before it is abandoned.
    public static let maximumAttempts = 5
    /// How long an unreachable coordinator is retried.
    public static let unavailableGrace: TimeInterval = 10
    /// Heartbeat while the rig is held: Cuttlefish lets go after two minutes.
    public static let heartbeatInterval: Duration = .seconds(20)
    public static let dedicatedNote =
        "The dedicated runtime (setup helper, dedicated API and Apple engine) is not replaced by this upgrade; "
        + "it follows in its own coordinated runtime component update once the app is verified."

    public let layout: RigUpgradeLayout
    public let environment: RigUpgradeEnvironment
    var store: RigUpgradeStore { .init(layout: layout) }
    var ledger: RigDrainLedger { .init(layout: layout) }

    public init(layout: RigUpgradeLayout, environment: RigUpgradeEnvironment) {
        self.layout = layout
        self.environment = environment
    }

    // MARK: Prepare

    /// Verifies the staged release and the host, and records everything a
    /// resume or rollback needs. Nothing the host runs is changed.
    /// `services` are the target release's service definitions, when it
    /// reports them (`rig-helper --probe`).
    @discardableResult
    public func prepare(
        _ staged: RigStagedRelease, options: RigUpgradeOptions, operation: UUID = UUID(),
        services definitions: [String: RetainedServiceDefinition]? = nil
    ) async throws -> RigUpgradeJournal {
        let lock = try store.lock()
        defer { lock.release() }
        if let existing = try store.read(), !existing.phase.isTerminal {
            throw MicropodError.message(
                "Rig upgrade \(existing.operation.uuidString) is \(existing.phase.rawValue); "
                    + "`micropod update apply --disruptive` resumes it and `--abandon` drops one that has not "
                    + "stopped anything")
        }
        _ = await releaseOutstandingDrains(keeping: nil)
        try refuseConcurrentUpdates()
        let fm = FileManager.default
        let app = layout.appPath
        guard fm.fileExists(atPath: app.path) else {
            throw MicropodError.message("No Micropod app is installed at \(app.path)")
        }
        let source = try RigBundleIdentity.read(app)
        let target = staged.identity
        guard source.key != target.key else {
            throw MicropodError.message(
                "Micropod \(target.version) (\(target.revision.prefix(12))) is already installed")
        }
        let stagedBundle = staged.bundle(in: layout)
        guard target.matches(stagedBundle) else {
            throw MicropodError.message(
                "The staged \(target.version) release changed after it was verified; stage it again")
        }
        try environment.verifier.verifyApp(stagedBundle)
        // Only Micropod's own signed app is replaced, by a process App
        // Management lets update it, with rights over both bundles.
        try environment.verifier.verifyApp(app)
        try environment.verifySwapper()
        try Self.requireAtomicSwap(stagedBundle, app)
        let payload = try ensurePayload(target, from: stagedBundle)

        let directory = layout.operationDirectory(operation)
        for sub in ["previous", "new"] {
            try fm.createDirectory(
                at: directory.appendingPathComponent(sub), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        var services: [RigServiceSnapshot] = []
        var files: [RigFileReplacement] = []
        var baseline = RigHealthBaseline()
        var retainedAPI = false
        for id in RetainedServiceLaunchAgent.ids {
            let recordURL = RetainedServiceLaunchAgent.recordURL(id, servicesRoot: layout.servicesRoot)
            guard try Self.existingRegularFile(recordURL) else { continue }
            let record = try RetainedServiceLaunchAgent.readRecord(recordURL)
            guard record.schema == 1, record.identifier == RetainedServiceLaunchAgent.identifier(id) else {
                throw MicropodError.message("The retained \(id) record is not one this upgrade can replace")
            }
            let binary = URL(fileURLWithPath: record.executable).lastPathComponent
            let executable = payload.appendingPathComponent("Contents/MacOS/" + binary)
            try environment.verifier.verifyExecutable(executable, identifier: record.identifier)
            let moved = record.moved(
                to: payload, sourceVersion: target.build, sha256: try UpdateServiceWitness.digest(executable),
                definition: definitions?[id] ?? RetainedServiceLaunchAgent.definition(id))
            let label = RetainedServiceLaunchAgent.label(id)
            let plist = RetainedServiceLaunchAgent.plistURL(id, launchAgents: layout.launchAgents)
            files.append(
                try replacement(installed: recordURL, bytes: JSONEncoder().encode(moved), in: directory, mode: 0o600))
            files.append(
                try replacement(
                    installed: plist,
                    bytes: RetainedServiceLaunchAgent.plistData(id, record: moved, servicesRoot: layout.servicesRoot),
                    in: directory, mode: 0o644))
            services.append(
                .init(
                    id: id, kind: .retained, label: label, plist: plist.path,
                    wasLoaded: await environment.launch.isLoaded(label)))
            if id == "api-server" { retainedAPI = true } else { baseline.retainedComponents.append(id) }
        }
        var connectInstalled = false
        if try Self.existingRegularFile(layout.connectPlist),
            Self.programPath(layout.connectPlist) == layout.connectBinary.path
        {
            let api = payload.appendingPathComponent("Contents/MacOS/MicropodAPI")
            try environment.verifier.verifyExecutable(
                api, identifier: RetainedServiceLaunchAgent.identifier("api-server"))
            let bin = layout.connectBinary.deletingLastPathComponent()
            files.append(try replacement(installed: layout.connectBinary, source: api, in: directory, mode: 0o755))
            let guest = payload.appendingPathComponent("Contents/Resources/micropod-guest")
            if fm.fileExists(atPath: guest.path) {
                files.append(
                    try replacement(
                        installed: bin.appendingPathComponent("micropod-guest"), source: guest, in: directory,
                        mode: 0o755))
            }
            files.append(
                try replacement(
                    installed: layout.connectRoot.appendingPathComponent("VERSION"),
                    bytes: Data((target.version + "\n").utf8), in: directory, mode: 0o644))
            services.append(
                .init(
                    id: "connect-api", kind: .connect, label: RigUpgradeLayout.connectLabel,
                    plist: layout.connectPlist.path,
                    wasLoaded: await environment.launch.isLoaded(RigUpgradeLayout.connectLabel)))
            connectInstalled = true
        }

        baseline.sockets = [options.dockerShimSocket, options.sharedFSSocket].filter {
            ComponentProbe.observeSocket($0) == .accepting
        }
        baseline.connectAnswered = await environment.health.connectAnswers(port: options.connectPort)
        if baseline.connectAnswered, let reported = environment.portOwner(options.connectPort) {
            func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
            let owner = real(URL(fileURLWithPath: reported))
            baseline.connectReplaced =
                (connectInstalled && owner == real(layout.connectBinary))
                || (retainedAPI && owner.hasPrefix(real(layout.payloadsRoot) + "/"))
                || owner.hasPrefix(real(app) + "/")
        }
        let appWasRunning = await environment.app.isRunning(app)
        var notes: [String] = []
        if let image = options.smokeImage, baseline.connectAnswered {
            let probe = RigHealthExpectation(
                operation: operation, version: source.version, revision: source.revision, appRunning: false,
                appControlSocket: options.appControlSocket, sockets: [], connectPort: options.connectPort,
                connectRequired: true, connectVersionGated: false, retainedComponents: [])
            do {
                try await environment.health.smoke(probe, image: image)
                baseline.smokeImage = image
            } catch {
                notes.append(
                    "The smoke container did not run on \(source.version) either, so it is not required "
                        + "after the upgrade: \(Self.describe(error))")
            }
        }
        let journal = RigUpgradeJournal(
            operation: operation, createdAt: environment.now(), source: source, target: target, appPath: app.path,
            stagedBundle: stagedBundle.path,
            previousBundle: layout.releaseDirectory(source).appendingPathComponent("Micropod.app").path,
            targetPayload: payload.path, appWasRunning: appWasRunning,
            dedicatedRuntime: environment.dedicatedRuntime(), services: services, files: files,
            baseline: baseline, options: options, notes: notes)
        try store.write(journal)
        environment.log("rig upgrade \(operation.uuidString): prepared \(source.version) → \(target.version)")
        try environment.checkpoint("prepared")
        return journal
    }

    // MARK: Run

    /// Runs the recorded upgrade from its phase to a terminal phase. Throws,
    /// leaving the journal non-terminal, only when it must be resumed.
    @discardableResult
    public func run() async throws -> RigUpgradeJournal {
        let lock = try store.lock()
        defer { lock.release() }
        guard var journal = try store.read() else { throw MicropodError.message("No rig upgrade is recorded") }
        guard !journal.phase.isTerminal else {
            _ = await releaseOutstandingDrains(keeping: nil)
            return journal
        }
        journal.attempts += 1
        if journal.attempts > Self.maximumAttempts { return try await abandonStalled(&journal) }
        try save(&journal)
        _ = await releaseOutstandingDrains(keeping: journal.drainSpec)
        if journal.phase == .rollingBack { return try await rollBack(&journal) }
        do {
            try await forward(&journal)
            return journal
        } catch let interruption as RigUpgradeInterruption {
            throw interruption
        } catch {
            let message = Self.describe(error)
            switch journal.phase {
            case .prepared, .draining:
                // Terminal first: a crash during the release must not leave a
                // draining journal a resume could take past the drain.
                journal.reason = message + " Nothing was changed."
                journal.phase = .refused
                try save(&journal)
                await releaseDrain(&journal)
                return journal
            case .completing:
                // Verified and installed: finishing is retried, never undone.
                journal.notes.append("Completion is retried: \(message)")
                try? save(&journal)
                throw error
            default:
                journal.failure = "\(journal.phase.rawValue): \(message)"
                try transition(&journal, to: .rollingBack)
                return try await rollBack(&journal)
            }
        }
    }

    /// A phase that kept crashing its engine is abandoned the way a failed
    /// step is: before any change the upgrade is refused, after one it rolls
    /// back. A rollback that kept crashing is recorded first, then services
    /// and the app are started once more.
    private func abandonStalled(_ journal: inout RigUpgradeJournal) async throws -> RigUpgradeJournal {
        let stalled = "gave up after \(Self.maximumAttempts) runs in \(journal.phase.rawValue)"
        switch journal.phase {
        case .prepared, .draining:
            journal.reason = "The upgrade " + stalled + ". Nothing was changed."
            journal.phase = .refused
            try save(&journal)
        case .completing:
            journal.notes.append("Finishing steps " + stalled + "; the verified upgrade stands.")
            journal.reason = "Micropod \(journal.target.version) replaced \(journal.source.version)."
            journal.phase = .completed
        case .rollingBack:
            journal.reason =
                "Rollback " + stalled + (journal.failure.map { " (after \($0))" } ?? "")
                + ". Services and the app were started as they are; `micropod update recover --rig` retries."
            journal.phase = .recoveryRequired
            try save(&journal)
            _ = try await startAllBestEffort(journal)
        default:
            journal.failure = journal.failure ?? stalled
            try transition(&journal, to: .rollingBack)
            return try await rollBack(&journal)
        }
        await releaseDrain(&journal)
        try save(&journal)
        return journal
    }

    /// `micropod update recover --rig`. Before anything was stopped it
    /// abandons the upgrade; a rollback that gave up runs again (restarting
    /// services whatever it cannot restore); an interrupted upgrade resumes;
    /// a finished one releases drains still outstanding.
    @discardableResult
    public func recover() async throws -> RigUpgradeJournal {
        do {
            let lock = try store.lock()
            defer { lock.release() }
            guard var journal = try store.read() else { throw MicropodError.message("No rig upgrade is recorded") }
            switch journal.phase {
            case .prepared, .draining:
                return try await abandon(&journal, reason: "Abandoned by `micropod update recover --rig`.")
            case .recoveryRequired:
                journal.phase = .rollingBack
                journal.attempts = 0
                try save(&journal)
            case .completed, .rolledBack, .refused:
                _ = await releaseOutstandingDrains(keeping: nil)
                return journal
            default:
                break
            }
        }
        return try await run()
    }

    /// `micropod update apply --abandon`: drops an upgrade that has not
    /// stopped anything yet.
    @discardableResult
    public func abandon(reason: String) async throws -> RigUpgradeJournal {
        let lock = try store.lock()
        defer { lock.release() }
        guard var journal = try store.read() else { throw MicropodError.message("No rig upgrade is recorded") }
        return try await abandon(&journal, reason: reason)
    }

    private func abandon(_ journal: inout RigUpgradeJournal, reason: String) async throws -> RigUpgradeJournal {
        guard !journal.phase.isTerminal else { return journal }
        guard [.prepared, .draining].contains(journal.phase) else {
            throw MicropodError.message(
                "Rig upgrade \(journal.operation.uuidString) is \(journal.phase.rawValue) and has stopped services; "
                    + "`micropod update recover --rig` finishes or rolls it back")
        }
        journal.reason = reason + " Nothing was changed."
        journal.phase = .refused
        try save(&journal)
        await releaseDrain(&journal)
        return journal
    }

    /// The helper is giving up on this journal (its restart budget is spent).
    /// Recorded where `micropod update recover --rig` can take it from, after
    /// starting the services and app as they are: an upgrade that stopped
    /// nothing is refused, a verified one stands, anything in between needs
    /// recovery.
    @discardableResult
    public func stopResuming(reason: String) async throws -> RigUpgradeJournal {
        let lock = try store.lock()
        defer { lock.release() }
        guard var journal = try store.read() else { throw MicropodError.message("No rig upgrade is recorded") }
        switch journal.phase {
        case .completed, .rolledBack, .refused, .recoveryRequired:
            return journal
        case .prepared, .draining:
            return try await abandon(&journal, reason: reason + ".")
        case .completing:
            journal.notes.append(reason + " while finishing; the verified upgrade stands.")
            journal.reason = "Micropod \(journal.target.version) replaced \(journal.source.version)."
            journal.phase = .completed
        default:
            journal.reason =
                reason + " in \(journal.phase.rawValue)"
                + (journal.failure.map { " (after \($0))" } ?? "")
                + ". Services and the app were started as they are; `micropod update recover --rig` retries."
            journal.phase = .recoveryRequired
            try save(&journal)
            _ = try await startAllBestEffort(journal)
        }
        try save(&journal)
        await releaseDrain(&journal)
        return journal
    }

    private func forward(_ journal: inout RigUpgradeJournal) async throws {
        let entry = journal.phase
        // Sparkle may have started installing while this engine was down.
        if [.stopping, .swapping].contains(entry), environment.desktopInstallerRunning() {
            throw MicropodError.message("Sparkle's installer started for Micropod while the upgrade was interrupted")
        }
        if journal.phase == .prepared { try transition(&journal, to: .draining) }
        if journal.phase == .draining {
            try verifyBeforeDisruption(journal)
            try await drain(&journal)
            // A Sparkle install may have started while Cuttlefish drained.
            try refuseConcurrentUpdates()
            try transition(&journal, to: .stopping)
        }
        try await whileHeld(journal) {
            // A resume after a crash, reboot or re-login finds whatever
            // launchd reloaded and whatever app was launched since: stop it
            // all again, or start it all again, before going on.
            if [.swapping, .starting].contains(entry) { try await stopAll(journal) }
            if entry == .verifying { try await startAll(journal) }
            if journal.phase == .stopping {
                try await stopAll(journal)
                try transition(&journal, to: .swapping)
            }
            if journal.phase == .swapping {
                try swapApp(journal)
                try installFiles(journal)
                try transition(&journal, to: .starting)
            }
            if journal.phase == .starting {
                try await startAll(journal)
                try transition(&journal, to: .verifying)
            }
            if journal.phase == .verifying {
                try await verify(&journal)
                try transition(&journal, to: .completing)
            }
        }
        if journal.phase == .completing {
            // Verified before a crash or reboot; whatever went down since comes back.
            if entry == .completing { try await startAll(journal) }
            try await complete(&journal)
        }
    }

    /// Runs `body` while a heartbeat repeats the drain: Cuttlefish lets go of
    /// a drain nobody has asked about for two minutes. It continues after an
    /// unreachable coordinator, so one that comes back holds the rig, and it
    /// stops before the drain is released.
    func whileHeld(_ journal: RigUpgradeJournal, _ body: () async throws -> Void) async throws {
        guard journal.drainRequested, !journal.drainReleased else { return try await body() }
        let drain = environment.drain
        let spec = journal.drainSpec
        let interval = environment.heartbeatInterval
        let ledger = ledger
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                let reply = await drain.drain(spec)
                // A coordinator that comes back now holds the rig.
                if [.draining, .drained].contains(reply.state) { try? ledger.acknowledge(spec) }
            }
        }
        defer { heartbeat.cancel() }
        try await body()
    }

    // MARK: Journal

    func transition(_ journal: inout RigUpgradeJournal, to phase: RigUpgradeJournal.Phase) throws {
        journal.phase = phase
        journal.attempts = 1
        try save(&journal)
        environment.log("rig upgrade \(journal.operation.uuidString): \(phase.rawValue)")
        try environment.checkpoint(phase.rawValue)
    }

    func save(_ journal: inout RigUpgradeJournal) throws {
        journal.updatedAt = environment.now()
        try store.write(journal)
    }

    func checkpoint(_ journal: RigUpgradeJournal, _ name: String) throws {
        try environment.checkpoint(journal.phase.rawValue + ":" + name)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
