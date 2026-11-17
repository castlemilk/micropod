import Darwin
import Foundation

// MARK: - What the engine drives

/// The user's launchd domain.
public protocol RigLaunchControlling: Sendable {
    func isLoaded(_ label: String) async -> Bool
    /// Unloads a job; a job that is not loaded is already out.
    func bootout(_ label: String) async throws
    /// Loads a job; a job that is already loaded is already in.
    func bootstrap(_ plist: URL, label: String) async throws
}

/// The desktop app process.
public protocol RigAppControlling: Sendable {
    func isRunning(_ app: URL) async -> Bool
    /// Ends the app and the agents it spawned from its bundle.
    func stop(_ app: URL, timeout: Duration) async throws
    /// Launches the app when it is not running.
    func launch(_ app: URL) async throws
}

public enum RigDrainError: Error, LocalizedError, Sendable {
    /// No request reached a coordinator (absent, offline or untrusted).
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

public struct RigDrainReply: Sendable, Equatable {
    public let drained: Bool
    public let reason: String?
    public init(drained: Bool, reason: String? = nil) {
        self.drained = drained
        self.reason = reason
    }
}

/// The rig controller (Cuttlefish) on the maintenance socket.
public protocol RigDrainCoordinating: Sendable {
    /// Whether this host has a rig controller to ask at all.
    func isConfigured() -> Bool
    /// Asks the rig to take no new work; repeated until it reports drained.
    func drain(_ operation: UUID) async throws -> RigDrainReply
    /// Lets the rig take work again.
    func release(_ operation: UUID) async throws
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
    /// Executable paths of running processes; GC never removes one's directory.
    public var runningExecutables: @Sendable () -> [String]
    /// The executable listening on a TCP port, if one is known.
    public var portOwner: @Sendable (UInt16) -> String?
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void
    /// Named points between durable steps. Tests stop the engine at each.
    public var checkpoint: @Sendable (String) throws -> Void
    public var log: @Sendable (String) -> Void

    public init(
        launch: any RigLaunchControlling, app: any RigAppControlling, drain: any RigDrainCoordinating,
        health: any RigHealthProbing, verifier: any RigBundleVerifying,
        swap: @escaping @Sendable (URL, URL) throws -> Void = RigUpgradeEngine.swapItems,
        dedicatedRuntime: @escaping @Sendable () -> Bool,
        runtimeMaintenance: @escaping @Sendable () -> Bool = { false },
        runningExecutables: @escaping @Sendable () -> [String],
        portOwner: @escaping @Sendable (UInt16) -> String?, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
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
        self.runningExecutables = runningExecutables
        self.portOwner = portOwner
        self.now = now
        self.sleep = sleep
        self.checkpoint = checkpoint
        self.log = log
    }
}

// MARK: - Engine

/// A disruptive upgrade of the desktop app and the user-level services it
/// leaves running (docker-shim, shared-fs, the Connect API). Jobs may be
/// interrupted; the desktop is never left fenced.
///
/// Every step is preceded by a journal write and is idempotent by inspection
/// (bundle identity, file digests, launchd state), so any engine run resumes
/// an interrupted one: forward phases complete, a failure rolls back to the
/// exact previous bytes. The root runtime helper, the dedicated API and the
/// Apple runtime are not touched.
public struct RigUpgradeEngine: Sendable {
    public static let maximumAttempts = 5
    /// How long an unreachable coordinator is retried before going ahead.
    public static let unavailableGrace: TimeInterval = 10
    public static let dedicatedNote =
        "The dedicated runtime (setup helper, dedicated API and Apple engine) is left unchanged."

    public let layout: RigUpgradeLayout
    public let environment: RigUpgradeEnvironment
    var store: RigUpgradeStore { .init(layout: layout) }

    public init(layout: RigUpgradeLayout, environment: RigUpgradeEnvironment) {
        self.layout = layout
        self.environment = environment
    }

    // MARK: Prepare

    /// Verifies the staged release and records everything a resume or
    /// rollback needs. Nothing the host runs is changed.
    @discardableResult
    public func prepare(_ staged: RigStagedRelease, options: RigUpgradeOptions, operation: UUID = UUID())
        async throws -> RigUpgradeJournal
    {
        let lock = try store.lock()
        defer { lock.release() }
        if let existing = try store.read() {
            guard existing.phase.isTerminal else {
                throw MicropodError.message(
                    "Rig upgrade \(existing.operation.uuidString) is \(existing.phase.rawValue); "
                        + "`micropod update apply --disruptive` resumes it")
            }
            var last = existing
            await releaseDrain(&last)
        }
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
            guard fm.fileExists(atPath: recordURL.path) else { continue }
            let record = try RetainedServiceLaunchAgent.readRecord(recordURL)
            guard record.schema == 1, record.identifier == RetainedServiceLaunchAgent.identifier(id) else {
                throw MicropodError.message("The retained \(id) record is not one this upgrade can replace")
            }
            let binary = URL(fileURLWithPath: record.executable).lastPathComponent
            let executable = payload.appendingPathComponent("Contents/MacOS/" + binary)
            try environment.verifier.verifyExecutable(executable, identifier: record.identifier)
            let moved = record.moved(
                to: payload, sourceVersion: target.build, sha256: try UpdateServiceWitness.digest(executable))
            let label = RetainedServiceLaunchAgent.label(id)
            let plist = RetainedServiceLaunchAgent.plistURL(id, launchAgents: layout.launchAgents)
            files.append(
                try replacement(
                    installed: recordURL, bytes: JSONEncoder().encode(moved), in: directory, mode: 0o600))
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
        if fm.fileExists(atPath: layout.connectPlist.path),
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
        guard !journal.phase.isTerminal else { return journal }
        journal.attempts += 1
        if journal.attempts > Self.maximumAttempts {
            // A phase that keeps crashing its engine is abandoned the way a
            // failed step is: before any change it is refused, after one it
            // rolls back; only a rollback that keeps crashing stops here.
            let stalled = "gave up after \(Self.maximumAttempts) attempts in \(journal.phase.rawValue)"
            switch journal.phase {
            case .prepared, .draining:
                journal.reason = "The upgrade " + stalled + ". Nothing was changed."
                journal.phase = .refused
            case .completing:
                journal.notes.append("Finishing steps " + stalled + "; the verified upgrade stands.")
                journal.reason = "Micropod \(journal.target.version) replaced \(journal.source.version)."
                journal.phase = .completed
            case .rollingBack:
                journal.reason =
                    "Rollback " + stalled + (journal.failure.map { " (after \($0))" } ?? "")
                    + ". Nothing more is changed; `micropod update recover --rig` retries it."
                journal.phase = .recoveryRequired
            default:
                journal.failure = journal.failure ?? stalled
                journal.attempts = 1
                journal.phase = .rollingBack
                try save(&journal)
                return try await rollBack(&journal)
            }
            await releaseDrain(&journal)
            try save(&journal)
            return journal
        }
        try save(&journal)
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
                journal.reason = message + " Nothing was changed."
                journal.phase = .refused
                await releaseDrain(&journal)
                try save(&journal)
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

    /// `micropod update recover --rig`: retries a rollback that gave up, or
    /// releases a drain a finished upgrade could not release.
    @discardableResult
    public func recover() async throws -> RigUpgradeJournal {
        do {
            let lock = try store.lock()
            defer { lock.release() }
            guard var journal = try store.read() else { throw MicropodError.message("No rig upgrade is recorded") }
            if journal.phase == .recoveryRequired {
                journal.phase = .rollingBack
                journal.attempts = 0
                try save(&journal)
            } else if journal.phase.isTerminal {
                await releaseDrain(&journal)
                return journal
            }
        }
        return try await run()
    }

    private func forward(_ journal: inout RigUpgradeJournal) async throws {
        if journal.phase == .prepared { try transition(&journal, to: .draining) }
        if journal.phase == .draining {
            try verifyBeforeDisruption(journal)
            try await drain(&journal)
            // A Sparkle install may have started while Cuttlefish drained.
            try refuseConcurrentUpdates()
            try transition(&journal, to: .stopping)
        }
        try await whileHeld(journal) {
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
        if journal.phase == .completing { try await complete(&journal) }
    }

    /// Runs `body` while a heartbeat keeps the drain held: Cuttlefish lets go
    /// of a drain nobody has asked about for two minutes. It stops before the
    /// drain is released.
    private func whileHeld(_ journal: RigUpgradeJournal, _ body: () async throws -> Void) async throws {
        guard journal.drainRequested, !journal.drainReleased, journal.drain != .unavailable else {
            return try await body()
        }
        let drain = environment.drain
        let operation = journal.operation
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                _ = try? await drain.drain(operation)
            }
        }
        defer { heartbeat.cancel() }
        try await body()
    }

    // MARK: Steps

    private func verifyBeforeDisruption(_ journal: RigUpgradeJournal) throws {
        let app = URL(fileURLWithPath: journal.appPath)
        let staged = URL(fileURLWithPath: journal.stagedBundle)
        guard journal.source.matches(app) else {
            throw MicropodError.message("The installed app changed after the upgrade was prepared")
        }
        guard journal.target.matches(staged) else {
            throw MicropodError.message(
                "The staged \(journal.target.version) release changed after it was verified; it was not installed")
        }
        try environment.verifier.verifyApp(staged)
        guard journal.target.matches(URL(fileURLWithPath: journal.targetPayload)) else {
            throw MicropodError.message("The \(journal.target.version) service payload changed after it was verified")
        }
        for file in journal.files where Self.digest(file.replacement) != file.replacementSHA256 {
            throw MicropodError.message("The replacement for \(file.installed) changed after it was verified")
        }
        try refuseConcurrentUpdates()
    }

    private func drain(_ journal: inout RigUpgradeJournal) async throws {
        guard journal.drain == nil else { return }
        guard environment.drain.isConfigured() else {
            journal.drain = .skipped
            journal.notes.append("No Cuttlefish rig coordinator is configured on this host; nothing was drained.")
            try save(&journal)
            return
        }
        if journal.drainStartedAt == nil {
            journal.drainStartedAt = environment.now()
            journal.drainRequested = true
            try save(&journal)
        }
        let started = journal.drainStartedAt ?? environment.now()
        let deadline = started.addingTimeInterval(journal.options.drainTimeout)
        var last = "no answer yet"
        var unavailableSince: Date?
        while true {
            do {
                let reply = try await environment.drain.drain(journal.operation)
                unavailableSince = nil
                if reply.drained {
                    journal.drain = .drained
                    journal.notes.append(
                        "Cuttlefish drained in \(Int(environment.now().timeIntervalSince(started))) s.")
                    try save(&journal)
                    return
                }
                last = reply.reason ?? "work is still running"
            } catch let interruption as RigUpgradeInterruption {
                throw interruption
            } catch RigDrainError.unavailable(let reason) {
                last = reason
                let since = unavailableSince ?? environment.now()
                unavailableSince = since
                if environment.now().timeIntervalSince(since) >= Self.unavailableGrace {
                    journal.drain = .unavailable
                    journal.notes.append("Cuttlefish did not answer (\(reason)); the upgrade went ahead.")
                    try save(&journal)
                    return
                }
            } catch {
                last = Self.describe(error)
            }
            try environment.checkpoint("draining:poll")
            if environment.now() >= deadline {
                journal.drain = .timedOut
                journal.notes.append(
                    "Cuttlefish had not drained after \(Int(journal.options.drainTimeout)) s (\(last)); "
                        + "work still running was interrupted.")
                try save(&journal)
                return
            }
            try await environment.sleep(.seconds(2))
        }
    }

    private func stopAll(_ journal: RigUpgradeJournal) async throws {
        try await environment.app.stop(URL(fileURLWithPath: journal.appPath), timeout: .seconds(20))
        try checkpoint(journal, "stopped-app")
        for service in journal.services {
            try await environment.launch.bootout(service.label)
            try checkpoint(journal, "bootout:" + service.id)
        }
    }

    private func swapApp(_ journal: RigUpgradeJournal) throws {
        let app = URL(fileURLWithPath: journal.appPath)
        let staged = URL(fileURLWithPath: journal.stagedBundle)
        if journal.target.matches(app) { return }
        guard journal.source.matches(app) else {
            throw MicropodError.message(
                "\(app.path) is neither \(journal.source.version) nor \(journal.target.version); it was not replaced")
        }
        guard journal.target.matches(staged) else {
            throw MicropodError.message("The staged \(journal.target.version) bundle changed; it was not installed")
        }
        try environment.verifier.verifyApp(staged)
        try environment.swap(staged, app)
        try checkpoint(journal, "swapped-app")
        guard journal.target.matches(app) else {
            throw MicropodError.message("The swap did not install \(journal.target.version)")
        }
    }

    private func restoreApp(_ journal: RigUpgradeJournal) throws {
        let app = URL(fileURLWithPath: journal.appPath)
        let staged = URL(fileURLWithPath: journal.stagedBundle)
        if journal.source.matches(app) { return }
        guard journal.target.matches(app), journal.source.matches(staged) else {
            throw MicropodError.message(
                "Neither \(app.path) nor \(staged.path) is the previous \(journal.source.version) app; both are kept")
        }
        try environment.swap(staged, app)
        try checkpoint(journal, "swapped-back")
        guard journal.source.matches(app) else {
            throw MicropodError.message("The swap back did not restore \(journal.source.version)")
        }
    }

    private func installFiles(_ journal: RigUpgradeJournal) throws {
        for file in journal.files {
            if Self.digest(file.installed) == file.replacementSHA256 { continue }
            guard Self.digest(file.replacement) == file.replacementSHA256 else {
                throw MicropodError.message("The replacement for \(file.installed) changed; it was not installed")
            }
            try Self.install(
                URL(fileURLWithPath: file.replacement), at: URL(fileURLWithPath: file.installed), mode: file.mode)
            try checkpoint(journal, "installed:" + URL(fileURLWithPath: file.installed).lastPathComponent)
        }
    }

    private func restoreFiles(_ journal: RigUpgradeJournal) throws {
        for file in journal.files.reversed() {
            let installed = URL(fileURLWithPath: file.installed)
            if let backup = file.backup {
                if Self.digest(file.installed) == file.backupSHA256 { continue }
                guard Self.digest(backup) == file.backupSHA256 else {
                    throw MicropodError.message("The saved copy of \(file.installed) changed; it was not restored")
                }
                try Self.install(URL(fileURLWithPath: backup), at: installed, mode: file.mode)
            } else {
                guard FileManager.default.fileExists(atPath: installed.path) else { continue }
                try RuntimeDurableFile.remove(installed)
            }
            try checkpoint(journal, "restored:" + installed.lastPathComponent)
        }
    }

    private func startAll(_ journal: RigUpgradeJournal) async throws {
        for service in journal.services where service.wasLoaded {
            try await environment.launch.bootstrap(URL(fileURLWithPath: service.plist), label: service.label)
            try checkpoint(journal, "bootstrap:" + service.id)
        }
        if journal.appWasRunning {
            try await environment.app.launch(URL(fileURLWithPath: journal.appPath))
            try checkpoint(journal, "launched-app")
        }
    }

    private func verify(_ journal: inout RigUpgradeJournal) async throws {
        let expectation = expectation(journal, for: journal.target)
        let report = try await gate(expectation, timeout: journal.options.healthTimeout)
        for note in report.notes where !journal.notes.contains(note) { journal.notes.append(note) }
        if let image = journal.baseline.smokeImage {
            guard report.runtimeAvailable else {
                throw MicropodError.message(
                    "The Apple runtime is not available on \(journal.target.version), though the smoke container "
                        + "ran before the upgrade")
            }
            try await environment.health.smoke(expectation, image: image)
            journal.notes.append("A \(image) smoke container ran and was removed on \(journal.target.version).")
        }
        try save(&journal)
    }

    private func gate(_ expectation: RigHealthExpectation, timeout: TimeInterval) async throws -> RigHealthReport {
        let deadline = environment.now().addingTimeInterval(timeout)
        while true {
            let report = await environment.health.check(expectation)
            if report.healthy { return report }
            if environment.now() >= deadline {
                throw MicropodError.message(
                    "\(expectation.version) did not pass its health gate within \(Int(timeout)) s: "
                        + report.failures.joined(separator: "; "))
            }
            try await environment.sleep(.seconds(1))
        }
    }

    private func complete(_ journal: inout RigUpgradeJournal) async throws {
        journal.notes += keepPrevious(journal)
        try checkpoint(journal, "kept-previous")
        await releaseDrain(&journal)
        try checkpoint(journal, "released-drain")
        for note in collectGarbage(journal) where !journal.notes.contains(note) { journal.notes.append(note) }
        var summary =
            "Micropod \(journal.target.version) replaced \(journal.source.version): the app with its CLI and MCP"
        let replaced = journal.services.map(\.id)
        if !replaced.isEmpty { summary += ", " + replaced.joined(separator: ", ") }
        summary += ". Drain: \(journal.drain?.rawValue ?? "skipped")."
        if journal.dedicatedRuntime { summary += " " + Self.dedicatedNote }
        journal.reason = summary
        try transition(&journal, to: .completed)
    }

    private func rollBack(_ journal: inout RigUpgradeJournal) async throws -> RigUpgradeJournal {
        do {
            var health = ""
            try await whileHeld(journal) {
                try await stopAll(journal)
                try restoreApp(journal)
                try restoreFiles(journal)
                try await startAll(journal)
                do {
                    _ = try await gate(
                        expectation(journal, for: journal.source), timeout: min(journal.options.healthTimeout, 60))
                } catch let interruption as RigUpgradeInterruption {
                    throw interruption
                } catch {
                    health =
                        " The restored \(journal.source.version) did not pass its own health gate: "
                        + Self.describe(error)
                }
            }
            await releaseDrain(&journal)
            journal.reason =
                "Rolled back to \(journal.source.version): \(journal.failure ?? "the upgrade failed")." + health
                + (journal.dedicatedRuntime ? " " + Self.dedicatedNote : "")
            try transition(&journal, to: .rolledBack)
            return journal
        } catch let interruption as RigUpgradeInterruption {
            throw interruption
        } catch {
            journal.notes.append("Rollback attempt \(journal.attempts) did not finish: \(Self.describe(error))")
            try? save(&journal)
            throw MicropodError.message("Rollback did not finish (\(Self.describe(error))); the next run resumes it")
        }
    }

    private func releaseDrain(_ journal: inout RigUpgradeJournal) async {
        guard journal.drainRequested, !journal.drainReleased else { return }
        do {
            try await environment.drain.release(journal.operation)
            journal.drainReleased = true
        } catch {
            journal.notes.append(
                "Cuttlefish's drain was not released (\(Self.describe(error))). It lets an abandoned drain go after "
                    + "two minutes, and the next upgrade releases it.")
        }
        try? save(&journal)
    }

    /// The Sparkle updater and runtime maintenance replace parts of what this
    /// upgrade stops; neither may be in flight.
    private func refuseConcurrentUpdates() throws {
        guard !environment.runtimeMaintenance() else {
            throw MicropodError.message(
                "Runtime maintenance holds the runtime's admission gate; let it finish or run "
                    + "`micropod runtime recover` first")
        }
        let receipt: UpdateContinuityReceipt?
        do {
            receipt = try layout.desktopUpdates.read()
        } catch {
            throw MicropodError.message(
                "The desktop update transaction cannot be read (\(Self.describe(error))); "
                    + "reconcile it with `micropod update recover` first")
        }
        if let receipt, !receipt.isTerminal {
            throw MicropodError.message(
                "A desktop update to \(receipt.targetVersion) is \(receipt.phase.rawValue); "
                    + "finish or reconcile it with `micropod update recover` first")
        }
    }

    // MARK: Journal

    private func expectation(_ journal: RigUpgradeJournal, for identity: RigBundleIdentity) -> RigHealthExpectation {
        RigHealthExpectation(
            operation: journal.operation, version: identity.version, revision: identity.revision,
            appRunning: journal.appWasRunning, appControlSocket: journal.options.appControlSocket,
            sockets: journal.baseline.sockets, connectPort: journal.options.connectPort,
            connectRequired: journal.baseline.connectAnswered,
            connectVersionGated: journal.baseline.connectReplaced,
            retainedComponents: journal.baseline.retainedComponents)
    }

    private func transition(_ journal: inout RigUpgradeJournal, to phase: RigUpgradeJournal.Phase) throws {
        journal.phase = phase
        try save(&journal)
        environment.log("rig upgrade \(journal.operation.uuidString): \(phase.rawValue)")
        try environment.checkpoint(phase.rawValue)
    }

    private func save(_ journal: inout RigUpgradeJournal) throws {
        journal.updatedAt = environment.now()
        try store.write(journal)
    }

    private func checkpoint(_ journal: RigUpgradeJournal, _ name: String) throws {
        try environment.checkpoint(journal.phase.rawValue + ":" + name)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
