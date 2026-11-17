import AppKit
import Foundation
import MicropodCore
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
/// Downloads require a durable continuity transaction before Sparkle can stage
/// an install-on-quit. Workload services retain their signed payloads and process
/// identities while the desktop and its linked command-line tools are replaced.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    /// Lazy so `self` is fully initialized before being passed as the
    /// (weakly-held) updater delegate.
    @ObservationIgnored
    lazy var controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: false,
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
    /// The desktop gate is closed and no local command is in flight. Workloads
    /// owned by the retained services may continue running.
    @ObservationIgnored var restartIsSafe: @MainActor () async -> Bool = { false }
    let restartGuard: UpdateRestartGuard
    @ObservationIgnored private let admission: ManagedUpdateAdmission?
    @ObservationIgnored nonisolated private let updateStore: UpdateContinuityStore
    var restartBlockedReason: String? {
        if let reason = restartGuard.blockedReason { return reason }
        if status == .updateAvailable, admission != nil, admission?.candidate?.isCompatible != true {
            return "This release has no compatible signed desktop payload."
        }
        return nil
    }
    @ObservationIgnored private var autoInstallTimer: Timer?
    @ObservationIgnored private var notifiedVersion: String?
    @ObservationIgnored nonisolated private let installerBoundary = UpdateInstallerBoundary()
    @ObservationIgnored private var preparingUpdate = false
    @ObservationIgnored private var informationCheck: UUID?
    @ObservationIgnored private var completedInformationCheck: UUID?
    @ObservationIgnored private var hasStartedUpdater = false

    /// How long the user must have been away before an automatic install.
    static let idleBeforeInstall: TimeInterval = 10 * 60
    static let autoInstallKey = "updates.installAutomatically"
    var automaticIdleSeconds: Double {
        get { UserDefaults.standard.object(forKey: "updates.idleSeconds") as? Double ?? Self.idleBeforeInstall }
        set { UserDefaults.standard.set(min(3600, max(0, newValue)), forKey: "updates.idleSeconds") }
    }

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

    init(feedConfigured: Bool? = nil, restartGuard: UpdateRestartGuard? = nil, store: UpdateContinuityStore = .standard)
    {
        self.feedConfigured = feedConfigured ?? (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil)
        let production = ManagedUpdateAdmission(store: store)
        let admission = restartGuard == nil ? production : nil
        self.updateStore = store
        self.admission = admission
        self.restartGuard = restartGuard ?? UpdateRestartGuard(coordinator: production)
        status = self.feedConfigured ? .idle : .unavailable
        super.init()
        if admission != nil, self.feedConfigured, updateStore.requiresRecovery {
            self.restartGuard.adoptRetainedRecovery()
        }
        self.restartGuard.didBlock = { [weak self] in
            guard let self else { return }
            if self.readyToInstall, [.readyToInstall, .installing].contains(self.status) {
                self.status = self.restartGuard.state == .recoveryRequired ? .error : .readyToInstall
            }
        }
        guard self.feedConfigured else { return }
        if UserDefaults.standard.object(forKey: "updates.checkAutomatically") == nil {
            UserDefaults.standard.set(
                UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true,
                forKey: "updates.checkAutomatically")
        }
        _ = controller
        // Automatic downloading can stage an install-on-quit outside our
        // guarded apply path. Checks remain informational until a fresh
        // workload-owner receipt authorizes this exact artifact.
        controller.updater.automaticallyDownloadsUpdates = false
        // Own the scheduler so every background check starts informationally.
        // An installation-capable Sparkle driver needs a durable receipt first.
        controller.updater.automaticallyChecksForUpdates = false
        startUpdaterIfPermitted()
        Task { @MainActor [weak self] in
            guard let self, self.restartGuard.state == .recoveryRequired else { return }
            if !(await self.restartGuard.reconcileRecovery()) {
                self.lastError = self.restartGuard.blockedReason
                self.status = .error
            } else {
                self.startUpdaterIfPermitted()
            }
        }
        // Look now rather than up to an hour after launch.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if self?.status != .readyToInstall, self?.checksAutomatically == true {
                self?.checkForUpdatesInBackground()
            }
        }
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await UpdateController.shared.installIfSafe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoInstallTimer = timer
    }

    /// Apply the automatic policy while the interface is in the background.
    /// Running workloads are not an idle requirement.
    func installIfSafe() async {
        guard !preparingUpdate else { return }
        if checksAutomatically, Date().timeIntervalSince(lastCheckedAt ?? .distantPast) >= 3600,
            ![.checking, .installing, .readyToInstall].contains(status)
        {
            checkForUpdatesInBackground()
        }
        guard [.updateAvailable, .readyToInstall].contains(status), installsAutomatically, !NSApp.isActive else {
            return
        }
        // kCGAnyInputEventType (~0): the last keyboard/mouse input of any kind.
        guard let anyInput = CGEventType(rawValue: ~0) else { return }
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard away >= automaticIdleSeconds else { return }
        await applyStagedUpdate()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The version a restart would install, when one is staged.
    var stagedVersion: String? {
        status == .readyToInstall ? (downloadedVersion ?? availableVersion) : nil
    }
    var installableVersion: String? {
        guard status == .readyToInstall || status == .updateAvailable && admission?.candidate?.isCompatible == true
        else { return nil }
        return downloadedVersion ?? availableVersion
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Information-only check while coordinated installation is unavailable.
    func checkForUpdates() {
        checkForUpdatesInBackground()
    }

    /// Information-only check for API/MCP triggers.
    func checkForUpdatesInBackground() {
        startInformationCheck(forPreparation: false)
    }

    private func startInformationCheck(forPreparation: Bool) {
        guard forPreparation || !preparingUpdate, ![.installing, .readyToInstall].contains(status) else { return }
        guard controller.updater.canCheckForUpdates, !controller.updater.sessionInProgress else { return }
        informationCheck = installerBoundary.beginInformationCheck()
        admission?.candidate = nil
        // A staged update stays staged: a newer check can't un-stage it.
        if status != .readyToInstall { status = .checking }
        lastError = nil
        controller.updater.checkForUpdateInformation()
    }

    private func startUpdaterIfPermitted() {
        guard feedConfigured, !hasStartedUpdater, !updateStore.requiresRecovery else { return }
        hasStartedUpdater = true
        controller.startUpdater()
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
        report["desktopAdmission"] = DesktopActivity.shared.isClosed ? "closed" : "open"
        report["automaticChecks"] = checksAutomatically
        report["automaticInstallation"] = installsAutomatically
        report["canCheckForUpdates"] = canCheckForUpdates
        report["automaticIdleSeconds"] = automaticIdleSeconds
        report["channel"] = channel.rawValue
        report["workloadProtocol"] = 1
        report["payloadCompatible"] = admission?.candidate?.isCompatible == true
        report["updateScope"] = "desktop; workload services and Apple runtime are retained"
        report["desktopRuntimeContext"] =
            feedConfigured
            ? (AppDependencies.shared.client.usesIsolatedTransport ? "managed" : "existing") : "unavailable"
        report["currentSourceRevision"] =
            Bundle.main.object(forInfoDictionaryKey: "MicropodSourceRevision") as? String ?? "unknown"
        do {
            if let receipt = try updateStore.read() {
                report["transaction"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
            }
        } catch { report["recoveryError"] = error.localizedDescription }
        if let restartBlockedReason { report["restartBlockedReason"] = restartBlockedReason }
        // The CLI and MCP server update with the app when linked into it.
        report["cliLinked"] = CLIToolLinks.linked
        if let lastError { report["error"] = lastError }
        if let lastCheckedAt { report["checkedAt"] = ISO8601DateFormatter().string(from: lastCheckedAt) }
        return report
    }

    /// Our scheduler keeps checks informational until admission is prepared.
    var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { self.checksAutomatically },
            set: { self.checksAutomatically = $0 })
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "updates.checkAutomatically") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updates.checkAutomatically") }
    }

    enum Channel: String { case stable, qualification }
    var channel: Channel {
        get { Channel(rawValue: UserDefaults.standard.string(forKey: "updates.channel") ?? "stable") ?? .stable }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "updates.channel") }
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updates.channel") == "qualification"
            ? "https://castlemilk.github.io/micropod/qualification-appcast.xml" : nil
    }

    /// Install a staged update via Sparkle's silent install handler —
    /// it terminates the app, swaps in the new version, and relaunches.
    /// Returns false until `willInstallUpdateOnQuit` has staged the
    /// update (poll `readyToInstall` first).
    @discardableResult
    func applyStagedUpdate() async -> Bool {
        // Injected coordinators exercise the same serial guard without
        // touching the installed app's durable production transaction.
        if admission == nil || !restartGuard.isAvailable {
            guard status == .readyToInstall, let handler = immediateInstallHandler else { return false }
            let accepted = await restartGuard.requestInstallation(noObservedWork: restartIsSafe) { handler() }
            let valid = accepted && [.prepared, .installationStarted].contains(restartGuard.state)
            if valid { status = .installing }
            return valid
        }
        if status == .readyToInstall, let handler = immediateInstallHandler {
            do {
                guard let receipt = try updateStore.read(), receipt.phase == .installing,
                    receipt.owner == (try RuntimeProcessBirth.read(getpid())), DesktopActivity.shared.isClosed
                else { return false }
                try receipt.verifyServices()
                status = .installing
                handler()
                return true
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
        guard !preparingUpdate, status == .updateAvailable, admission?.candidate?.isCompatible == true else {
            return false
        }
        // Our scheduler disables Sparkle checks, so the signed bundle must
        // explicitly allow guarded background downloads independently of them.
        guard controller.updater.allowsAutomaticUpdates else {
            lastError = "This app bundle cannot download guarded updates. Reinstall the current signed app."
            status = .error
            return false
        }
        preparingUpdate = true
        defer { preparingUpdate = false }
        // Probing reports the actual resumable item too. Sparkle may bypass
        // shouldProceed when resuming, so bind that fresh item before permission.
        startInformationCheck(forPreparation: true)
        guard let check = informationCheck else { return false }
        var found = false
        for _ in 0..<100 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            if completedInformationCheck == check, controller.updater.canCheckForUpdates {
                found = admission?.candidate?.isCompatible == true
                break
            }
        }
        guard found else { return false }
        guard controller.updater.canCheckForUpdates else { return false }
        let accepted = await restartGuard.requestInstallation(noObservedWork: restartIsSafe) { [weak self] in
            guard let self else { return }
            installerBoundary.reset()
            controller.updater.automaticallyDownloadsUpdates = true
            controller.updater.checkForUpdatesInBackground()
        }
        let stillAccepted = accepted && [.prepared, .installationStarted].contains(restartGuard.state)
        if stillAccepted { status = .installing }
        return stillAccepted
    }

    func reconcileUpdateRecovery() async -> Bool {
        if DesktopActivity.shared.isClosed, restartGuard.state != .recoveryRequired {
            restartGuard.adoptRetainedRecovery()
        }
        guard await restartGuard.reconcileRecovery() else { return false }
        startUpdaterIfPermitted()
        status = readyToInstall ? .readyToInstall : .idle
        return true
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle can resume an older installer without shouldProceedWithUpdate.
    /// Deny every installation-capable driver at the earlier check boundary.
    @objc(updater:mayPerformUpdateCheck:error:)
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updateInformation { return }
        _ = try qualifiedReceipt()
    }

    nonisolated func qualifiedReceipt(for item: SUAppcastItem? = nil) throws -> UpdateContinuityReceipt {
        guard let receipt = try updateStore.read(),
            [.downloading, .extracting, .installing].contains(receipt.phase),
            receipt.owner == (try RuntimeProcessBirth.read(getpid())), DesktopActivity.shared.isClosed
        else { throw UpdateRestartGuard.Failure.unavailable }
        try receipt.verifyServices()
        if let item {
            let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any]
            guard item.versionString == receipt.targetVersion,
                item.fileURL?.absoluteString == receipt.artifactURL, item.contentLength == receipt.artifactBytes,
                enclosure?["sparkle:edSignature"] as? String == receipt.artifactSignature,
                enclosure?["micropodSourceRevision"] as? String == receipt.targetSourceRevision,
                UpdaterPolicy.admitsFeedItem(minimumUpdateVersion: item.minimumUpdateVersion, enclosure: enclosure)
            else { throw MicropodError.message("The selected update does not match its prepared transaction") }
        }
        return receipt
    }

    nonisolated func updater(
        _ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard updateCheck != .updateInformation else { return }
        _ = try qualifiedReceipt(for: item)
    }

    nonisolated private func recordInstallerPhase(_ phase: UpdateContinuityReceipt.Phase, item: SUAppcastItem) throws {
        let receipt = try qualifiedReceipt(for: item)
        guard receipt.phase != phase, receipt.phase != .installing else { return }
        _ = try updateStore.transition(
            operation: receipt.operation, generation: receipt.generation,
            from: receipt.phase, to: phase)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let check = installerBoundary.informationCheck
        let display = item.displayVersionString
        let version = item.versionString
        let url = item.fileURL
        let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any]
        let signature = enclosure?["sparkle:edSignature"] as? String
        let source = enclosure?["micropodSourceRevision"] as? String
        let admitted = UpdaterPolicy.admitsFeedItem(
            minimumUpdateVersion: item.minimumUpdateVersion, enclosure: enclosure)
        let bytes = item.contentLength
        Task { @MainActor in
            guard informationCheck == check else { return }
            if ![.readyToInstall, .installing].contains(status) { status = .updateAvailable }
            availableVersion = display
            if let url, let signature, let source, admitted {
                admission?.candidate = .init(
                    version: version, url: url, signature: signature, bytes: bytes,
                    source: source)
            } else {
                admission?.candidate = nil
            }
            lastError = nil
            lastCheckedAt = Date()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { @MainActor in
            downloadedVersion = item.displayVersionString
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        // Sparkle starts its independent installer during extraction, before
        // willInstallUpdateOnQuit. Persist this boundary before returning.
        installerBoundary.markExtraction()
        do {
            try recordInstallerPhase(.extracting, item: item)
        } catch {
            NSLog(
                "Installer handoff is unconfirmed; update permission remains retained: %@", error.localizedDescription)
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
        installerBoundary.markPrepared()
        // Sparkle also installs on ordinary quit. Persist that boundary before
        // yielding back to its installer, rather than relying on a later Task.
        do {
            try recordInstallerPhase(.installing, item: item)
        } catch {
            // Permission was already retained before any download. An unknown
            // staging outcome must remain fenced, including on ordinary quit.
            NSLog("Update staging could not be reconciled: %@", error.localizedDescription)
            Task { @MainActor in
                let reason = "Update staging outcome is unconfirmed; the original receipt is retained."
                lastError = reason
                restartGuard.interrupted(reason: reason)
                status = .error
            }
            return true
        }
        let box = InstallHandlerBox(run: immediateInstallHandler)
        let version = item.displayVersionString
        Task { @MainActor in
            stageUpdate(version: version, handler: box.run)
            if notifiedVersion != version {
                notifiedVersion = version
                MicropodNotifier.shared.postUpdateReady(version: version)
            }
            // The durable hold was acquired before downloading, including the
            // install-on-quit path. Finish this same transaction immediately.
            _ = await applyStagedUpdate()
        }
        return true
    }

    /// The guarded download ended without staging and its receipt recorded
    /// the rejection. A failure keeps the offer beside its error. A cycle
    /// that found nothing installable withdraws the offer, so the status never
    /// says up to date while still naming an available version; the next
    /// information check finds it again if the feed still offers it.
    func settleRejectedDownload(failure: String?) {
        if let failure {
            lastError = failure
            status = .error
            return
        }
        status = .upToDate
        availableVersion = nil
        admission?.candidate = nil
    }

    func stageUpdate(version: String, handler: @escaping () -> Void) {
        immediateInstallHandler = handler
        readyToInstall = true
        status = .readyToInstall
        downloadedVersion = version
        lastError = nil
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let check = installerBoundary.informationCheck
        Task { @MainActor in
            guard informationCheck == check else { return }
            lastCheckedAt = Date()
            // Nothing newer than what is already staged: keep it staged.
            guard status != .readyToInstall else { return }
            status = .upToDate
            availableVersion = nil
            admission?.candidate = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installerBoundary.markPrepared()
        do {
            try recordInstallerPhase(.installing, item: item)
        } catch { NSLog("Update installation outcome requires recovery: %@", error.localizedDescription) }
        Task { @MainActor in
            status = .installing
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        let check = installerBoundary.informationCheck
        Task { @MainActor in
            guard informationCheck == check else { return }
            if updateCheck == .updateInformation { completedInformationCheck = check }
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
            let failure = error as NSError?
            let rejectedArchive =
                failure?.domain == SUSparkleErrorDomain
                && [Int(SUError.validationError.rawValue), Int(SUError.unarchivingError.rawValue)].contains(
                    failure?.code ?? -1)
            if updateCheck != .updateInformation, !installerBoundary.hasPrepared,
                let receipt = try? updateStore.read(),
                receipt.phase == .downloading && !installerBoundary.hasExtracted
                    || receipt.phase == .extracting && rejectedArchive
            {
                let reason = error?.localizedDescription ?? "No installable update remained after preparation"
                restartGuard.interrupted(reason: reason)
                do {
                    guard receipt.owner == (try RuntimeProcessBirth.read(getpid())),
                        try ManagedUpdateAdmission.currentExecutableDigest() == receipt.sourceExecutableSHA256
                    else { throw MicropodError.message("Original desktop identity changed") }
                    _ = try updateStore.transition(
                        operation: receipt.operation,
                        generation: receipt.generation, from: receipt.phase, to: .downloadRejected, detail: reason)
                    _ = await reconcileUpdateRecovery()
                    settleRejectedDownload(failure: error == nil || benign ? nil : reason)
                } catch { status = .error }
            }
            if updateCheck == .updateInformation, error == nil { await installIfSafe() }
        }
    }
}

private final class UpdateInstallerBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var extracted = false
    private var prepared = false
    private var check: UUID?
    func beginInformationCheck() -> UUID {
        lock.withLock {
            let id = UUID()
            check = id
            return id
        }
    }
    var informationCheck: UUID? { lock.withLock { check } }
    func markExtraction() { lock.withLock { extracted = true } }
    func markPrepared() {
        lock.withLock {
            extracted = true
            prepared = true
        }
    }
    func reset() {
        lock.withLock {
            extracted = false
            prepared = false
        }
    }
    var hasExtracted: Bool { lock.withLock { extracted } }
    var hasPrepared: Bool { lock.withLock { prepared } }
}
