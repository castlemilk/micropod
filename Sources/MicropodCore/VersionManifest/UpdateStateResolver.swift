import Foundation

/// Derives the one read-only UpdateState from what an updater actually
/// recorded: the app's `update.status` report (its durable transaction,
/// restart guard and Sparkle status) and the runtime admission gate. Nothing
/// is inferred from elapsed time or from a version comparison alone.
public enum UpdateStateResolver {
    public static let desktopScope = "desktop"
    public static let runtimeScope = "runtime"

    /// Transaction phases in which an update is in flight.
    static let inFlightPhases: Set<String> = ["prepared", "downloading", "extracting", "installing"]

    /// The desktop updater's state from the app's `update.status` report.
    /// Unknown keys are ignored; absent keys mean "not reported".
    public static func desktop(report: [String: Any]) -> Micropod_V1_UpdateState {
        let status = report["state"] as? String ?? ""
        let guardState = report["restartGuard"] as? String ?? ""
        let blocker = text(report["restartBlockedReason"])
        let transaction = report["transaction"] as? [String: Any]
        let phase = transaction?["phase"] as? String
        let detail = text(transaction?["detail"])
        let target = text(transaction?["targetVersion"])
        let available = text(report["availableVersion"])
        let downloaded = text(report["downloadedVersion"])

        var state = Micropod_V1_UpdateState()
        state.scope = desktopScope
        state.currentVersion = text(report["currentVersion"]) ?? ComponentProbe.unknown
        if let available { state.availableVersion = available }
        if let transaction {
            state.operationID = transaction["operation"] as? String ?? ""
            if let updated = timestamp(transaction["updatedAt"]) { state.updatedAt = updated }
        }
        func finish(
            _ kind: Micropod_V1_UpdateState.Kind, phase: String = "", reason: String? = nil, target: String? = nil
        ) -> Micropod_V1_UpdateState {
            var result = state
            result.kind = kind
            result.phase = phase
            result.reason = reason ?? ""
            result.targetVersion = target ?? ""
            return result
        }

        if let failure = text(report["recoveryError"]) {
            return finish(.recoveryRequired, reason: "The update transaction cannot be read: \(failure)")
        }
        if guardState == "recoveryRequired" || phase == "recoveryRequired" {
            return finish(
                .recoveryRequired,
                reason: blocker ?? detail
                    ?? "An update's outcome is unknown; it is retained until a verified reconciliation.",
                target: target)
        }
        if let phase, inFlightPhases.contains(phase) {
            return finish(.upgrading, phase: phase, target: target)
        }
        if guardState == "preparing" || guardState == "prepared" {
            return finish(.upgrading, phase: guardState, target: downloaded ?? available)
        }
        if guardState == "installationStarted" || status == "installing" {
            return finish(.upgrading, phase: "installing", target: target ?? downloaded ?? available)
        }
        if phase == "downloadRejected" {
            return finish(
                .rolledBack, reason: detail ?? "The download was rejected before installation", target: target)
        }
        if status == "readyToInstall" || report["readyToInstall"] as? Bool == true {
            let staged = downloaded ?? available
            if let blocker { return finish(.blocked, reason: blocker, target: staged) }
            return finish(.staged, target: staged)
        }
        if status == "updateAvailable" || (guardState == "blocked" && available != nil), let blocker {
            return finish(.blocked, reason: blocker, target: available)
        }
        if phase == "aborted", let target, target != state.currentVersion {
            return finish(
                .rolledBack, reason: detail ?? "The update was abandoned before it took effect", target: target)
        }
        return finish(.current, reason: status == "error" ? text(report["error"]) : nil)
    }

    /// The answering server cannot observe this updater.
    public static func unobservable(scope: String, reason: String) -> Micropod_V1_UpdateState {
        Micropod_V1_UpdateState.with {
            $0.kind = .unknown
            $0.scope = scope
            $0.reason = reason
            $0.currentVersion = ComponentProbe.unknown
        }
    }

    /// Runtime maintenance from the admission gate the maintenance closes.
    public static func runtime(admission: RuntimeAdmission, currentVersion: String) -> Micropod_V1_UpdateState {
        var state = Micropod_V1_UpdateState()
        state.scope = runtimeScope
        state.currentVersion = currentVersion.isEmpty ? ComponentProbe.unknown : currentVersion
        guard admission.isClosed else {
            state.kind = .current
            return state
        }
        state.kind = .upgrading
        state.phase = "runtime-maintenance"
        do {
            let fence = try admission.readFence()
            state.operationID = fence.operation.uuidString
            state.reason =
                fence.actionStarted
                ? "Runtime maintenance closed workload admission and its action has started"
                : "Runtime maintenance closed workload admission; its action has not started"
        } catch {
            state.reason =
                "Runtime maintenance closed workload admission; its operation is not readable here: "
                + error.localizedDescription
        }
        return state
    }

    /// One state for both updaters: an unknown desktop outcome first, then
    /// runtime maintenance in flight, then the desktop's own state.
    public static func combined(desktop: Micropod_V1_UpdateState, runtime: Micropod_V1_UpdateState)
        -> Micropod_V1_UpdateState
    {
        if desktop.kind == .recoveryRequired { return desktop }
        if runtime.kind == .upgrading || runtime.kind == .recoveryRequired { return runtime }
        return desktop
    }

    /// A disruptive rig upgrade's state from its journal and the newest staged
    /// release, or nil when neither says anything. `installedVersion` is the
    /// app on disk, which a staged release must be newer than. `active` is
    /// false for a journal that has disrupted nothing and that no engine or
    /// helper will run (RigUpgradeFence.isActive): it is not reported.
    public static func rig(
        journal: RigUpgradeJournal?, staged: RigStagedRelease?, installedVersion: String?, active: Bool = true
    ) -> Micropod_V1_UpdateState? {
        func state(_ kind: Micropod_V1_UpdateState.Kind) -> Micropod_V1_UpdateState {
            var state = Micropod_V1_UpdateState()
            state.kind = kind
            state.scope = desktopScope
            state.currentVersion = installedVersion ?? ComponentProbe.unknown
            return state
        }
        if let journal, active || ![.prepared, .draining].contains(journal.phase) {
            var result = state(.current)
            result.operationID = journal.operation.uuidString
            result.updatedAt = ISO8601DateFormatter().string(from: journal.updatedAt)
            result.targetVersion = journal.target.version
            let dedicated = journal.dedicatedRuntime ? " " + RigUpgradeEngine.dedicatedNote : ""
            switch journal.phase {
            case .prepared, .draining, .stopping, .swapping, .starting, .verifying, .completing:
                result.kind = .upgrading
                result.phase = "rig-" + journal.phase.rawValue
                result.currentVersion = journal.source.version
                result.reason =
                    "Disruptive upgrade \(journal.source.version) → \(journal.target.version); jobs may be "
                    + "interrupted." + dedicated
                return result
            case .rollingBack:
                result.kind = .upgrading
                result.phase = "rig-rolling-back"
                result.currentVersion = journal.source.version
                result.reason = "Restoring \(journal.source.version): \(journal.failure ?? "the upgrade failed")"
                return result
            case .recoveryRequired:
                result.kind = .recoveryRequired
                result.reason = journal.reason ?? "The rig upgrade could not finish its rollback"
                return result
            case .rolledBack, .refused:
                // A release staged after the outcome replaces it.
                if let staged, staged.stagedAt > journal.updatedAt, staged.isNewer(than: installedVersion ?? "") {
                    break
                }
                result.kind = journal.phase == .refused ? .blocked : .rolledBack
                result.reason = journal.reason ?? ""
                return result
            case .completed:
                break
            }
        }
        guard let staged, let installedVersion, staged.isNewer(than: installedVersion) else { return nil }
        var result = state(.staged)
        result.targetVersion = staged.identity.version
        result.updatedAt = ISO8601DateFormatter().string(from: staged.stagedAt)
        return result
    }

    /// The rig upgrade state this account's files (and launchd) describe.
    public static func rig(
        layout: RigUpgradeLayout, helperProgram: (String) -> String? = RigLaunchctl.loadedProgramNow
    ) -> Micropod_V1_UpdateState? {
        let installed = (try? ComponentProbe.bundleStamp(layout.appPath))?.version
        let journal = try? RigUpgradeStore(layout: layout).read()
        return rig(
            journal: journal, staged: RigStagedRelease.newest(in: layout),
            installedVersion: installed == ComponentProbe.unknown ? nil : installed,
            active: journal.map { RigUpgradeFence.isActive($0, layout: layout, helperProgram: helperProgram) } ?? false)
    }

    /// Both updaters plus a disruptive rig upgrade. An upgrade in flight wins
    /// (the app it replaces cannot report); its rollback, refusal or staged
    /// release outranks a desktop that is merely current or unobservable.
    public static func combined(
        desktop: Micropod_V1_UpdateState, runtime: Micropod_V1_UpdateState, rig: Micropod_V1_UpdateState?
    ) -> Micropod_V1_UpdateState {
        let base = combined(desktop: desktop, runtime: runtime)
        guard let rig else { return base }
        if rig.kind == .upgrading || rig.kind == .recoveryRequired { return rig }
        guard [.current, .unknown, .unspecified].contains(base.kind) else { return base }
        var result = rig
        if result.availableVersion.isEmpty { result.availableVersion = base.availableVersion }
        return result
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    /// ISO 8601 from JSONEncoder's default date encoding (seconds since
    /// 2001) or an ISO 8601 string; nil otherwise.
    public static func timestamp(_ value: Any?) -> String? {
        let formatter = ISO8601DateFormatter()
        if let seconds = value as? Double {
            return formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
        }
        if let seconds = value as? Int {
            return formatter.string(from: Date(timeIntervalSinceReferenceDate: TimeInterval(seconds)))
        }
        if let text = value as? String, formatter.date(from: text) != nil { return text }
        return nil
    }
}
