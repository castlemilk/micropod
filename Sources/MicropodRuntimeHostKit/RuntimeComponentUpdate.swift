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
    /// SHA-256 of the daemon definition's content with sorted keys.
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
    /// The desktop app's own release, which the manifest must name.
    public let desktopVersion: String
    public let desktopRevision: String
    public init(manifest: Data, signature: Data, bundle: URL, desktopVersion: String, desktopRevision: String) {
        self.manifest = manifest
        self.signature = signature
        self.bundle = bundle
        self.desktopVersion = desktopVersion
        self.desktopRevision = desktopRevision
    }
}

/// The dedicated API a runtime is configured with.
public struct RuntimeComponentAPI: Codable, Sendable, Equatable {
    public let executableSHA256: String
    public let guestSHA256: String?
    public init(executableSHA256: String, guestSHA256: String?) {
        self.executableSHA256 = executableSHA256
        self.guestSHA256 = guestSHA256
    }
}

/// The runtime a component update replaced: what a rollback restores. Every
/// part is content-addressed under `RuntimeHost`, so these are exact bytes.
public struct RuntimeComponentRuntime: Codable, Sendable, Equatable {
    public let selection: ManagedRuntimeLocation.Selection
    public let workerSHA256: String
    public let api: RuntimeComponentAPI
    public init(selection: ManagedRuntimeLocation.Selection, workerSHA256: String, api: RuntimeComponentAPI) {
        self.selection = selection
        self.workerSHA256 = workerSHA256
        self.api = api
    }
}

/// Root-held state that outlives every record: the highest release this host
/// ran, the highest signed security floor, and the launchd definition root
/// last approved. None of it is read from the user-writable setup app.
public struct RuntimeComponentState: Codable, Sendable, Equatable {
    public var highestVersion: String?
    public var securityFloor: String?
    public var approvedDefinitionSHA256: String?
    public init(highestVersion: String? = nil, securityFloor: String? = nil, approvedDefinitionSHA256: String? = nil) {
        self.highestVersion = highestVersion
        self.securityFloor = securityFloor
        self.approvedDefinitionSHA256 = approvedDefinitionSHA256
    }
}

/// Every effect a component update has. Tests use real directories and real
/// atomic swaps; code signing, the probe and process identity are faked.
public protocol RuntimeComponentEnvironment: Sendable {
    /// Root-only: the journal, the floor and every staged, verified, retained
    /// and rejected bundle.
    var root: URL { get }
    var installedBundle: URL { get }
    var publicKey: String { get }
    /// The running helper's compiled-in release (`MicropodBuildInfo`), never
    /// a plist in a writable bundle.
    var runningVersion: String { get }
    func offered() throws -> RuntimeComponentOffer
    /// ``RuntimeSecureCopy``: a copy no unprivileged process can change.
    func secureCopy(_ source: URL, to destination: URL) throws
    /// Whether `bundle` is already root-owned and sealed in place.
    func isSealed(_ bundle: URL) -> Bool
    func inspect(_ bundle: URL) throws -> RuntimeComponentBundle
    /// Developer ID from Micropod's team, the setup, helper and API
    /// identifiers and a strict seal over nested code; notarization too
    /// when `notarized` (bytes root itself retained skip only that check).
    func verifyCode(_ bundle: URL, notarized: Bool) throws
    /// Runs the bundle's helper with `--component-probe`.
    func probe(_ bundle: URL) throws -> RuntimeComponentProbe
    /// Exchanges two paths atomically (`renamex_np(RENAME_SWAP)`).
    func swap(_ a: URL, _ b: URL) throws
    /// The running helper's executable digest, after proving the file at its
    /// path is the image this process runs.
    func runningHelperSHA256() throws -> String
    /// The active dedicated API configuration.
    func activeAPI(identity: IsolatedRuntimeIdentity) -> RuntimeComponentAPI?
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
/// `operation.json`: every helper, including one rolled back to, must still
/// read the runtime operation journal.
public struct RuntimeComponentUpdateRecord: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// A rollback's coordinated restart onto the previous runtime, run by
        /// the current helper before the helper is swapped back.
        case restoringRuntime
        /// Copying and verifying the target. Nothing has changed.
        case staging
        /// About to exchange the installed bundle; it may or may not have.
        case swapping
        /// Exchanged. The target helper must start and verify itself.
        case relaunching
        /// The target helper serves and verified itself.
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
    /// Replaces the installed bundle with a sealed root-owned copy of the
    /// same verified bytes: no relaunch, the running helper is the target.
    public var reseat: Bool
    /// Follow the helper with a coordinated restart of the runtime.
    public var restartRuntime: Bool
    public var phase: Phase
    /// The installed setup app when the update began.
    public let source: RuntimeComponentBundle
    /// Known before staging for a rollback, after verification otherwise.
    public var target: RuntimeComponentBundle?
    public let manifest: RuntimeComponentManifest?
    public var targetVersion: String
    /// For a rollback: the update whose retained `previous` bytes it restores.
    public var restoring: UUID?
    /// The runtime before this update's restart; a rollback restores it.
    public var previousRuntime: RuntimeComponentRuntime?
    /// Launches of the target helper before it verified itself.
    public var targetLaunches: Int
    public var runtimeOperation: UUID?
    public var reason: String?
    public let createdAt: Date
    public var updatedAt: Date
}

public struct RuntimeComponentUpdater: Sendable {
    /// A target helper that has not served after this many launches is
    /// swapped back: launchd restarts a crashing helper every 10 s.
    public static let maximumTargetLaunches = 3
    /// A target that has not confirmed itself by then exits so the launch
    /// counts: a hang must not stall the update.
    public static let confirmationDeadline: TimeInterval = 120
    public static let bundleName = "Micropod Runtime Setup.app"
    public let environment: any RuntimeComponentEnvironment

    public init(environment: any RuntimeComponentEnvironment) { self.environment = environment }

    public var journal: URL { environment.root.appendingPathComponent("component-update.json") }
    var stateURL: URL { environment.root.appendingPathComponent("component-state.json") }
    var components: URL { environment.root.appendingPathComponent("components") }
    func directory(_ operation: UUID) -> URL { components.appendingPathComponent(operation.uuidString) }
    func path(_ operation: UUID, _ kind: String) -> URL {
        directory(operation).appendingPathComponent(kind + "/" + Self.bundleName)
    }
    /// Sealed copy that is swapped into place.
    func staged(_ operation: UUID) -> URL { path(operation, "new") }
    /// Sealed copy of the verified target that never leaves root's
    /// directory: the worker, API and guest are installed from it.
    public func verified(_ operation: UUID) -> URL { path(operation, "verified") }
    /// The displaced bundle, moved aside unread. It may be another account's
    /// files: it is only ever secure-copied, never read or run in place.
    func previous(_ operation: UUID) -> URL { path(operation, "previous") }
    func restore(_ operation: UUID) -> URL { path(operation, "restore") }
    func rejected(_ operation: UUID) -> URL { path(operation, "rejected") }
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

    /// Lenient: an unreadable journal blocks only a component update, never
    /// a lifecycle action or its recovery.
    public func readLeniently() -> RuntimeComponentUpdateRecord? { try? read() }

    func save(_ record: inout RuntimeComponentUpdateRecord) throws {
        record.updatedAt = environment.now()
        try RuntimeDurableFile.write(record, to: journal)
        if record.phase.isTerminal {
            try? RuntimeDurableFile.write(
                record, to: history.appendingPathComponent(record.operation.uuidString + ".json"))
            prune(keeping: record)
        }
    }

    public func state() -> RuntimeComponentState {
        guard let data = try? RuntimeDurableFile.read(stateURL, maximumBytes: 4096, ownerUID: geteuid()) else {
            return .init()
        }
        return (try? JSONDecoder().decode(RuntimeComponentState.self, from: data)) ?? .init()
    }

    /// Raises the high-water marks; never lowers them.
    func raise(version: String?, floor: String?, definition: String?) throws {
        var current = state()
        func higher(_ a: String?, _ b: String?) -> String? {
            guard let b, let next = ReleaseVersion(b) else { return a }
            guard let a, let old = ReleaseVersion(a) else { return b }
            return next > old ? b : a
        }
        current.highestVersion = higher(current.highestVersion, version)
        current.securityFloor = higher(current.securityFloor, floor)
        if let definition { current.approvedDefinitionSHA256 = definition }
        try RuntimeDurableFile.write(current, to: stateURL)
    }

    public func summary() -> RuntimeComponentUpdateSummary? {
        guard let record = readLeniently() else { return nil }
        return .init(
            operation: record.operation, phase: record.phase.rawValue, rollback: record.rollback,
            sourceVersion: record.source.version, targetVersion: record.targetVersion,
            runtimeOperation: record.runtimeOperation, reason: record.reason)
    }

    // MARK: Planning

    /// Records a new update, or returns the one `operation` already names.
    /// Every refusal here happens before anything is copied.
    ///
    /// - A forward update stages the offered release. When the running helper
    ///   already is that release it re-seats it instead: the same verified
    ///   bytes, root-owned, swapped in without a relaunch.
    /// - A rollback first restores the previous runtime (`restoringRuntime`)
    ///   when the runtime moved, then stages the retained previous bundle.
    public func plan(
        operation: UUID, ownerUID: UInt32, installedSelection: ManagedRuntimeLocation.Selection,
        runtime: RuntimeComponentRuntime?, rollback: Bool, restartRuntime: Bool = true, reseatOnly: Bool = false
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
            !FileManager.default.fileExists(
                atPath: history.appendingPathComponent(operation.uuidString + ".json").path)
        else {
            throw MicropodError.message(
                "This operation ID was already recorded; check current status instead of replaying it")
        }
        guard let running = ReleaseVersion(environment.runningVersion), running.suffix.isEmpty else {
            throw MicropodError.message(
                "This runtime helper's release (\(environment.runningVersion)) is unknown, so it cannot judge a "
                    + "downgrade; nothing was changed")
        }
        let installed = try environment.inspect(environment.installedBundle)
        let runningSHA256 = try environment.runningHelperSHA256()
        guard runningSHA256 == installed.helperSHA256 else {
            throw MicropodError.message(
                "The installed setup app is not the helper that is running; nothing was changed. Restart the "
                    + "runtime helper before updating it")
        }
        let marks = state()
        let floor = marks.securityFloor.flatMap(ReleaseVersion.init)
        let now = environment.now()
        if rollback {
            guard let last = try read(), !last.rollback, !last.reseat,
                last.target?.helperSHA256 == runningSHA256,
                FileManager.default.fileExists(atPath: previous(last.operation).path)
            else {
                throw MicropodError.message(
                    "No retained runtime components can be restored; the installed ones were left unchanged")
            }
            if let floor, let target = ReleaseVersion(last.source.version), target < floor {
                throw MicropodError.message(
                    "Micropod \(last.source.version) is below the signed security floor \(floor); it cannot be "
                        + "restored")
            }
            if ReleaseVersion(last.source.version) == nil, floor != nil {
                throw MicropodError.message("The retained release's version is unknown; it cannot be restored")
            }
            let restoreRuntime = last.previousRuntime.map { $0 != runtime } ?? false
            var record = RuntimeComponentUpdateRecord(
                schema: RuntimeComponentUpdateRecord.schemaVersion, operation: operation, ownerUID: ownerUID,
                rollback: true, reseat: false, restartRuntime: false,
                phase: restoreRuntime ? .restoringRuntime : .staging, source: installed, target: last.source,
                manifest: nil, targetVersion: last.source.version, restoring: last.operation,
                previousRuntime: last.previousRuntime, targetLaunches: 0, runtimeOperation: nil, reason: nil,
                createdAt: now, updatedAt: now)
            try save(&record)
            return record
        }
        let offer = try environment.offered()
        let manifest = try RuntimeComponentManifest.verified(
            offer.manifest, signature: offer.signature, publicKey: environment.publicKey)
        // A manifest belongs to the app that carries it: an older release's
        // manifest replayed into another app is refused.
        guard manifest.version == offer.desktopVersion, manifest.sourceRevision == offer.desktopRevision else {
            throw MicropodError.message(
                "The runtime component manifest (\(manifest.version)) is not the installed app's own "
                    + "(\(offer.desktopVersion)); nothing was changed")
        }
        guard let target = manifest.releaseVersion else {
            throw MicropodError.message("The runtime component manifest's release is malformed")
        }
        guard manifest.manages(installedSelection) else {
            throw MicropodError.message(
                "Micropod \(manifest.version)'s helper cannot manage the installed Apple runtime "
                    + "\(installedSelection.version); nothing was changed")
        }
        if let floor, target < floor {
            throw MicropodError.message(
                "Micropod \(manifest.version) is below the signed security floor \(floor); nothing was changed")
        }
        var record = RuntimeComponentUpdateRecord(
            schema: RuntimeComponentUpdateRecord.schemaVersion, operation: operation, ownerUID: ownerUID,
            rollback: false, reseat: false, restartRuntime: restartRuntime, phase: .staging, source: installed,
            target: nil, manifest: manifest, targetVersion: manifest.version, restoring: nil, previousRuntime: nil,
            targetLaunches: 0, runtimeOperation: nil, reason: nil, createdAt: now, updatedAt: now)
        guard !reseatOnly || manifest.helper.sha256 == runningSHA256 else {
            throw MicropodError.message("The installed app's release is not the running helper's")
        }
        if manifest.helper.sha256 == runningSHA256 {
            // The running helper is this release. Re-seat it: whatever the
            // installed bundle is, a sealed root-owned copy of the verified
            // bytes replaces it before anything is installed from it.
            guard target == running else {
                throw MicropodError.message("The running helper does not report the manifest's release")
            }
            record.reseat = true
            try save(&record)
            return record
        }
        let highest = marks.highestVersion.flatMap(ReleaseVersion.init)
        guard target > running, highest.map({ target >= $0 }) ?? true else {
            throw MicropodError.message(
                "The installed desktop app carries runtime components \(manifest.version), not newer than "
                    + "\(running)\(highest.map { " (highest installed: \($0))" } ?? ""); nothing was changed "
                    + "(`micropod runtime update --rollback` restores the previous ones)")
        }
        guard let minimum = ReleaseVersion(manifest.minimumHelperVersion), running >= minimum else {
            throw MicropodError.message(
                "Runtime components \(manifest.version) need an installed helper of at least "
                    + "\(manifest.minimumHelperVersion); this one is \(running)")
        }
        try save(&record)
        return record
    }

    /// The runtime restored, a rollback goes on to the helper swap.
    public func runtimeRestored(_ record: inout RuntimeComponentUpdateRecord) throws {
        record.phase = .staging
        record.runtimeOperation = nil
        try save(&record)
    }

    // MARK: Swap (the installed helper)

    /// Copies, verifies, probes and swaps in the target. Returns the record
    /// once the swap happened: `relaunching`, `helperReady` for a re-seat, or
    /// `swapping` when a step after the swap failed (the next launch settles
    /// that by inspection). Before the swap every failure ends the update
    /// `refused`, with nothing changed, and is rethrown.
    public func stageAndSwap(
        _ start: RuntimeComponentUpdateRecord, installedSelection: ManagedRuntimeLocation.Selection
    ) throws -> RuntimeComponentUpdateRecord {
        var record = start
        guard record.phase == .staging else { return record }
        let staged = staged(record.operation)
        do {
            try environment.checkpoint("staging")
            for kind in ["new", "verified", "previous", "restore"] {
                try? RuntimeSecureCopy.remove(path(record.operation, kind))
            }
            if !record.rollback {
                guard let manifest = record.manifest else {
                    throw MicropodError.message("The runtime component manifest is missing")
                }
                try environment.secureCopy(try environment.offered().bundle, to: staged)
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
                // The retained bytes are the displaced bundle, possibly another
                // account's files: secure-copied, verified, never used in place.
                guard let restoring = record.restoring else {
                    throw MicropodError.message("The retained runtime components are unknown")
                }
                try environment.secureCopy(previous(restoring), to: staged)
                try environment.verifyCode(staged, notarized: false)
                guard try environment.inspect(staged) == record.target else {
                    throw MicropodError.message("The retained runtime components changed")
                }
            }
            guard let target = record.target else { throw MicropodError.message("The target is unknown") }
            // The approved definition is root's record, not the writable plist.
            let approved = state().approvedDefinitionSHA256 ?? record.source.daemonDefinitionSHA256
            guard target.daemonDefinitionSHA256 == approved else {
                throw MicropodError.message(
                    "Micropod \(target.version) changes the runtime helper's launchd definition, which needs "
                        + "administrator approval again: `micropod runtime update --bootstrap` installs it")
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
            try environment.secureCopy(staged, to: verified(record.operation))
            guard try environment.inspect(verified(record.operation)) == target else {
                throw MicropodError.message("The verified copy of the setup app changed")
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
        if record.reseat {
            try? raise(
                version: record.target?.version, floor: record.manifest?.securityFloor,
                definition: record.target?.daemonDefinitionSHA256)
            record.phase = record.restartRuntime ? .helperReady : .completed
            record.reason = record.restartRuntime ? nil : "The runtime helper was re-seated as a root-owned copy"
        } else {
            record.phase = .relaunching
        }
        try? save(&record)
        try environment.checkpoint("relaunching")
        return record
    }

    // MARK: Launch

    public enum Launch: Equatable, Sendable {
        case proceed
        /// Proceed, but exit within ``confirmationDeadline`` unless
        /// ``confirmTarget()`` succeeds, so a hang counts as a failed launch.
        case proceedUnconfirmed
        /// Exit so launchd starts the bundle that is installed now.
        case relaunch
    }

    /// Runs first at every helper start: settles whatever the previous helper
    /// left by inspecting which helper executable is installed and running,
    /// never by remembered progress. The helper swap took no fence and drained
    /// nothing, so every outcome here settles locally.
    public func launch() -> Launch {
        guard var record = readLeniently(), !record.phase.isTerminal else { return .proceed }
        do {
            let running = try environment.runningHelperSHA256()
            let installed = try environment.inspect(environment.installedBundle).helperSHA256
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
                    guard installed == target.helperSHA256 else {
                        try settle(
                            &record, .recoveryRequired,
                            "The running helper is \(target.version) but the installed setup app is not")
                        return .proceed
                    }
                    try retainDisplaced(record)
                    if record.reseat {
                        try settle(
                            &record, record.restartRuntime ? .helperReady : .completed,
                            "The runtime helper was re-seated as a root-owned copy")
                        return .proceed
                    }
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
                    return .proceedUnconfirmed
                }
                if running == record.source.helperSHA256 {
                    if installed == target.helperSHA256 { return .relaunch }
                    try settle(&record, .refused, "The setup app was never exchanged. Nothing was changed.")
                    return .proceed
                }
                try settle(&record, .recoveryRequired, "The running helper is neither the previous nor the new one")
                return .proceed
            case .rollingBack:
                if installed == record.source.helperSHA256 {
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

    /// Swaps the retained source bytes back in, from a fresh sealed copy.
    /// Idempotent by inspection.
    func rollBack(_ record: inout RuntimeComponentUpdateRecord, _ reason: String) throws -> Launch {
        record.phase = .rollingBack
        record.reason = reason
        try save(&record)
        if try environment.inspect(environment.installedBundle).helperSHA256 != record.source.helperSHA256 {
            let retained = previous(record.operation)
            guard FileManager.default.fileExists(atPath: retained.path) else {
                try settle(&record, .recoveryRequired, reason + "; the previous setup app is not retained")
                return .proceed
            }
            let copy = restore(record.operation)
            try environment.secureCopy(retained, to: copy)
            try environment.verifyCode(copy, notarized: false)
            guard try environment.inspect(copy) == record.source else {
                try settle(&record, .recoveryRequired, reason + "; the retained setup app changed")
                return .proceed
            }
            try environment.swap(copy, environment.installedBundle)
            try environment.checkpoint("rolledBackSwap")
            try? rename(copy, rejected(record.operation))
        }
        return .relaunch
    }

    /// The target helper is serving (controller and both listeners started).
    /// Until this runs, every launch counts toward a rollback. Raises the
    /// root-held marks to the target.
    @discardableResult
    public func confirmTarget() throws -> Bool {
        guard var record = try read(), record.phase == .relaunching, let target = record.target,
            try environment.runningHelperSHA256() == target.helperSHA256
        else { return false }
        try raise(
            version: record.rollback ? nil : target.version, floor: record.manifest?.securityFloor,
            definition: target.daemonDefinitionSHA256)
        record.phase = .helperReady
        record.reason = nil
        try save(&record)
        return true
    }

    // MARK: Runtime follow-up (the target helper)

    /// The sealed root-only copy the runtime is staged from, checked against
    /// the target once more.
    public func verifiedSource(_ record: RuntimeComponentUpdateRecord) throws -> URL {
        let copy = verified(record.operation)
        guard let target = record.target, try environment.runningHelperSHA256() == target.helperSHA256,
            environment.isSealed(copy), try environment.inspect(copy) == target
        else {
            throw MicropodError.message(
                "The verified copy of runtime components \(record.targetVersion) is unavailable")
        }
        return copy
    }

    /// Records the coordinated restart that activates the target's runtime.
    public func beginRuntime(
        _ record: inout RuntimeComponentUpdateRecord, operation: UUID, previous: RuntimeComponentRuntime?
    ) throws {
        record.phase = record.phase == .restoringRuntime ? .restoringRuntime : .restarting
        record.runtimeOperation = operation
        if record.previousRuntime == nil { record.previousRuntime = previous }
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
        if record.phase == .restoringRuntime {
            try settle(
                &record, .refused,
                "The previous runtime could not be restored: " + reason + ". Nothing else was changed")
            return
        }
        try settle(
            &record, .helperUpdated,
            "Runtime helper \(record.targetVersion) is running; the dedicated runtime was not restarted: "
                + reason + ". `micropod runtime update` restarts it")
    }

    /// Follows the restart's terminal outcome. `completed` stands only when
    /// the runtime runs exactly the target's worker and API. A restart in
    /// recovery keeps the update waiting: `micropod runtime recover` settles
    /// it exactly as any other, and the update follows.
    /// Returns true when a rollback's restore finished and the helper swap
    /// should now run.
    @discardableResult
    public func followRuntime(_ status: IsolatedRuntimeStatus, activeAPI: RuntimeComponentAPI?) throws -> Bool {
        guard var record = try read(), [.restarting, .restoringRuntime].contains(record.phase),
            let runtime = record.runtimeOperation
        else { return false }
        guard status.operation == runtime else {
            if status.operation != nil, status.isTerminal {
                // Another operation replaced it: the restart never started.
                try deferRuntime(&record, "its restart \(runtime.uuidString) never started")
            }
            return false
        }
        guard status.isTerminal else { return false }
        switch status.phase {
        case "completed":
            if record.phase == .restoringRuntime {
                guard let previous = record.previousRuntime, status.workerSHA256 == previous.workerSHA256,
                    activeAPI == previous.api, status.selection == previous.selection
                else {
                    try settle(&record, .recoveryRequired, "The restored runtime is not the previous one")
                    return false
                }
                try runtimeRestored(&record)
                return true
            }
            guard let target = record.target, status.workerSHA256 == target.helperSHA256,
                activeAPI == RuntimeComponentAPI(executableSHA256: target.apiSHA256, guestSHA256: target.guestSHA256)
            else {
                try settle(
                    &record, .recoveryRequired,
                    "The restarted runtime does not run the verified worker and API of \(record.targetVersion)")
                return false
            }
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
        return false
    }

    // MARK: Helpers

    func settle(
        _ record: inout RuntimeComponentUpdateRecord, _ phase: RuntimeComponentUpdateRecord.Phase, _ reason: String
    ) throws {
        record.phase = phase
        record.reason = reason
        try save(&record)
    }

    /// After the swap the displaced bundle sits at the staging path. It is
    /// moved aside unread: it may be another account's files.
    func retainDisplaced(_ record: RuntimeComponentUpdateRecord) throws {
        let displaced = staged(record.operation)
        var info = stat()
        guard lstat(displaced.path, &info) == 0 else { return }
        if record.reseat {
            try RuntimeSecureCopy.remove(displaced)
            return
        }
        try rename(displaced, previous(record.operation))
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
    /// bytes, and the history of the last 32. Staging leftovers of a
    /// finished operation go, immutable flags included.
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
        for entry in operations where !keep.contains(entry.lastPathComponent) { try? RuntimeSecureCopy.remove(entry) }
        for kind in ["new", "restore"] { try? RuntimeSecureCopy.remove(path(record.operation, kind)) }
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
    public let runningVersion: String
    public init(executable: URL, runningVersion: String) {
        self.executable = executable
        self.runningVersion = runningVersion
    }

    public var root: URL { IsolatedRuntimePolicy.root }
    public var installedBundle: URL { RuntimeSetupInstallation.installedURL }

    public func offered() throws -> RuntimeComponentOffer {
        let resources = Self.desktopApp.appendingPathComponent("Contents/Resources")
        guard
            let manifest = try? RuntimeNonblockingFile.read(
                resources.appendingPathComponent(RuntimeComponentManifest.fileName),
                limit: RuntimeComponentManifest.maximumBytes),
            let signature = try? RuntimeNonblockingFile.read(
                resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName), limit: 1024),
            let plist = try? RuntimeNonblockingFile.read(
                Self.desktopApp.appendingPathComponent("Contents/Info.plist"), limit: 65536),
            let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let version = info["CFBundleShortVersionString"] as? String
        else {
            throw MicropodError.message(
                "The installed Micropod app carries no signed runtime component manifest; update the app first")
        }
        return .init(
            manifest: manifest, signature: signature,
            bundle: Self.desktopApp.appendingPathComponent("Contents/Helpers/" + RuntimeComponentUpdater.bundleName),
            desktopVersion: version, desktopRevision: info["MicropodSourceRevision"] as? String ?? "")
    }

    public func secureCopy(_ source: URL, to destination: URL) throws {
        try RuntimeSecureCopy.copy(source, to: destination, owner: 0, group: 0)
    }

    public func isSealed(_ bundle: URL) -> Bool {
        (try? RuntimeSecureCopy.assertSealed(bundle, owner: 0, group: 0)) != nil
    }

    public func inspect(_ bundle: URL) throws -> RuntimeComponentBundle {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? RuntimeNonblockingFile.read(plist, limit: 65536),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == IsolatedRuntimePolicy.setupIdentifier,
            let version = info["CFBundleShortVersionString"] as? String
        else { throw MicropodError.message("\(bundle.path) is not Micropod Runtime Setup") }
        let daemon = bundle.appendingPathComponent(Self.daemonPlist)
        let daemonBytes = try RuntimeNonblockingFile.read(daemon, limit: 65536)
        guard
            let definition = try PropertyListSerialization.propertyList(from: daemonBytes, format: nil)
                as? [String: Any]
        else { throw MicropodError.message("The runtime helper's launchd definition is unreadable") }
        let canonical = try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
        let guest = bundle.appendingPathComponent("Contents/Resources/micropod-guest")
        var guestInfo = stat()
        return .init(
            version: version, revision: info["MicropodSourceRevision"] as? String ?? "",
            cdhash: try Self.cdhash(bundle),
            helperSHA256: try ManagedRuntimeInstaller.sha256(
                bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")),
            apiSHA256: try ManagedRuntimeInstaller.sha256(bundle.appendingPathComponent("Contents/MacOS/MicropodAPI")),
            guestSHA256: lstat(guest.path, &guestInfo) == 0 ? try ManagedRuntimeInstaller.sha256(guest) : nil,
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

    public func activeAPI(identity: IsolatedRuntimeIdentity) -> RuntimeComponentAPI? {
        (try? IsolatedRuntimeAPIConfiguration.read(identity: identity)).map {
            .init(executableSHA256: $0.executableSHA256, guestSHA256: $0.guestSHA256)
        }
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
