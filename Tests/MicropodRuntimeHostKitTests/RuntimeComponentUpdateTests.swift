import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodRuntimeHostKit

/// The dedicated API the runtime is configured with, shared by the component
/// environment fixture and a driver fixture that "activates" what it staged.
final class ActiveAPIBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _active: RuntimeComponentAPI?
    private var _staged: RuntimeComponentAPI?
    var active: RuntimeComponentAPI? {
        get { lock.withLock { _active } }
        set { lock.withLock { _active = newValue } }
    }
    var staged: RuntimeComponentAPI? {
        get { lock.withLock { _staged } }
        set { lock.withLock { _staged = newValue } }
    }
    func activate() { lock.withLock { if let staged = _staged { _active = staged } } }
}

/// Real directories, real `renamex_np` swaps and the real secure copy (owned
/// by this account instead of root); code signing, the probe, notarization and
/// "which helper launchd started" are simulated. A bundle is a directory with
/// `identity.json` (what `inspect` reports), a helper payload whose bytes stand
/// in for the executable, and `signed`.
final class ComponentEnvironmentFixture: RuntimeComponentEnvironment, @unchecked Sendable {
    let root: URL
    let installedBundle: URL
    let desktop: URL
    let key = Curve25519.Signing.PrivateKey()
    let api: ActiveAPIBox
    let group: gid_t
    private let lock = NSLock()
    private var _running: String
    private var _runningVersion: String?
    private var _stopAt: String?
    private var _copies: [URL] = []
    private var _verified: [URL] = []
    private var _swaps: [URL] = []
    private var _desktop: (String, String)?
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    static let source = bundle("0.13.9", "9", cdhash: "1", helper: "2", api: "3")
    static let target = bundle("0.13.10", "a", cdhash: "b", helper: "c", api: "e")

    static func bundle(
        _ version: String, _ revision: Character, cdhash: Character, helper: Character, api: Character,
        definition: Character = "5"
    ) -> RuntimeComponentBundle {
        .init(
            version: version, revision: String(repeating: revision, count: 40),
            cdhash: String(repeating: cdhash, count: 40), helperSHA256: String(repeating: helper, count: 64),
            apiSHA256: String(repeating: api, count: 64), guestSHA256: nil,
            daemonPlistSHA256: String(repeating: "4", count: 64),
            daemonDefinitionSHA256: String(repeating: definition, count: 64))
    }

    init(root: URL, api: ActiveAPIBox = .init()) throws {
        self.root = root
        self.api = api
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        group = info.st_gid
        installedBundle = root.appendingPathComponent("Applications/Micropod Runtime Setup.app")
        desktop = root.appendingPathComponent("Applications/Micropod.app")
        _running = Self.source.helperSHA256
        try Self.makeBundle(installedBundle, Self.source)
        try offer(Self.target)
    }

    static func makeBundle(_ url: URL, _ identity: RuntimeComponentBundle, signed: Bool = true) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try RuntimeSecureCopy.remove(url) }
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: url.appendingPathComponent("identity.json"))
        try Data(("helper " + identity.helperSHA256).utf8).write(
            to: url.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"))
        if signed { try Data().write(to: url.appendingPathComponent("signed")) }
    }

    static func manifest(
        _ identity: RuntimeComponentBundle, securityFloor: String? = nil, minimumHelper: String = "0.13.9"
    ) -> RuntimeComponentManifest {
        let apple = RuntimeComponentManifest.AppleRuntime(
            version: AppleRuntimeRelease.supported.version, packageSHA256: AppleRuntimeRelease.supported.packageSHA256)
        return .init(
            version: identity.version, sourceRevision: identity.revision, minimumHelperVersion: minimumHelper,
            setup: .init(
                bundleIdentifier: IsolatedRuntimePolicy.setupIdentifier, cdhash: identity.cdhash,
                daemonPlistSHA256: identity.daemonPlistSHA256),
            helper: .init(identifier: IsolatedRuntimePolicy.helperIdentifier, sha256: identity.helperSHA256),
            api: .init(identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier, sha256: identity.apiSHA256),
            guestSHA256: identity.guestSHA256, appleRuntime: apple, appleRuntimes: [apple],
            securityFloor: securityFloor)
    }

    /// Puts `identity` inside the desktop app with a manifest signed by `signer`.
    func offer(
        _ identity: RuntimeComponentBundle, signed: Bool = true, signer: Curve25519.Signing.PrivateKey? = nil,
        manifest override: RuntimeComponentManifest? = nil
    ) throws {
        try Self.makeBundle(
            desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app"), identity, signed: signed)
        let manifest = override ?? Self.manifest(identity)
        let bytes = try JSONEncoder().encode(manifest)
        let resources = desktop.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try bytes.write(to: resources.appendingPathComponent(RuntimeComponentManifest.fileName))
        try Data((try (signer ?? key).signature(for: bytes)).base64EncodedString().utf8).write(
            to: resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName))
        desktopRelease = (manifest.version, manifest.sourceRevision)
    }

    /// launchd started whatever is installed now.
    func launchInstalled() throws {
        let identity = try inspect(installedBundle)
        lock.withLock {
            _running = identity.helperSHA256
            _runningVersion = identity.version
        }
    }
    var running: String {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    /// The compiled-in release of the running helper.
    var runningVersion: String {
        get { lock.withLock { _runningVersion } ?? Self.source.version }
        set { lock.withLock { _runningVersion = newValue } }
    }
    var desktopRelease: (String, String) {
        get { lock.withLock { _desktop } ?? (Self.target.version, Self.target.revision) }
        set { lock.withLock { _desktop = newValue } }
    }
    func stop(at checkpoint: String?) { lock.withLock { _stopAt = checkpoint } }
    var copies: Int { lock.withLock { _copies.count } }
    var copySources: [URL] { lock.withLock { _copies } }
    var verifiedPaths: [URL] { lock.withLock { _verified } }
    var swappedPaths: [URL] { lock.withLock { _swaps } }

    func offered() throws -> RuntimeComponentOffer {
        let resources = desktop.appendingPathComponent("Contents/Resources")
        return .init(
            manifest: try Data(contentsOf: resources.appendingPathComponent(RuntimeComponentManifest.fileName)),
            signature: try Data(
                contentsOf: resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName)),
            bundle: desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app"),
            desktopVersion: desktopRelease.0, desktopRevision: desktopRelease.1)
    }
    func secureCopy(_ source: URL, to destination: URL) throws {
        lock.withLock { _copies.append(source) }
        try RuntimeSecureCopy.copy(source, to: destination, owner: getuid(), group: group)
    }
    func isSealed(_ bundle: URL) -> Bool {
        (try? RuntimeSecureCopy.assertSealed(bundle, owner: getuid(), group: group)) != nil
    }
    func inspect(_ bundle: URL) throws -> RuntimeComponentBundle {
        try JSONDecoder().decode(
            RuntimeComponentBundle.self, from: Data(contentsOf: bundle.appendingPathComponent("identity.json")))
    }
    func verifyCode(_ bundle: URL, notarized: Bool) throws {
        lock.withLock { _verified.append(bundle) }
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("signed").path) else {
            throw MicropodError.message("not Micropod's sealed, notarized release")
        }
    }
    func probe(_ bundle: URL) throws -> RuntimeComponentProbe {
        let identity = try inspect(bundle)
        return .current(version: identity.version, revision: identity.revision)
    }
    func swap(_ a: URL, _ b: URL) throws {
        lock.withLock { _swaps.append(a) }
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    func runningHelperSHA256() throws -> String { running }
    func activeAPI(identity: IsolatedRuntimeIdentity) -> RuntimeComponentAPI? { api.active }
    func checkpoint(_ name: String) throws {
        if lock.withLock({ _stopAt == name }) { throw RuntimeComponentInterruption(checkpoint: name) }
    }

    /// The installed helper payload's bytes: what a rollback must restore.
    func installedPayload() throws -> Data {
        try Data(contentsOf: installedBundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"))
    }
}

final class RuntimeComponentUpdateTests: XCTestCase {
    private let selection = ManagedRuntimeLocation.Selection(
        version: AppleRuntimeRelease.supported.version, packageSHA256: AppleRuntimeRelease.supported.packageSHA256,
        incarnation: UUID())

    private func fixture() throws -> (RuntimeComponentUpdater, ComponentEnvironmentFixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rcu-" + UUID().uuidString)
        addTeardownBlock { try? RuntimeSecureCopy.remove(root) }
        let environment = try ComponentEnvironmentFixture(root: root.appendingPathComponent("host"))
        return (RuntimeComponentUpdater(environment: environment), environment)
    }

    private func plan(_ updater: RuntimeComponentUpdater, operation: UUID = UUID(), rollback: Bool = false) throws
        -> RuntimeComponentUpdateRecord
    {
        try updater.plan(
            operation: operation, ownerUID: 501, installedSelection: selection, runtime: nil, rollback: rollback)
    }

    private func stage(_ updater: RuntimeComponentUpdater, _ environment: ComponentEnvironmentFixture) throws
        -> RuntimeComponentUpdateRecord
    {
        let record = try plan(updater)
        XCTAssertEqual(record.phase, .staging)
        return try updater.stageAndSwap(record, installedSelection: selection)
    }

    /// Swap, relaunch, confirm, and finish with the runtime already following.
    private func complete(_ updater: RuntimeComponentUpdater, _ environment: ComponentEnvironmentFixture) throws
        -> RuntimeComponentUpdateRecord
    {
        _ = try stage(updater, environment)
        try environment.launchInstalled()
        _ = updater.launch()
        try updater.confirmTarget()
        var record = try XCTUnwrap(updater.read())
        try updater.finishWithoutRestart(&record)
        return record
    }

    func testUpdateSwapsInTheVerifiedTargetAndRetainsTheExactPreviousBytes() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        let swapped = try stage(updater, environment)
        XCTAssertEqual(swapped.phase, .relaunching)
        XCTAssertEqual(try environment.inspect(environment.installedBundle), ComponentEnvironmentFixture.target)
        XCTAssertTrue(environment.isSealed(environment.installedBundle), "The installed bundle is a sealed copy")
        XCTAssertTrue(environment.isSealed(updater.verified(swapped.operation)))
        let retained = updater.previous(swapped.operation)
        XCTAssertEqual(
            try Data(contentsOf: retained.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")), before)

        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .proceedUnconfirmed, "The watchdog is armed until the helper serves")
        XCTAssertEqual(try updater.read()?.phase, .relaunching)
        XCTAssertEqual(try updater.read()?.targetLaunches, 1)
        XCTAssertTrue(try updater.confirmTarget())
        XCTAssertEqual(try updater.read()?.phase, .helperReady)
        XCTAssertEqual(updater.state().highestVersion, "0.13.10")
        XCTAssertEqual(try updater.verifiedSource(XCTUnwrap(updater.read())), updater.verified(swapped.operation))
    }

    // A helper killed after recording its swap intent but before renamex_np:
    // the next launch finds the old bytes installed and running, and settles.
    func testHostKilledBeforeTheSwapSettlesWithNothingChanged() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        environment.stop(at: "swapping")
        XCTAssertThrowsError(try stage(updater, environment))
        XCTAssertEqual(try updater.read()?.phase, .swapping)

        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .proceed)
        let settled = try XCTUnwrap(updater.read())
        XCTAssertEqual(settled.phase, .refused)
        XCTAssertEqual(try environment.installedPayload(), before)
        XCTAssertEqual(try environment.inspect(environment.installedBundle), ComponentEnvironmentFixture.source)
    }

    // Killed between renamex_np and moving the displaced bundle aside: the
    // target is installed, launchd starts it, and the previous bytes are
    // retained, moved aside without being read.
    func testHostKilledMidSwapResumesFromWhatIsInstalled() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        environment.stop(at: "swapped")
        XCTAssertThrowsError(try stage(updater, environment))
        let record = try XCTUnwrap(updater.read())
        XCTAssertEqual(record.phase, .swapping)

        try environment.launchInstalled()
        XCTAssertEqual(environment.running, ComponentEnvironmentFixture.target.helperSHA256)
        XCTAssertEqual(updater.launch(), .proceedUnconfirmed)
        try updater.confirmTarget()
        XCTAssertEqual(try updater.read()?.phase, .helperReady)
        let retained = updater.previous(record.operation).appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")
        XCTAssertEqual(try Data(contentsOf: retained), before)
    }

    // A new helper that keeps crashing (or hanging, past the watchdog) before
    // it serves is swapped back after three launches. The retained bytes are
    // secure-copied first and the copy, never the retained path, is verified
    // and swapped.
    func testCrashLoopingTargetRollsBackFromASealedCopyOfThePreviousBytes() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        let swapped = try stage(updater, environment)
        for _ in 0..<RuntimeComponentUpdater.maximumTargetLaunches {
            try environment.launchInstalled()
            XCTAssertEqual(updater.launch(), .proceedUnconfirmed)
        }
        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .relaunch)
        XCTAssertEqual(try updater.read()?.phase, .rollingBack)
        XCTAssertEqual(try environment.installedPayload(), before)
        XCTAssertTrue(environment.isSealed(environment.installedBundle), "The restored bundle is a sealed copy")
        let retained = updater.previous(swapped.operation)
        XCTAssertFalse(environment.verifiedPaths.contains(retained), "Retained bytes are never verified in place")
        XCTAssertFalse(environment.swappedPaths.contains(retained), "Retained bytes are never swapped in place")

        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .proceed)
        XCTAssertEqual(try XCTUnwrap(updater.read()).phase, .rolledBack)
    }

    func testInterruptedRollbackStillSettles() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        _ = try stage(updater, environment)
        for _ in 0..<RuntimeComponentUpdater.maximumTargetLaunches {
            try environment.launchInstalled()
            _ = updater.launch()
        }
        environment.stop(at: "rolledBackSwap")
        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .proceed, "The interruption is recorded, not fatal")
        environment.stop(at: nil)
        try environment.launchInstalled()
        _ = updater.launch()
        XCTAssertEqual(try environment.installedPayload(), before)
        XCTAssertEqual(try XCTUnwrap(updater.read()).phase, .rolledBack)
    }

    func testAManifestNotSignedByTheReleaseKeyChangesNothing() throws {
        let (updater, environment) = try fixture()
        try environment.offer(ComponentEnvironmentFixture.target, signer: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try plan(updater)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("release key"), "\($0)")
        }
        XCTAssertNil(try updater.read())
        XCTAssertEqual(environment.copies, 0)
    }

    // L2: a validly signed manifest from another release, replayed into this
    // desktop app, is refused.
    func testAManifestThatIsNotTheInstalledAppsOwnIsRefused() throws {
        let (updater, environment) = try fixture()
        environment.desktopRelease = ("0.14.0", String(repeating: "f", count: 40))
        XCTAssertThrowsError(try plan(updater)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("not the installed app's own"), "\($0)")
        }
    }

    func testABundleThatDoesNotMatchItsManifestIsRefusedBeforeTheSwap() throws {
        let (updater, environment) = try fixture()
        let forged = ComponentEnvironmentFixture.bundle("0.13.10", "a", cdhash: "f", helper: "c", api: "e")
        try environment.offer(ComponentEnvironmentFixture.target)
        try ComponentEnvironmentFixture.makeBundle(
            environment.desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app"), forged)
        XCTAssertThrowsError(try stage(updater, environment))
        XCTAssertEqual(try updater.read()?.phase, .refused)
        XCTAssertEqual(try environment.inspect(environment.installedBundle), ComponentEnvironmentFixture.source)

        let unsigned = try fixture()
        try unsigned.1.offer(ComponentEnvironmentFixture.target, signed: false)
        XCTAssertThrowsError(try stage(unsigned.0, unsigned.1))
        XCTAssertEqual(try unsigned.0.read()?.phase, .refused)
    }

    // H1: an ACL granting write to everyone, an extended attribute, a flag
    // and a setuid bit planted in the offered bundle do not survive into the
    // copy root verifies and installs.
    func testPlantedACLsAttributesFlagsAndSetuidDoNotReachTheInstalledCopy() throws {
        let (updater, environment) = try fixture()
        let offered = environment.desktop.appendingPathComponent(
            "Contents/Helpers/Micropod Runtime Setup.app/Contents/MacOS/MicropodRuntimeHost")
        try RuntimeSecureCopyTests.plant(offered)
        let swapped = try stage(updater, environment)
        XCTAssertEqual(swapped.phase, .relaunching)
        let installed = environment.installedBundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")
        try RuntimeSecureCopyTests.assertClean(installed)
        XCTAssertTrue(environment.isSealed(environment.installedBundle))
        XCTAssertTrue(environment.isSealed(updater.verified(swapped.operation)))
    }

    // L4: the definition root approved is compared, not the writable plist.
    func testAChangedLaunchdDefinitionNeedsSetupInsteadOfASelfUpdate() throws {
        let (updater, environment) = try fixture()
        let changed = ComponentEnvironmentFixture.bundle(
            "0.13.10", "a", cdhash: "b", helper: "c", api: "e", definition: "7")
        try environment.offer(changed)
        XCTAssertThrowsError(try stage(updater, environment)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("launchd definition"), "\($0)")
        }
        XCTAssertEqual(try environment.inspect(environment.installedBundle), ComponentEnvironmentFixture.source)

        // An attacker edits the installed plist to match the new definition:
        // root's approved record still refuses it.
        let (other, otherEnvironment) = try fixture()
        try other.raise(version: nil, floor: nil, definition: String(repeating: "5", count: 64))
        let edited = ComponentEnvironmentFixture.bundle(
            "0.13.9", "9", cdhash: "1", helper: "2", api: "3", definition: "7")
        try ComponentEnvironmentFixture.makeBundle(otherEnvironment.installedBundle, edited)
        try otherEnvironment.offer(changed)
        XCTAssertThrowsError(try stage(other, otherEnvironment))
    }

    // M1: the helper's compiled-in release decides, not a plist in the
    // writable bundle; an unknown release fails closed; the root-held
    // high-water mark refuses anything older than what this host ran.
    func testDowngradeChecksUseTheRunningReleaseAndARootHeldHighWaterMark() throws {
        let (updater, environment) = try fixture()
        let forged = ComponentEnvironmentFixture.bundle("99.0.0", "9", cdhash: "1", helper: "2", api: "3")
        try ComponentEnvironmentFixture.makeBundle(environment.installedBundle, forged)
        XCTAssertEqual(try plan(updater).phase, .staging, "A forged installed version changes nothing")

        let (unknown, unknownEnvironment) = try fixture()
        unknownEnvironment.runningVersion = "dev"
        XCTAssertThrowsError(try plan(unknown)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("unknown"), "\($0)")
        }

        let (marked, markedEnvironment) = try fixture()
        try marked.raise(version: "0.14.0", floor: nil, definition: nil)
        XCTAssertThrowsError(try plan(marked)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("highest installed"), "\($0)")
        }
        XCTAssertEqual(markedEnvironment.copies, 0)
    }

    // M2: a signed security floor, once installed, is enforced by root on
    // every later update and rollback.
    func testASignedSecurityFloorRefusesARollbackBelowIt() throws {
        let (updater, environment) = try fixture()
        try environment.offer(
            ComponentEnvironmentFixture.target,
            manifest: ComponentEnvironmentFixture.manifest(ComponentEnvironmentFixture.target, securityFloor: "0.13.10")
        )
        XCTAssertEqual(try complete(updater, environment).phase, .completed)
        XCTAssertEqual(updater.state().securityFloor, "0.13.10")
        XCTAssertThrowsError(try plan(updater, rollback: true)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("security floor"), "\($0)")
        }
    }

    func testReplaysAndUnmanageableRuntimesAreRefused() throws {
        let (updater, environment) = try fixture()
        let other = ManagedRuntimeLocation.Selection(
            version: "1.5.0", packageSHA256: String(repeating: "0", count: 64), incarnation: UUID())
        XCTAssertThrowsError(
            try updater.plan(
                operation: UUID(), ownerUID: 501, installedSelection: other, runtime: nil, rollback: false)
        ) { XCTAssertTrue("\($0.localizedDescription)".contains("cannot manage"), "\($0)") }

        let refused = try plan(updater)
        environment.stop(at: "staging")
        XCTAssertThrowsError(try updater.stageAndSwap(refused, installedSelection: selection))
        try environment.launchInstalled()
        _ = updater.launch()
        XCTAssertEqual(try updater.read()?.phase, .refused)
        // A lost reply: the same operation answers with its outcome, once.
        XCTAssertEqual(try plan(updater, operation: refused.operation).phase, .refused)
        XCTAssertEqual(environment.copies, 0)
        environment.stop(at: nil)
        _ = try complete(updater, environment)
        XCTAssertThrowsError(try plan(updater, operation: refused.operation)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("already recorded"), "\($0)")
        }
    }

    // H4: when the running helper already is the offered release, an update
    // re-seats it: a sealed copy of the verified bytes replaces whatever is
    // installed (here a user-owned bundle with an ACL), with no relaunch.
    func testTheRunningReleaseIsReseatedAsASealedCopyWithoutARelaunch() throws {
        let (updater, environment) = try fixture()
        try ComponentEnvironmentFixture.makeBundle(environment.installedBundle, ComponentEnvironmentFixture.target)
        try RuntimeSecureCopyTests.plant(environment.installedBundle.appendingPathComponent("identity.json"))
        try environment.launchInstalled()
        XCTAssertFalse(environment.isSealed(environment.installedBundle))
        let record = try plan(updater)
        XCTAssertTrue(record.reseat)
        let reseated = try updater.stageAndSwap(record, installedSelection: selection)
        XCTAssertEqual(reseated.phase, .helperReady, "Same bytes: no relaunch")
        XCTAssertTrue(environment.isSealed(environment.installedBundle))
        XCTAssertEqual(
            environment.copySources.first,
            environment.desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app"),
            "Re-seated from the signed release, not from the installed bundle")
        XCTAssertNoThrow(try updater.verifiedSource(reseated))
        XCTAssertThrowsError(try plan(updater, rollback: true), "A re-seat retains nothing to roll back to")
    }

    // H2: the runtime is staged only from root's sealed copy of the verified
    // target; a copy that changed or is missing stops the update.
    func testTheVerifiedCopyIsCheckedBeforeTheRuntimeIsStagedFromIt() throws {
        let (updater, environment) = try fixture()
        let swapped = try stage(updater, environment)
        try environment.launchInstalled()
        _ = updater.launch()
        try updater.confirmTarget()
        let record = try XCTUnwrap(updater.read())
        XCTAssertNoThrow(try updater.verifiedSource(record))
        try ComponentEnvironmentFixture.makeBundle(
            updater.verified(swapped.operation),
            ComponentEnvironmentFixture.bundle("0.13.10", "a", cdhash: "b", helper: "d", api: "e"))
        XCTAssertThrowsError(try updater.verifiedSource(record))
        try RuntimeSecureCopy.remove(updater.verified(swapped.operation))
        XCTAssertThrowsError(try updater.verifiedSource(record))
    }

    // H2: `completed` stands only when the restarted runtime runs exactly
    // the target's worker and API.
    func testACompletedRestartOnOtherBytesIsNotACompletedUpdate() throws {
        let (updater, environment) = try fixture()
        _ = try stage(updater, environment)
        try environment.launchInstalled()
        _ = updater.launch()
        try updater.confirmTarget()
        var record = try XCTUnwrap(updater.read())
        let restart = UUID()
        try updater.beginRuntime(&record, operation: restart, previous: nil)
        var status = IsolatedRuntimeStatus(phase: "completed", message: "")
        status.operation = restart
        status.workerSHA256 = ComponentEnvironmentFixture.target.helperSHA256
        let wrong = RuntimeComponentAPI(executableSHA256: String(repeating: "9", count: 64), guestSHA256: nil)
        try updater.followRuntime(status, activeAPI: wrong)
        XCTAssertEqual(try updater.read()?.phase, .recoveryRequired)
    }

    // M3: a FIFO planted where a file is read never wedges the root helper.
    func testAFIFOInPlaceOfAFileIsRefusedWithoutBlocking() throws {
        let (updater, environment) = try fixture()
        let plist = environment.desktop.appendingPathComponent("Contents/Resources")
            .appendingPathComponent(RuntimeComponentManifest.fileName)
        try FileManager.default.removeItem(at: plist)
        XCTAssertEqual(mkfifo(plist.path, 0o644), 0)
        let started = Date()
        XCTAssertThrowsError(try RuntimeNonblockingFile.read(plist, limit: 1024))
        XCTAssertThrowsError(try ManagedRuntimeInstaller.sha256(plist))
        XCTAssertThrowsError(try RuntimeDurableFile.read(plist, maximumBytes: 1024))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        _ = updater
    }

    // M6: an undecodable journal is read leniently: it blocks only an update.
    func testAnUnreadableJournalBlocksOnlyAnUpdate() throws {
        let (updater, _) = try fixture()
        try FileManager.default.createDirectory(
            at: updater.journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: updater.journal)
        XCTAssertNil(updater.readLeniently())
        XCTAssertNil(updater.summary())
        XCTAssertEqual(updater.launch(), .proceed)
        XCTAssertThrowsError(try plan(updater))
    }

    // An explicit rollback restores exactly the bytes the last update
    // replaced, from a sealed copy, through the same swap, launch and settle.
    func testRollbackRestoresTheRetainedBytes() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        XCTAssertEqual(try complete(updater, environment).phase, .completed)
        let rollback = try plan(updater, rollback: true)
        XCTAssertEqual(rollback.phase, .staging, "The runtime never moved, so nothing to restore first")
        XCTAssertEqual(rollback.target, ComponentEnvironmentFixture.source)
        let swapped = try updater.stageAndSwap(rollback, installedSelection: selection)
        XCTAssertEqual(swapped.phase, .relaunching)
        XCTAssertEqual(try environment.installedPayload(), before)
        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .proceedUnconfirmed)
        try updater.confirmTarget()
        XCTAssertEqual(try updater.read()?.phase, .helperReady)
        XCTAssertEqual(updater.state().highestVersion, "0.13.10", "A rollback never lowers the mark")
    }

    // M7: a rollback whose runtime moved restores the runtime first.
    func testARollbackWhoseRuntimeMovedRestoresTheRuntimeFirst() throws {
        let (updater, environment) = try fixture()
        _ = try stage(updater, environment)
        try environment.launchInstalled()
        _ = updater.launch()
        try updater.confirmTarget()
        var record = try XCTUnwrap(updater.read())
        let previous = RuntimeComponentRuntime(
            selection: selection, workerSHA256: ComponentEnvironmentFixture.source.helperSHA256,
            api: .init(executableSHA256: ComponentEnvironmentFixture.source.apiSHA256, guestSHA256: nil))
        try updater.beginRuntime(&record, operation: UUID(), previous: previous)
        try updater.finishWithoutRestart(&record)
        let moved = RuntimeComponentRuntime(
            selection: selection, workerSHA256: ComponentEnvironmentFixture.target.helperSHA256,
            api: .init(executableSHA256: ComponentEnvironmentFixture.target.apiSHA256, guestSHA256: nil))
        let rollback = try updater.plan(
            operation: UUID(), ownerUID: 501, installedSelection: selection, runtime: moved, rollback: true)
        XCTAssertEqual(rollback.phase, .restoringRuntime)
        XCTAssertEqual(rollback.previousRuntime, previous)
    }
}

/// H1: ``RuntimeSecureCopy`` on real files (owned by this account).
final class RuntimeSecureCopyTests: XCTestCase {
    static func plant(_ file: URL) throws {
        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow write,append,writeattr,writeextattr", file.path]
        try acl.run()
        acl.waitUntilExit()
        XCTAssertEqual(acl.terminationStatus, 0)
        XCTAssertEqual(setxattr(file.path, "com.example.planted", "x", 1, 0, XATTR_NOFOLLOW), 0)
        XCTAssertEqual(chmod(file.path, 0o4777), 0)
        XCTAssertEqual(chflags(file.path, UInt32(UF_NODUMP)), 0)
    }

    static func assertClean(_ file: URL, file line: StaticString = #filePath, at number: UInt = #line) throws {
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7022, 0, "special bits or group/world write", file: line, line: number)
        XCTAssertEqual(info.st_flags, 0, "file flags", file: line, line: number)
        XCTAssertEqual(listxattr(file.path, nil, 0, XATTR_NOFOLLOW), 0, "extended attributes", file: line, line: number)
        if let acl = acl_get_link_np(file.path, ACL_TYPE_EXTENDED) {
            var entry: acl_entry_t?
            XCTAssertNotEqual(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), 0, "ACL", file: line, line: number)
            acl_free(UnsafeMutableRawPointer(acl))
        }
    }

    private func tree() throws -> (URL, gid_t) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rsc-" + UUID().uuidString)
        addTeardownBlock { try? RuntimeSecureCopy.remove(root) }
        let bundle = root.appendingPathComponent("source/Setup.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("executable".utf8).write(to: bundle.appendingPathComponent("Contents/MacOS/Helper"))
        try Data("plist".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(chmod(bundle.appendingPathComponent("Contents/MacOS/Helper").path, 0o755), 0)
        var info = stat()
        XCTAssertEqual(lstat(root.path, &info), 0)
        return (bundle, info.st_gid)
    }

    func testAPrePlantedACLAttributeFlagAndSetuidAreStrippedAndProvedGone() throws {
        let (bundle, group) = try tree()
        let helper = bundle.appendingPathComponent("Contents/MacOS/Helper")
        try Self.plant(helper)
        XCTAssertEqual(chmod(bundle.appendingPathComponent("Contents/Info.plist").path, 0o666), 0)
        let copy = bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "copy/Setup.app")
        try RuntimeSecureCopy.copy(bundle, to: copy, owner: getuid(), group: group)
        try Self.assertClean(copy.appendingPathComponent("Contents/MacOS/Helper"))
        try Self.assertClean(copy.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNoThrow(try RuntimeSecureCopy.assertSealed(copy, owner: getuid(), group: group))
        var info = stat()
        XCTAssertEqual(lstat(copy.appendingPathComponent("Contents/MacOS/Helper").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755, "An executable stays executable")
    }

    func testTheSealCheckCatchesAnACLAddedAfterTheCopy() throws {
        let (bundle, group) = try tree()
        let copy = bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "copy/Setup.app")
        try RuntimeSecureCopy.copy(bundle, to: copy, owner: getuid(), group: group)
        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow write", copy.appendingPathComponent("Contents/Info.plist").path]
        try acl.run()
        acl.waitUntilExit()
        XCTAssertThrowsError(try RuntimeSecureCopy.assertSealed(copy, owner: getuid(), group: group)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("ACL"), "\($0)")
        }
    }

    func testFIFOsLinksAndOversizedTreesAreRefusedBeforeAnythingIsCopied() throws {
        let (bundle, group) = try tree()
        let copy = bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "copy/Setup.app")
        XCTAssertEqual(mkfifo(bundle.appendingPathComponent("Contents/pipe").path, 0o644), 0)
        XCTAssertThrowsError(try RuntimeSecureCopy.copy(bundle, to: copy, owner: getuid(), group: group))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/pipe"))
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Contents/link").path, withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try RuntimeSecureCopy.copy(bundle, to: copy, owner: getuid(), group: group))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/link"))
        XCTAssertThrowsError(
            try RuntimeSecureCopy.copy(bundle, to: copy, owner: getuid(), group: group, limits: .init(entries: 2)))
        XCTAssertNoThrow(try RuntimeSecureCopy.copy(bundle, to: copy, owner: getuid(), group: group))
    }

    func testAnImmutableEntryLeavesNoLeftovers() throws {
        let (bundle, group) = try tree()
        let copy = bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "copy/Setup.app")
        try RuntimeSecureCopy.copy(bundle, to: copy, owner: getuid(), group: group)
        XCTAssertEqual(chflags(copy.appendingPathComponent("Contents/Info.plist").path, UInt32(UF_IMMUTABLE)), 0)
        try RuntimeSecureCopy.remove(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }
}
