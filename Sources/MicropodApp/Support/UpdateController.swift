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
/// Updates download in the background and install on quit. Because
/// Micropod rarely quits, a staged update also installs itself when it is
/// safe: the app isn't frontmost, the user has been idle for
/// ``idleBeforeInstall``, and no containers are running — a restart
/// briefly stops the app's agents (Docker shim, API), which in-flight jobs
/// would notice. Otherwise the banner's "Restart to Update" does it.
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
        case updateAvailable  // found; downloading
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

    private override init() {
        feedConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        status = feedConfigured ? .idle : .unavailable
        super.init()
        _ = controller
        // Hands-off apply path: updates found by background checks
        // download silently and install automatically on quit — the
        // app-control socket can drive the whole loop headless.
        controller.updater.automaticallyDownloadsUpdates = true
        guard feedConfigured else { return }
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
        guard away >= Self.idleBeforeInstall, await restartIsSafe(), status == .readyToInstall else { return }
        applyStagedUpdate()
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

    /// UI check — shows Sparkle's dialog (menu button).
    func checkForUpdates() {
        if status != .readyToInstall { status = .checking }
        controller.checkForUpdates(nil)
    }

    /// Silent check for API/MCP triggers — Sparkle's gentle UI still
    /// appears only when an update is actually found.
    func checkForUpdatesInBackground() {
        // A staged update stays staged: a newer check can't un-stage it.
        if status != .readyToInstall { status = .checking }
        lastError = nil
        controller.updater.checkForUpdatesInBackground()
    }

    var statusReport: [String: Any] {
        var report: [String: Any] = [
            "state": status.rawValue,
            "feedConfigured": status != .unavailable,
            "currentVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
        ]
        if let availableVersion { report["availableVersion"] = availableVersion }
        if let downloadedVersion {
            report["downloaded"] = true
            report["downloadedVersion"] = downloadedVersion
        }
        if readyToInstall { report["readyToInstall"] = true }
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
    func applyStagedUpdate() -> Bool {
        guard let handler = immediateInstallHandler else { return false }
        status = .installing
        spawnRelaunchWatchdog()
        // Sparkle's install handler terminates this process — give the
        // app-control server a beat to flush its response first so API
        // callers get a real 202 instead of a dropped connection.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            handler()
        }
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

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            if status != .readyToInstall { status = .updateAvailable }
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
            self.immediateInstallHandler = box.run
            readyToInstall = true
            status = .readyToInstall
            downloadedVersion = version
            lastError = nil
            if notifiedVersion != version {
                notifiedVersion = version
                MicropodNotifier.shared.postUpdateReady(version: version)
            }
        }
        return true
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
