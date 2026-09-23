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
    private(set) var lastError: String?
    private(set) var lastCheckedAt: Date?

    private override init() {
        feedConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        status = feedConfigured ? .idle : .unavailable
        super.init()
        _ = controller
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

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            status = .updateAvailable
            availableVersion = item.displayVersionString
            lastError = nil
            lastCheckedAt = Date()
        }
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
