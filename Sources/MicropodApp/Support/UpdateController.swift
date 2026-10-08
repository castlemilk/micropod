import AppKit
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Single owner of the Sparkle updater.
///
/// The packaged app publishes an EdDSA-signed appcast on GitHub Pages
/// (`SUFeedURL` in the packaged Info.plist). Dev/test binaries have no
/// Info.plist feed key, so the updater only starts when a feed is
/// configured — keeps `swift run` and XCTest hosts from talking to the
/// release channel.
///
/// Delegate callbacks record the last check's outcome so the app-control
/// socket (`update.status`) can report it to the API server and MCP, and
/// the UI (banner, menu bar, Settings) observes it.
///
/// Installation requires a qualified admission coordinator. Until that bridge exists,
/// information checks remain available and every installation path is blocked:
/// a restart stops the app's API/shim agents and can interrupt new work.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    /// Lazy so `self` is fully initialized before being passed as the
    /// (weakly-held) updater delegate.
    @ObservationIgnored
    lazy var controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: feedConfigured,
        updaterDelegate: self,
        userDriverDelegate: nil)

    /// Whether an appcast feed is configured — false in dev/test bundles.
    @ObservationIgnored private let feedConfigured: Bool

    /// Lifecycle states surfaced to API/MCP callers.
    enum Status: String {
        case unavailable  // no SUFeedURL (dev/test binary)
        case idle
        case checking
        case upToDate
        case updateAvailable  // information check found a newer version
        case readyToInstall  // downloaded and staged: restart installs it
        case installing
        case error
    }

    private(set) var status: Status
    private(set) var availableVersion: String?
    private(set) var downloadedVersion: String?
    /// True once Sparkle has extracted the update and staged it for
    /// install-on-quit — `applyStagedUpdate` only works in this state.
    private(set) var readyToInstall = false
    private(set) var lastError: String?
    private(set) var lastCheckedAt: Date?

    /// Sparkle's silent install+relaunch block, captured when the
    /// update is fully staged. nil until then.
    @ObservationIgnored private var immediateInstallHandler: (() -> Void)?
    /// Whether nothing would be disrupted by a restart right now (no running
    /// containers) — set by the app once its store is up.
    @ObservationIgnored var restartIsSafe: @MainActor () async -> Bool = { false }
    let restartGuard: UpdateRestartGuard
    var restartBlockedReason: String? { restartGuard.blockedReason }
    @ObservationIgnored private var autoInstallTimer: Timer?
    @ObservationIgnored private var notifiedVersion: String?

    /// How long the user must have been away before an automatic install.
    static let idleBeforeInstall: TimeInterval = 10 * 60
    static let autoInstallKey = "updates.installAutomatically"

    /// Install staged updates on their own when it is safe (default on).
    var installsAutomatically: Bool {
        get {
            access(keyPath: \.installsAutomatically)
            return UserDefaults.standard.object(forKey: Self.autoInstallKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.installsAutomatically) {
                UserDefaults.standard.set(newValue, forKey: Self.autoInstallKey)
            }
        }
    }

    init(feedConfigured: Bool? = nil, restartGuard: UpdateRestartGuard = UpdateRestartGuard()) {
        self.feedConfigured = feedConfigured ?? (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil)
        self.restartGuard = restartGuard
        status = self.feedConfigured ? .idle : .unavailable
        super.init()
        restartGuard.didBlock = { [weak self] in
            guard let self else { return }
            if self.readyToInstall, [.readyToInstall, .installing].contains(self.status) {
                self.status = self.restartGuard.state == .recoveryRequired ? .error : .readyToInstall
            }
        }
        guard self.feedConfigured else { return }
        _ = controller
        // Automatic downloading can stage an install-on-quit outside our
        // guarded apply path. Keep checks informational until the bridge is
        // qualified, including resumed Sparkle drivers.
        controller.updater.automaticallyDownloadsUpdates = false
        // Look now rather than up to an hour after launch.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if self?.status != .readyToInstall { self?.checkForUpdatesInBackground() }
        }
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await UpdateController.shared.installIfSafe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoInstallTimer = timer
    }

    /// Installs a staged update when nobody would notice: automatic
    /// installs on, the app in the background, the user idle, and nothing
    /// running.
    func installIfSafe() async {
        guard status == .readyToInstall, installsAutomatically, !NSApp.isActive else { return }
        // kCGAnyInputEventType (~0): the last keyboard/mouse input of any kind.
        guard let anyInput = CGEventType(rawValue: ~0) else { return }
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard away >= Self.idleBeforeInstall else { return }
        await applyStagedUpdate()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The version a restart would install, when one is staged.
    var stagedVersion: String? {
        status == .readyToInstall ? (downloadedVersion ?? availableVersion) : nil
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Information-only check while coordinated installation is unavailable.
    func checkForUpdates() {
        if status != .readyToInstall { status = .checking }
        // Information checks cannot start a Sparkle installer. Both interactive
        // and automatic install drivers are denied below until qualification.
        controller.updater.checkForUpdateInformation()
    }

    /// Information-only check for API/MCP triggers.
    func checkForUpdatesInBackground() {
        // A staged update stays staged: a newer check can't un-stage it.
        if status != .readyToInstall { status = .checking }
        lastError = nil
        controller.updater.checkForUpdateInformation()
    }

    var statusReport: [String: Any] {
        var report: [String: Any] = [
            "state": status.rawValue,
            "feedConfigured": feedConfigured,
            "currentVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
        ]
        if let availableVersion { report["availableVersion"] = availableVersion }
        if let downloadedVersion {
            report["downloaded"] = true
            report["downloadedVersion"] = downloadedVersion
        }
        if readyToInstall { report["readyToInstall"] = true }
        report["restartGuard"] = restartGuard.state.rawValue
        if let restartBlockedReason { report["restartBlockedReason"] = restartBlockedReason }
        // The CLI and MCP server update with the app when linked into it.
        report["cliLinked"] = CLIToolLinks.linked
        if let lastError { report["error"] = lastError }
        if let lastCheckedAt { report["checkedAt"] = ISO8601DateFormatter().string(from: lastCheckedAt) }
        return report
    }

    /// Bound to `SUEnableAutomaticChecks`; Sparkle persists it in
    /// standard user defaults itself.
    var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { [controller] in controller.updater.automaticallyChecksForUpdates },
            set: { [controller] in controller.updater.automaticallyChecksForUpdates = $0 })
    }

    /// Install a staged update via Sparkle's silent install handler —
    /// it terminates the app, swaps in the new version, and relaunches.
    /// Returns false until `willInstallUpdateOnQuit` has staged the
    /// update (poll `readyToInstall` first).
    @discardableResult
    func applyStagedUpdate() async -> Bool {
        guard status == .readyToInstall, let handler = immediateInstallHandler else { return false }
        let accepted = await restartGuard.requestInstallation(noObservedWork: restartIsSafe) { [weak self] in
            self?.spawnRelaunchWatchdog()
            handler()
        }
        let stillAccepted = accepted && [.prepared, .installationStarted].contains(restartGuard.state)
        if stillAccepted { status = .installing }
        return stillAccepted
    }

    func reconcileUpdateRecovery() async -> Bool {
        guard await restartGuard.reconcileRecovery() else { return false }
        status = readyToInstall ? .readyToInstall : .idle
        return true
    }

    /// Belt-and-suspenders relaunch: Sparkle's progress agent relaunches
    /// the app via NSWorkspace, but that call can race the bundle swap
    /// or be dropped for silent installs. A detached helper waits for
    /// this process to exit, then `open`s the bundle (a no-op activate
    /// if Sparkle already relaunched it). Survives our termination
    /// because it gets reparented to launchd.
    private func spawnRelaunchWatchdog() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let log = NSString("~/.micropod/run/relaunch.log").expandingTildeInPath
        let logDir = (log as NSString).deletingLastPathComponent
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            mkdir -p '\(logDir)'
            exec >>'\(log)' 2>&1
            echo "watchdog spawned pid=\(pid) path=\(path)"
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            echo "parent exited"
            sleep 1.5
            for i in 1 2 3 4 5 6 7 8 9 10; do
                /usr/bin/open '\(path)' && { echo "relaunched (try $i)"; exit 0; }
                sleep 1
            done
            echo "relaunch failed"
            exit 1
            """,
        ]
        do {
            try helper.run()
        } catch {
            NSLog("UpdateController: failed to spawn relaunch watchdog: \(error)")
        }
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle can resume an older installer without shouldProceedWithUpdate.
    /// Deny every installation-capable driver at the earlier check boundary.
    @objc(updater:mayPerformUpdateCheck:error:)
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try Self.requireInformationCheck(updateCheck)
    }

    nonisolated static func requireInformationCheck(_ updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updateInformation else {
            throw NSError(
                domain: "Micropod.UpdateAdmission", code: 1,
                userInfo: [NSLocalizedDescriptionKey: UpdateRestartGuard.unavailableReason])
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            if ![.readyToInstall, .installing].contains(status) { status = .updateAvailable }
            availableVersion = item.displayVersionString
            lastError = nil
            lastCheckedAt = Date()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { @MainActor in
            downloadedVersion = item.displayVersionString
        }
    }

    /// Sparkle's install block isn't declared Sendable — box it so it can
    /// cross into the MainActor hop.
    private struct InstallHandlerBox: @unchecked Sendable {
        let run: () -> Void
    }

    /// The update is extracted and staged — Sparkle asks whether to run
    /// its normal (gentle-UI) scheduler or hand control to us. We take
    /// control so the app-control socket can trigger a silent install
    /// + relaunch on demand; Sparkle still installs on quit regardless.
    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let box = InstallHandlerBox(run: immediateInstallHandler)
        let version = item.displayVersionString
        Task { @MainActor in
            stageUpdate(version: version, handler: box.run)
            if notifiedVersion != version {
                notifiedVersion = version
                MicropodNotifier.shared.postUpdateReady(version: version)
            }
        }
        return true
    }

    func stageUpdate(version: String, handler: @escaping () -> Void) {
        immediateInstallHandler = handler
        readyToInstall = true
        status = .readyToInstall
        downloadedVersion = version
        lastError = nil
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in
            lastCheckedAt = Date()
            // Nothing newer than what is already staged: keep it staged.
            guard status != .readyToInstall else { return }
            status = .upToDate
            availableVersion = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in
            status = .installing
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        Task { @MainActor in
            lastCheckedAt = Date()
            // "No update found" is also delivered here as SUNoUpdateError —
            // benign, not a real error.
            let benign = (error as? NSError)?.code == Int(SUError.noUpdateError.rawValue)
            if let error, !benign {
                lastError = error.localizedDescription
                restartGuard.interrupted(reason: "Update interrupted: \(error.localizedDescription)")
                if ![.updateAvailable, .readyToInstall, .installing].contains(status) {
                    status = .error
                }
            } else {
                lastError = nil
                if status == .checking {
                    status = readyToInstall ? .readyToInstall : .idle
                }
            }
        }
    }
}
