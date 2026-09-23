import Foundation
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
/// socket (`update.status`) can report it to the API server and MCP.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    /// Lazy so `self` is fully initialized before being passed as the
    /// (weakly-held) updater delegate.
    lazy var controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: feedConfigured,
        updaterDelegate: self,
        userDriverDelegate: nil)

    /// Whether an appcast feed is configured — false in dev/test bundles.
    private let feedConfigured: Bool

    /// Lifecycle states surfaced to API/MCP callers.
    enum Status: String {
        case unavailable  // no SUFeedURL (dev/test binary)
        case idle
        case checking
        case upToDate
        case updateAvailable
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
    private var immediateInstallHandler: (() -> Void)?

    private override init() {
        feedConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        status = feedConfigured ? .idle : .unavailable
        super.init()
        _ = controller
        // Hands-off apply path: updates found by background checks
        // download silently and install automatically on quit — the
        // app-control socket can drive the whole loop headless.
        controller.updater.automaticallyDownloadsUpdates = true
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// UI check — shows Sparkle's dialog (menu button).
    func checkForUpdates() {
        status = .checking
        controller.checkForUpdates(nil)
    }

    /// Silent check for API/MCP triggers — Sparkle's gentle UI still
    /// appears only when an update is actually found.
    func checkForUpdatesInBackground() {
        status = .checking
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
            status = .updateAvailable
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
        Task { @MainActor in
            self.immediateInstallHandler = box.run
            readyToInstall = true
        }
        return true
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in
            status = .upToDate
            availableVersion = nil
            lastCheckedAt = Date()
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
                if status != .updateAvailable && status != .installing {
                    status = .error
                }
            } else {
                lastError = nil
                if status == .checking {
                    status = .idle
                }
            }
        }
    }
}
