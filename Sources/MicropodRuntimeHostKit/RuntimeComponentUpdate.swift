import CryptoKit
import Darwin
import Foundation
import MicropodCore

/// One setup app as a component update sees it.
public struct RuntimeComponentBundle: Codable, Sendable, Equatable {
    public let version: String
    public let revision: String
    /// The sealed bundle's code directory hash.
    public let cdhash: String
    public let helperSHA256: String
    public let apiSHA256: String
    public let guestSHA256: String?
    public let daemonPlistSHA256: String
    /// SHA-256 of the daemon definition's content with sorted keys: launchd
    /// keeps running an approved definition only while this is unchanged.
    public let daemonDefinitionSHA256: String

    public init(
        version: String, revision: String, cdhash: String, helperSHA256: String, apiSHA256: String,
        guestSHA256: String?, daemonPlistSHA256: String, daemonDefinitionSHA256: String
    ) {
        self.version = version
        self.revision = revision
        self.cdhash = cdhash
        self.helperSHA256 = helperSHA256
        self.apiSHA256 = apiSHA256
        self.guestSHA256 = guestSHA256
        self.daemonPlistSHA256 = daemonPlistSHA256
        self.daemonDefinitionSHA256 = daemonDefinitionSHA256
    }
}

/// What the installed desktop app offers: its signed manifest and the setup
/// app it carries. Nothing here is trusted until it is copied and verified.
public struct RuntimeComponentOffer: Sendable {
    public let manifest: Data
    public let signature: Data
    public let bundle: URL
    public init(manifest: Data, signature: Data, bundle: URL) {
        self.manifest = manifest
        self.signature = signature
        self.bundle = bundle
    }
}

/// Every effect a component update has. Tests use real directories and real
/// atomic swaps; only code signing, the probe and process identity are faked.
public protocol RuntimeComponentEnvironment: Sendable {
    /// Root-owned: the journal and the staged, previous and rejected bundles.
    var root: URL { get }
    var installedBundle: URL { get }
    var publicKey: String { get }
    func offered() throws -> RuntimeComponentOffer
    /// Copies into a root-owned directory and makes the copy root-owned.
    func copyBundle(_ source: URL, to destination: URL) throws
    func inspect(_ bundle: URL) throws -> RuntimeComponentBundle
    /// Developer ID from Micropod's team, the setup, helper and API
    /// identifiers and a strict seal over nested code; notarization too
    /// when `notarized` (bytes root already retained skip only that check).
    func verifyCode(_ bundle: URL, notarized: Bool) throws
    /// Runs the bundle's helper with `--component-probe`.
    func probe(_ bundle: URL) throws -> RuntimeComponentProbe
    /// Exchanges two paths atomically (`renamex_np(RENAME_SWAP)`).
    func swap(_ a: URL, _ b: URL) throws
    /// The running helper's executable digest, after proving the file at its
    /// path is the image this process runs.
    func runningHelperSHA256() throws -> String
    /// The active dedicated API configuration's executable digest.
    func activeAPISHA256(identity: IsolatedRuntimeIdentity) -> String?
    /// Named points between durable steps; tests stop the update at each.
    func checkpoint(_ name: String) throws
    func now() -> Date
}

extension RuntimeComponentEnvironment {
    public func checkpoint(_ name: String) throws {}
    public func now() -> Date { Date() }
    public var publicKey: String { MicropodReleaseSigning.publicKey }
}

/// `component-update.json`. The update journals here, never in
/// `operation.json`: the helper swap takes no fence and drains nothing, and
/// every helper, including one rolled back to, must still read the runtime
/// operation journal.
public struct RuntimeComponentUpdateRecord: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// Copying and verifying the target. Nothing has changed.
        case staging
        /// About to exchange the installed bundle; it may or may not have.
        case swapping
        /// Exchanged. The target helper must start and verify itself.
        case relaunching
        /// The target helper runs and verified itself.
        case helperReady
        /// `runtimeOperation`, an ordinary coordinated restart, activates the
        /// target's worker, dedicated API and Apple build.
        case restarting
        /// About to exchange the retained previous bundle back.
        case rollingBack
        case completed
        /// The helper is the target; the runtime restart did not happen.
        case helperUpdated
        case rolledBack
        case refused
        case recoveryRequired

        public var isTerminal: Bool {
            [.completed, .helperUpdated, .rolledBack, .refused, .recoveryRequired].contains(self)
        }
    }

    public static let schemaVersion = 1
    public let schema: Int
    public let operation: UUID
    public let ownerUID: UInt32
    /// Returns to the bytes an earlier update replaced.
    public let rollback: Bool
    public var phase: Phase
    /// The installed setup app when the update began.
    public let source: RuntimeComponentBundle
    /// Known before staging for a rollback, after verification otherwise.
    public var target: RuntimeComponentBundle?
    public let manifest: RuntimeComponentManifest?
    public var targetVersion: String
    /// For a rollback: the update whose retained `previous` bytes it restores.
    public var restoring: UUID?
    /// Launches of the target helper before it verified itself.
    public var targetLaunches: Int
    public var runtimeOperation: UUID?
    public var reason: String?
    public let createdAt: Date
    public var updatedAt: Date
}

public struct RuntimeComponentUpdater: Sendable {
    /// A target helper that has not verified itself after this many launches
    /// is swapped back: launchd restarts a crashing helper every 10 s.
    public static let maximumTargetLaunches = 3
    public static let bundleName = "Micropod Runtime Setup.app"
    public let environment: any RuntimeComponentEnvironment

    public init(environment: any RuntimeComponentEnvironment) { self.environment = environment }

    public var journal: URL { environment.root.appendingPathComponent("component-update.json") }
    var components: URL { environment.root.appendingPathComponent("components") }
    func directory(_ operation: UUID) -> URL { components.appendingPathComponent(operation.uuidString) }
    func staged(_ operation: UUID) -> URL {
        directory(operation).appendingPathComponent("new/" + Self.bundleName)
    }
    /// The bytes an update replaced. Kept until a later update completes.
    func previous(_ operation: UUID) -> URL {
        directory(operation).appendingPathComponent("previous/" + Self.bundleName)
    }
    func rejected(_ operation: UUID) -> URL {
        directory(operation).appendingPathComponent("rejected/" + Self.bundleName)
    }
    var history: URL { components.appendingPathComponent("history") }

    // MARK: Journal

    public func read() throws -> RuntimeComponentUpdateRecord? {
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        let data = try RuntimeDurableFile.read(journal, maximumBytes: 65536, ownerUID: geteuid())
        let record = try JSONDecoder().decode(RuntimeComponentUpdateRecord.self, from: data)
        guard record.schema == RuntimeComponentUpdateRecord.schemaVersion else {
            throw MicropodError.message("The runtime component journal has an unknown schema")
        }
        return record
    }

    func save(_ record: inout RuntimeComponentUpdateRecord) throws {
        record.updatedAt = environment.now()
        try RuntimeDurableFile.write(record, to: journal)
        if record.phase.isTerminal {
            try? RuntimeDurableFile.write(
                record, to: history.appendingPathComponent(record.operation.uuidString + ".json"))
            prune(keeping: record)
        }
    }

    public func summary() -> RuntimeComponentUpdateSummary? {
        guard let record = try? read() else { return nil }
        return .init(
            operation: record.operation, phase: record.phase.rawValue, rollback: record.rollback,
            sourceVersion: record.source.version, targetVersion: record.targetVersion,
            runtimeOperation: record.runtimeOperation, reason: record.reason)
    }

    // MARK: Planning

    /// Records a new update, or returns the one `operation` already names.
    /// The result is `staging` when the helper itself changes,
    /// `helperReady` when only the runtime still has to follow the helper.
    /// Every refusal here happens before anything is copied.
    public func plan(
        operation: UUID, ownerUID: UInt32, installedSelection: ManagedRuntimeLocation.Selection, rollback: Bool
    ) throws -> RuntimeComponentUpdateRecord {
        if let current = try read() {
            if current.operation == operation {
                guard current.rollback == rollback else {
                    throw MicropodError.message("An operation ID cannot be reused for another action")
                }
                return current
            }
            guard current.phase.isTerminal else {
                throw MicropodError.message(
                    "Runtime component update \(current.operation.uuidString) is \(current.phase.rawValue); "
                        + "check its status instead of starting another")
            }
        }
        guard
            !FileManager.default.fileExists(atPath: history.appendingPathComponent(operation.uuidString + ".json").path)
        else {
            throw MicropodError.message(
                "This operation ID was already recorded; check current status instead of replaying it")
        }
        let installed = try environment.inspect(environment.installedBundle)
        guard try environment.runningHelperSHA256() == installed.helperSHA256 else {
            throw MicropodError.message(
                "The installed setup app is not the helper that is running; nothing was changed. Restart the "
                    + "runtime helper before updating it")
        }
        let now = environment.now()
        if rollback {
            guard let last = try read(), !last.rollback, last.target == installed,
                FileManager.default.fileExists(atPath: previous(last.operation).path)
            else {
                throw MicropodError.message(
                    "No retained runtime components can be restored; the installed ones were left unchanged")
            }
            var record = RuntimeComponentUpdateRecord(
                schema: RuntimeComponentUpdateRecord.schemaVersion, operation: operation, ownerUID: ownerUID,
                rollback: true, phase: .staging, source: installed, target: last.source, manifest: nil,
                targetVersion: last.source.version, restoring: last.operation, targetLaunches: 0,
                runtimeOperation: nil, reason: nil, createdAt: now, updatedAt: now)
            try save(&record)
            return record
        }
        let offer = try environment.offered()
        let manifest = try RuntimeComponentManifest.verified(
            offer.manifest, signature: offer.signature, publicKey: environment.publicKey)
        guard manifest.manages(installedSelection) else {
            throw MicropodError.message(
                "Micropod \(manifest.version)'s helper cannot manage the installed Apple runtime "
                    + "\(installedSelection.version); nothing was changed")
        }
        var record = RuntimeComponentUpdateRecord(
            schema: RuntimeComponentUpdateRecord.schemaVersion, operation: operation, ownerUID: ownerUID,
            rollback: false, phase: .staging, source: installed, target: nil, manifest: manifest,
            targetVersion: manifest.version, restoring: nil, targetLaunches: 0, runtimeOperation: nil,
            reason: nil, createdAt: now, updatedAt: now)
        if manifest.helper.sha256 == installed.helperSHA256, manifest.setup.cdhash == installed.cdhash {
            // The helper already is this release: only the runtime follows.
            record.target = installed
            record.phase = .helperReady
            try save(&record)
            return record
        }
        if let current = ReleaseVersion(installed.version), manifest.releaseVersion <= current {
            throw MicropodError.message(
                "The installed desktop app carries runtime components \(manifest.version), not newer than "
                    + "\(installed.version); nothing was changed (`micropod runtime update --rollback` restores "
                    + "the previous ones)")
        }
        if let current = ReleaseVersion(installed.version), let floor = ReleaseVersion(manifest.minimumHelperVersion),
            current < floor
        {
            throw MicropodError.message(
                "Runtime components \(manifest.version) need an installed helper of at least "
                    + "\(manifest.minimumHelperVersion); this one is \(installed.version)")
        }
        try save(&record)
        return record
    }

    // MARK: Swap (the installed helper)

    /// Copies, verifies, probes and swaps in the target. Returns the record
    /// once the swap happened (`relaunching`, or `swapping` when a step after
    /// it failed: the next launch settles that by inspection); the caller then
    /// lets launchd relaunch the helper. Before the swap every failure ends
    /// the update `refused`, with nothing changed, and is rethrown.
    public func stageAndSwap(
        _ start: RuntimeComponentUpdateRecord, installedSelection: ManagedRuntimeLocation.Selection
    )
        throws -> RuntimeComponentUpdateRecord
    {
        var record = start
        guard record.phase == .staging else { return record }
        let staged = staged(record.operation)
        do {
            try environment.checkpoint("staging")
            try createDirectories(record.operation)
            if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
            if !record.rollback {
                guard let manifest = record.manifest else {
                    throw MicropodError.message("The runtime component manifest is missing")
                }
                try environment.copyBundle(try environment.offered().bundle, to: staged)
                try environment.verifyCode(staged, notarized: true)
                let target = try environment.inspect(staged)
                guard target.cdhash == manifest.setup.cdhash, target.helperSHA256 == manifest.helper.sha256,
                    target.apiSHA256 == manifest.api.sha256, target.guestSHA256 == manifest.guestSHA256,
                    target.daemonPlistSHA256 == manifest.setup.daemonPlistSHA256,
                    target.version == manifest.version, target.revision == manifest.sourceRevision
                else {
                    throw MicropodError.message(
                        "The setup app inside the installed desktop app does not match its signed manifest")
                }
                record.target = target
            } else {
                // Root retained these bytes when it replaced them. They are
                // copied, so the retained original survives an interruption.
                guard let restoring = record.restoring else {
                    throw MicropodError.message("The retained runtime components are unknown")
                }
                try environment.copyBundle(previous(restoring), to: staged)
                try environment.verifyCode(staged, notarized: false)
                guard try environment.inspect(staged) == record.target else {
                    throw MicropodError.message("The retained runtime components changed")
                }
            }
            guard let target = record.target else { throw MicropodError.message("The target is unknown") }
            guard target.daemonDefinitionSHA256 == record.source.daemonDefinitionSHA256 else {
                throw MicropodError.message(
                    "Micropod \(target.version) changes the runtime helper's launchd definition, which needs "
                        + "administrator approval again: open Micropod Runtime Setup to install it")
            }
            let probe = try environment.probe(staged)
            guard probe.componentProtocol >= 1, probe.version == target.version,
                probe.runtimeSchema == IsolatedRuntimePolicy.schema,
                probe.appleRuntimes.contains(
                    .init(version: installedSelection.version, packageSHA256: installedSelection.packageSHA256))
            else {
                throw MicropodError.message(
                    "The staged runtime helper \(target.version) cannot manage this runtime; nothing was changed")
            }
            try requireSameVolume(staged, environment.installedBundle)
            record.phase = .swapping
            try save(&record)
            try environment.checkpoint("swapping")
        } catch let interruption as RuntimeComponentInterruption {
            throw interruption
        } catch {
            record.phase = .refused
            record.reason = Self.describe(error) + " Nothing was changed."
            try? save(&record)
            try? FileManager.default.removeItem(at: directory(record.operation).appendingPathComponent("new"))
            throw error
        }
        do {
            try environment.swap(staged, environment.installedBundle)
        } catch {
            // renamex_np changes both names or neither.
            record.phase = .refused
            record.reason = "The setup app could not be exchanged: \(Self.describe(error)). Nothing was changed."
            try? save(&record)
            throw error
        }
        try environment.checkpoint("swapped")
        // The commit point has passed: from here the next launch decides.
        try? retainDisplaced(record)
        record.phase = .relaunching
        try? save(&record)
        try environment.checkpoint("relaunching")
        return record
    }

    // MARK: Launch

    public enum Launch: Equatable, Sendable {
        case proceed
        /// Exit so launchd starts the bundle that is installed now.
        case relaunch
    }

    /// Runs before the controller exists: settles whatever the previous
    /// helper left, by inspecting which bytes are installed and which are
    /// running, never by remembered progress. The helper swap took no fence
    /// and drained nothing, so every outcome here settles locally.
    public func launch() -> Launch {
        guard var record = try? read(), !record.phase.isTerminal else { return .proceed }
        do {
            let running = try environment.runningHelperSHA256()
            let installed = try environment.inspect(environment.installedBundle)
            switch record.phase {
            case .staging:
                try settle(&record, .refused, "The update was interrupted before the swap. Nothing was changed.")
                return .proceed
            case .swapping, .relaunching:
                guard let target = record.target else {
                    try settle(&record, .refused, "The update was interrupted before the swap. Nothing was changed.")
                    return .proceed
                }
                if running == target.helperSHA256 {
                    guard installed.cdhash == target.cdhash else {
                        try settle(
                            &record, .recoveryRequired,
                            "The running helper is \(target.version) but the installed setup app is not")
                        return .proceed
                    }
                    try retainDisplaced(record)
                    if record.targetLaunches >= Self.maximumTargetLaunches {
                        return try rollBack(
                            &record,
                            "Runtime helper \(target.version) did not start serving after "
                                + "\(Self.maximumTargetLaunches) launches")
                    }
                    // Counted before anything that could crash: a helper
                    // that never reaches confirmTarget() is swapped back.
                    record.phase = .relaunching
                    record.targetLaunches += 1
                    try save(&record)
                    return .proceed
                }
                if running == record.source.helperSHA256 {
                    if installed.cdhash == target.cdhash { return .relaunch }
                    try settle(&record, .refused, "The setup app was never exchanged. Nothing was changed.")
                    try? FileManager.default.removeItem(at: staged(record.operation).deletingLastPathComponent())
                    return .proceed
                }
                try settle(&record, .recoveryRequired, "The running helper is neither the previous nor the new one")
                return .proceed
            case .rollingBack:
                if installed.cdhash == record.source.cdhash {
                    if running != record.source.helperSHA256 { return .relaunch }
                    try settle(&record, .rolledBack, record.reason ?? "The previous runtime components were restored")
                    return .proceed
                }
                return try rollBack(&record, record.reason ?? "Rolling back")
            default:
                return .proceed
            }
        } catch is RuntimeComponentInterruption {
            // A test's simulated crash: nothing more is written.
            return .proceed
        } catch {
            try? settle(&record, .recoveryRequired, Self.describe(error))
            return .proceed
        }
    }

    /// Swaps the retained source bytes back in. Idempotent by inspection.
    func rollBack(_ record: inout RuntimeComponentUpdateRecord, _ reason: String) throws -> Launch {
        record.phase = .rollingBack
        record.reason = reason
        try save(&record)
        let installed = try environment.inspect(environment.installedBundle)
        if installed.cdhash != record.source.cdhash {
            let retained = previous(record.operation)
            guard FileManager.default.fileExists(atPath: retained.path) else {
                try settle(&record, .recoveryRequired, reason + "; the previous setup app is not retained")
                return .proceed
            }
            try environment.verifyCode(retained, notarized: false)
            guard try environment.inspect(retained) == record.source else {
                try settle(&record, .recoveryRequired, reason + "; the retained setup app changed")
                return .proceed
            }
            try environment.swap(retained, environment.installedBundle)
            try environment.checkpoint("rolledBackSwap")
            try FileManager.default.createDirectory(
                at: rejected(record.operation).deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? rename(retained, rejected(record.operation))
        }
        return .relaunch
    }

    /// The target helper is serving (its controller and both listeners
    /// started). Until this runs, every launch counts toward a rollback.
    public func confirmTarget() throws {
        guard var record = try read(), record.phase == .relaunching, let target = record.target,
            try environment.runningHelperSHA256() == target.helperSHA256
        else { return }
        record.phase = .helperReady
        record.reason = nil
        try save(&record)
    }

    // MARK: Runtime follow-up (the target helper)

    /// Records the coordinated restart that activates the target's runtime.
    public func beginRuntime(_ record: inout RuntimeComponentUpdateRecord, operation: UUID) throws {
        record.phase = .restarting
        record.runtimeOperation = operation
        record.reason = nil
        try save(&record)
    }

    /// The runtime already runs the target's worker and API.
    public func finishWithoutRestart(_ record: inout RuntimeComponentUpdateRecord) throws {
        try settle(
            &record, record.rollback ? .rolledBack : .completed,
            "Runtime components \(record.targetVersion) are installed and running")
    }

    /// The helper is the target, but the runtime did not restart onto it.
    public func deferRuntime(_ record: inout RuntimeComponentUpdateRecord, _ reason: String) throws {
        try settle(
            &record, .helperUpdated,
            "Runtime helper \(record.targetVersion) is running; the dedicated runtime was not restarted: "
                + reason + ". `micropod runtime update` restarts it")
    }

    /// Follows the restart's terminal outcome. A restart in recovery keeps
    /// the update `restarting`: `micropod runtime recover` settles the restart
    /// exactly as any other, and the update follows it.
    public func followRuntime(_ status: IsolatedRuntimeStatus) throws {
        guard var record = try read(), record.phase == .restarting, let runtime = record.runtimeOperation else {
            return
        }
        guard status.operation == runtime else {
            if status.operation != nil, status.isTerminal {
                // Another operation replaced it: the restart never started.
                try deferRuntime(&record, "its restart \(runtime.uuidString) never started")
            }
            return
        }
        guard status.isTerminal else { return }
        switch status.phase {
        case "completed":
            try settle(
                &record, record.rollback ? .rolledBack : .completed,
                "Runtime components \(record.targetVersion) are installed and the dedicated runtime is verified")
        case "failed" where status.runtimeReleasedStopped == true:
            try settle(
                &record, .helperUpdated,
                "The dedicated runtime did not start on \(record.targetVersion) and is stopped with rig intake "
                    + "paused: `micropod runtime update --rollback` restores the previous components, "
                    + "`micropod runtime update` retries")
        case "recoveryRequired":
            record.reason =
                "The coordinated restart needs verification: `micropod runtime recover`"
                + (status.error.map { " (\($0))" } ?? "")
            try save(&record)
        default:
            try deferRuntime(&record, status.error ?? status.message)
        }
    }

    // MARK: Helpers

    func settle(
        _ record: inout RuntimeComponentUpdateRecord, _ phase: RuntimeComponentUpdateRecord.Phase, _ reason: String
    )
        throws
    {
        record.phase = phase
        record.reason = reason
        try save(&record)
    }

    /// The displaced bundle sits at the staging path after the swap; keep it
    /// as `previous`, the exact bytes a rollback restores.
    func retainDisplaced(_ record: RuntimeComponentUpdateRecord) throws {
        let displaced = staged(record.operation)
        guard FileManager.default.fileExists(atPath: displaced.path) else { return }
        guard (try? environment.inspect(displaced))?.cdhash == record.source.cdhash else { return }
        try rename(displaced, previous(record.operation))
    }

    func createDirectories(_ operation: UUID) throws {
        for sub in ["new", "previous"] {
            try FileManager.default.createDirectory(
                at: directory(operation).appendingPathComponent(sub), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    func rename(_ from: URL, _ to: URL) throws {
        try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard Darwin.rename(from.path, to.path) == 0 else {
            throw MicropodError.message("Could not move \(from.lastPathComponent) (\(errno))")
        }
        try RuntimeDurableFile.syncDirectory(to.deletingLastPathComponent())
    }

    func requireSameVolume(_ a: URL, _ b: URL) throws {
        var x = stat()
        var y = stat()
        guard lstat(a.path, &x) == 0, lstat(b.deletingLastPathComponent().path, &y) == 0, x.st_dev == y.st_dev else {
            throw MicropodError.message("The staged setup app is not on the installed one's volume")
        }
    }

    /// Keeps the current operation, the newest one that retains replaced
    /// bytes, and the history of the last 32.
    func prune(keeping record: RuntimeComponentUpdateRecord) {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: components, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let operations = entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }
        let retaining = operations.filter {
            fm.fileExists(atPath: $0.appendingPathComponent("previous/" + Self.bundleName).path)
        }
        .sorted { modified($0) > modified($1) }
        let keep = Set([directory(record.operation).lastPathComponent] + retaining.prefix(1).map(\.lastPathComponent))
        for entry in operations where !keep.contains(entry.lastPathComponent) { try? fm.removeItem(at: entry) }
        try? fm.removeItem(at: directory(record.operation).appendingPathComponent("new"))
        if let old = try? fm.contentsOfDirectory(at: history, includingPropertiesForKeys: [.contentModificationDateKey])
            .sorted(by: { modified($0) > modified($1) }).dropFirst(32)
        {
            for file in old { try? fm.removeItem(at: file) }
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Thrown by a test checkpoint to stop the update as a crash would.
public struct RuntimeComponentInterruption: Error, Equatable, Sendable {
    public let checkpoint: String
    public init(checkpoint: String) { self.checkpoint = checkpoint }
}

// MARK: - The Mac

/// The installed desktop app is the only source: no request names a path,
/// URL or bundle.
public struct NativeRuntimeComponentEnvironment: RuntimeComponentEnvironment {
    public static let desktopApp = URL(fileURLWithPath: "/Applications/Micropod.app")
    public static let daemonPlist = "Contents/Library/LaunchDaemons/" + IsolatedRuntimePolicy.serviceName + ".plist"
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public var root: URL { IsolatedRuntimePolicy.root }
    public var installedBundle: URL { RuntimeSetupInstallation.installedURL }

    public func offered() throws -> RuntimeComponentOffer {
        let resources = Self.desktopApp.appendingPathComponent("Contents/Resources")
        guard
            let manifest = try? Self.readBounded(
                resources.appendingPathComponent(RuntimeComponentManifest.fileName),
                limit: RuntimeComponentManifest.maximumBytes),
            let signature = try? Self.readBounded(
                resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName), limit: 1024)
        else {
            throw MicropodError.message(
                "The installed Micropod app carries no signed runtime component manifest; update the app first")
        }
        return .init(
            manifest: manifest, signature: signature,
            bundle: Self.desktopApp.appendingPathComponent("Contents/Helpers/" + RuntimeComponentUpdater.bundleName))
    }

    public func copyBundle(_ source: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw MicropodError.message("The offered setup app is not a directory")
        }
        try Self.run("/usr/bin/ditto", ["--noqtn", source.path, destination.path], timeout: 120)
        try Self.run("/usr/sbin/chown", ["-R", "0:0", destination.path], timeout: 30)
        try Self.run("/bin/chmod", ["-R", "go-w", destination.path], timeout: 30)
    }

    public func inspect(_ bundle: URL) throws -> RuntimeComponentBundle {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Self.readBounded(plist, limit: 65536),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == IsolatedRuntimePolicy.setupIdentifier,
            let version = info["CFBundleShortVersionString"] as? String
        else { throw MicropodError.message("\(bundle.path) is not Micropod Runtime Setup") }
        let daemon = bundle.appendingPathComponent(Self.daemonPlist)
        let daemonBytes = try Self.readBounded(daemon, limit: 65536)
        guard
            let definition = try PropertyListSerialization.propertyList(from: daemonBytes, format: nil)
                as? [String: Any]
        else { throw MicropodError.message("The runtime helper's launchd definition is unreadable") }
        let canonical = try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
        let guest = bundle.appendingPathComponent("Contents/Resources/micropod-guest")
        return .init(
            version: version, revision: info["MicropodSourceRevision"] as? String ?? "",
            cdhash: try Self.cdhash(bundle),
            helperSHA256: try ManagedRuntimeInstaller.sha256(
                bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")),
            apiSHA256: try ManagedRuntimeInstaller.sha256(bundle.appendingPathComponent("Contents/MacOS/MicropodAPI")),
            guestSHA256: FileManager.default.fileExists(atPath: guest.path)
                ? try ManagedRuntimeInstaller.sha256(guest) : nil,
            daemonPlistSHA256: Self.sha256(daemonBytes), daemonDefinitionSHA256: Self.sha256(canonical))
    }

    public func verifyCode(_ bundle: URL, notarized: Bool) throws {
        try RuntimeCodeIdentity.verifyBundle(
            bundle, identifier: IsolatedRuntimePolicy.setupIdentifier, notarized: notarized)
        try RuntimeCodeIdentity.verifyExecutable(
            bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"),
            identifier: IsolatedRuntimePolicy.helperIdentifier)
        try RuntimeCodeIdentity.verifyExecutable(
            bundle.appendingPathComponent("Contents/MacOS/MicropodAPI"),
            identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier)
    }

    public func probe(_ bundle: URL) throws -> RuntimeComponentProbe {
        let output = try Self.run(
            bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost").path, ["--component-probe"],
            timeout: 20)
        return try JSONDecoder().decode(RuntimeComponentProbe.self, from: output)
    }

    public func swap(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw MicropodError.message("renamex_np failed (\(errno))")
        }
        try RuntimeDurableFile.syncDirectory(a.deletingLastPathComponent())
        try RuntimeDurableFile.syncDirectory(b.deletingLastPathComponent())
    }

    public func runningHelperSHA256() throws -> String {
        guard
            RuntimeCodeIdentity.processMatchesExecutable(
                getpid(), url: executable, identifier: IsolatedRuntimePolicy.helperIdentifier)
        else { throw MicropodError.message("The running helper is not the executable at its path") }
        return try ManagedRuntimeInstaller.sha256(executable)
    }

    public func activeAPISHA256(identity: IsolatedRuntimeIdentity) -> String? {
        (try? IsolatedRuntimeAPIConfiguration.read(identity: identity))?.executableSHA256
    }

    /// A bounded read through a no-follow descriptor. The bytes are trusted
    /// only after their signature or a root-owned copy verifies.
    static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MicropodError.message("\(url.lastPathComponent) is unavailable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw MicropodError.message("\(url.lastPathComponent) is not a bounded regular file")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MicropodError.message("\(url.lastPathComponent) is oversized") }
        return data
    }

    static func cdhash(_ bundle: URL) throws -> String {
        guard let hash = RuntimeCodeIdentity.cdhash(bundle) else {
            throw MicropodError.message("\(bundle.lastPathComponent) has no code directory hash")
        }
        return hash
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a fixed tool with fixed arguments; output is read while it runs.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        final class Box: @unchecked Sendable { var data = Data() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let box = Box()
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        DispatchQueue.global().async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let name = URL(fileURLWithPath: tool).lastPathComponent
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw MicropodError.message("\(name) did not finish in time")
        }
        _ = drained.wait(timeout: .now() + 5)
        guard process.terminationStatus == 0 else {
            throw MicropodError.message("\(name) failed (\(process.terminationStatus))")
        }
        guard box.data.count <= 1 << 20 else { throw MicropodError.message("\(name) printed too much") }
        return box.data
    }
}
