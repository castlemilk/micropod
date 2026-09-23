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
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    let controller: SPUStandardUpdaterController

    private init() {
        let feedConfigured =
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: feedConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Bound to `SUEnableAutomaticChecks`; Sparkle persists it in
    /// standard user defaults itself.
    var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { [controller] in controller.updater.automaticallyChecksForUpdates },
            set: { [controller] in controller.updater.automaticallyChecksForUpdates = $0 })
    }
}
