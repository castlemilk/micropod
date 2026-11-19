import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodRuntimeHostKit

/// Real directories and real `renamex_np` swaps; only code signing, the
/// probe, notarization and "which helper launchd started" are simulated.
/// A bundle is a directory with `identity.json` (what `inspect` reports), a
/// helper payload whose bytes stand in for the executable, and `signed`.
final class ComponentEnvironmentFixture: RuntimeComponentEnvironment, @unchecked Sendable {
    let root: URL
    let installedBundle: URL
    let desktop: URL
    let key = Curve25519.Signing.PrivateKey()
    private let lock = NSLock()
    private var _running: String
    private var _stopAt: String?
    private var _copies = 0
    private var _apiSHA256: String?
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    static let source = RuntimeComponentBundle(
        version: "0.13.9", revision: String(repeating: "9", count: 40), cdhash: String(repeating: "1", count: 40),
        helperSHA256: String(repeating: "2", count: 64), apiSHA256: String(repeating: "3", count: 64),
        guestSHA256: nil, daemonPlistSHA256: String(repeating: "4", count: 64),
        daemonDefinitionSHA256: String(repeating: "5", count: 64))
    static let target = RuntimeComponentBundle(
        version: "0.13.10", revision: String(repeating: "a", count: 40), cdhash: String(repeating: "b", count: 40),
        helperSHA256: String(repeating: "c", count: 64), apiSHA256: String(repeating: "e", count: 64),
        guestSHA256: nil, daemonPlistSHA256: String(repeating: "4", count: 64),
        daemonDefinitionSHA256: String(repeating: "5", count: 64))

    init(root: URL) throws {
        self.root = root
        installedBundle = root.appendingPathComponent("Applications/Micropod Runtime Setup.app")
        desktop = root.appendingPathComponent("Applications/Micropod.app")
        _running = Self.source.helperSHA256
        try Self.makeBundle(installedBundle, Self.source)
        try offer(Self.target)
    }

    static func makeBundle(_ url: URL, _ identity: RuntimeComponentBundle, signed: Bool = true) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: url.appendingPathComponent("identity.json"))
        try Data(("helper " + identity.helperSHA256).utf8).write(
            to: url.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"))
        if signed { try Data().write(to: url.appendingPathComponent("signed")) }
    }

    /// Puts `identity` inside the desktop app with a manifest signed by `signer`.
    func offer(
        _ identity: RuntimeComponentBundle, signed: Bool = true, signer: Curve25519.Signing.PrivateKey? = nil,
        manifest override: RuntimeComponentManifest? = nil
    ) throws {
        try Self.makeBundle(
            desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app"), identity, signed: signed)
        let manifest =
            override
            ?? RuntimeComponentManifest(
                version: identity.version, sourceRevision: identity.revision, minimumHelperVersion: "0.13.9",
                setup: .init(
                    bundleIdentifier: IsolatedRuntimePolicy.setupIdentifier, cdhash: identity.cdhash,
                    daemonPlistSHA256: identity.daemonPlistSHA256),
                helper: .init(identifier: IsolatedRuntimePolicy.helperIdentifier, sha256: identity.helperSHA256),
                api: .init(
                    identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier, sha256: identity.apiSHA256),
                guestSHA256: identity.guestSHA256,
                appleRuntime: .init(
                    version: AppleRuntimeRelease.supported.version,
                    packageSHA256: AppleRuntimeRelease.supported.packageSHA256),
                appleRuntimes: [
                    .init(
                        version: AppleRuntimeRelease.supported.version,
                        packageSHA256: AppleRuntimeRelease.supported.packageSHA256)
                ])
        let bytes = try JSONEncoder().encode(manifest)
        let resources = desktop.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try bytes.write(to: resources.appendingPathComponent(RuntimeComponentManifest.fileName))
        try Data((try (signer ?? key).signature(for: bytes)).base64EncodedString().utf8).write(
            to: resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName))
    }

    /// launchd started whatever is installed now.
    func launchInstalled() throws { running = try inspect(installedBundle).helperSHA256 }
    var running: String {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    func stop(at checkpoint: String?) { lock.withLock { _stopAt = checkpoint } }
    var copies: Int { lock.withLock { _copies } }
    var apiSHA256: String? {
        get { lock.withLock { _apiSHA256 } }
        set { lock.withLock { _apiSHA256 = newValue } }
    }

    func offered() throws -> RuntimeComponentOffer {
        let resources = desktop.appendingPathComponent("Contents/Resources")
        return .init(
            manifest: try Data(contentsOf: resources.appendingPathComponent(RuntimeComponentManifest.fileName)),
            signature: try Data(
                contentsOf: resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName)),
            bundle: desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app"))
    }
    func copyBundle(_ source: URL, to destination: URL) throws {
        lock.withLock { _copies += 1 }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func inspect(_ bundle: URL) throws -> RuntimeComponentBundle {
        try JSONDecoder().decode(
            RuntimeComponentBundle.self, from: Data(contentsOf: bundle.appendingPathComponent("identity.json")))
    }
    func verifyCode(_ bundle: URL, notarized: Bool) throws {
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("signed").path) else {
            throw MicropodError.message("not Micropod's sealed, notarized release")
        }
    }
    func probe(_ bundle: URL) throws -> RuntimeComponentProbe {
        let identity = try inspect(bundle)
        return .current(version: identity.version, revision: identity.revision)
    }
    func swap(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    func runningHelperSHA256() throws -> String { running }
    func activeAPISHA256(identity: IsolatedRuntimeIdentity) -> String? { apiSHA256 }
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
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let environment = try ComponentEnvironmentFixture(root: root.appendingPathComponent("host"))
        return (RuntimeComponentUpdater(environment: environment), environment)
    }

    private func stage(_ updater: RuntimeComponentUpdater, _ environment: ComponentEnvironmentFixture) throws
        -> RuntimeComponentUpdateRecord
    {
        let record = try updater.plan(operation: UUID(), ownerUID: 501, installedSelection: selection, rollback: false)
        XCTAssertEqual(record.phase, .staging)
        return try updater.stageAndSwap(record, installedSelection: selection)
    }

    func testUpdateSwapsInTheVerifiedTargetAndRetainsTheExactPreviousBytes() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        let swapped = try stage(updater, environment)
        XCTAssertEqual(swapped.phase, .relaunching)
        XCTAssertEqual(try environment.inspect(environment.installedBundle), ComponentEnvironmentFixture.target)
        let retained = updater.previous(swapped.operation)
        XCTAssertEqual(
            try Data(contentsOf: retained.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")), before)

        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .proceed)
        XCTAssertEqual(try updater.read()?.phase, .relaunching, "Not ready until the new helper serves")
        XCTAssertEqual(try updater.read()?.targetLaunches, 1)
        try updater.confirmTarget()
        XCTAssertEqual(try updater.read()?.phase, .helperReady)
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
        XCTAssertTrue(settled.phase.isTerminal)
        XCTAssertEqual(try environment.installedPayload(), before)
        XCTAssertEqual(try environment.inspect(environment.installedBundle), ComponentEnvironmentFixture.source)
    }

    // Killed between renamex_np and moving the displaced bundle aside: the
    // target is installed, launchd starts it, and the previous bytes are
    // still retained for a rollback.
    func testHostKilledMidSwapResumesFromWhatIsInstalled() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        environment.stop(at: "swapped")
        XCTAssertThrowsError(try stage(updater, environment))
        let record = try XCTUnwrap(updater.read())
        XCTAssertEqual(record.phase, .swapping)

        try environment.launchInstalled()
        XCTAssertEqual(environment.running, ComponentEnvironmentFixture.target.helperSHA256)
        XCTAssertEqual(updater.launch(), .proceed)
        try updater.confirmTarget()
        XCTAssertEqual(try updater.read()?.phase, .helperReady)
        let retained = updater.previous(record.operation).appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")
        XCTAssertEqual(try Data(contentsOf: retained), before)
    }

    // A new helper that keeps crashing before it serves is swapped back after
    // three launches, and the previous helper then settles the update.
    func testCrashLoopingTargetRollsBackToTheExactPreviousBytes() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        let swapped = try stage(updater, environment)
        for _ in 0..<RuntimeComponentUpdater.maximumTargetLaunches {
            try environment.launchInstalled()
            XCTAssertEqual(updater.launch(), .proceed)
            // ...and it crashes before confirmTarget().
        }
        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .relaunch)
        XCTAssertEqual(try updater.read()?.phase, .rollingBack)
        XCTAssertEqual(try environment.installedPayload(), before)

        try environment.launchInstalled()
        XCTAssertEqual(environment.running, ComponentEnvironmentFixture.source.helperSHA256)
        XCTAssertEqual(updater.launch(), .proceed)
        let settled = try XCTUnwrap(updater.read())
        XCTAssertEqual(settled.phase, .rolledBack)
        XCTAssertEqual(settled.operation, swapped.operation)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: updater.rejected(swapped.operation).path),
            "The rejected target is kept for inspection")
    }

    // Killed during the rollback's own swap: inspection redoes or finishes it.
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
        try environment.launchInstalled()
        _ = updater.launch()
        XCTAssertEqual(try environment.installedPayload(), before)
        XCTAssertEqual(try XCTUnwrap(updater.read()).phase, .rolledBack)
    }

    func testAManifestNotSignedByTheReleaseKeyChangesNothing() throws {
        let (updater, environment) = try fixture()
        try environment.offer(ComponentEnvironmentFixture.target, signer: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(
            try updater.plan(operation: UUID(), ownerUID: 501, installedSelection: selection, rollback: false)
        ) { XCTAssertTrue("\($0.localizedDescription)".contains("release key"), "\($0)") }
        XCTAssertNil(try updater.read())
        XCTAssertEqual(environment.copies, 0)
    }

    func testABundleThatDoesNotMatchItsManifestIsRefusedBeforeTheSwap() throws {
        let (updater, environment) = try fixture()
        var forged = ComponentEnvironmentFixture.target
        forged = .init(
            version: forged.version, revision: forged.revision, cdhash: String(repeating: "f", count: 40),
            helperSHA256: forged.helperSHA256, apiSHA256: forged.apiSHA256, guestSHA256: nil,
            daemonPlistSHA256: forged.daemonPlistSHA256, daemonDefinitionSHA256: forged.daemonDefinitionSHA256)
        // The manifest pins the real target; the bundle beside it is another build.
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

    func testAChangedLaunchdDefinitionNeedsSetupInsteadOfASelfUpdate() throws {
        let (updater, environment) = try fixture()
        let changed = RuntimeComponentBundle(
            version: "0.13.10", revision: String(repeating: "a", count: 40), cdhash: String(repeating: "b", count: 40),
            helperSHA256: String(repeating: "c", count: 64), apiSHA256: String(repeating: "e", count: 64),
            guestSHA256: nil, daemonPlistSHA256: String(repeating: "6", count: 64),
            daemonDefinitionSHA256: String(repeating: "7", count: 64))
        try environment.offer(changed)
        XCTAssertThrowsError(try stage(updater, environment)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("launchd definition"), "\($0)")
        }
        XCTAssertEqual(try environment.inspect(environment.installedBundle), ComponentEnvironmentFixture.source)
    }

    func testDowngradesReplaysAndUnmanageableRuntimesAreRefused() throws {
        let (updater, environment) = try fixture()
        let older = RuntimeComponentBundle(
            version: "0.13.8", revision: String(repeating: "8", count: 40), cdhash: String(repeating: "7", count: 40),
            helperSHA256: String(repeating: "6", count: 64), apiSHA256: String(repeating: "3", count: 64),
            guestSHA256: nil, daemonPlistSHA256: String(repeating: "4", count: 64),
            daemonDefinitionSHA256: String(repeating: "5", count: 64))
        try environment.offer(older)
        XCTAssertThrowsError(
            try updater.plan(operation: UUID(), ownerUID: 501, installedSelection: selection, rollback: false))

        try environment.offer(ComponentEnvironmentFixture.target)
        let other = ManagedRuntimeLocation.Selection(
            version: "1.5.0", packageSHA256: String(repeating: "0", count: 64), incarnation: UUID())
        XCTAssertThrowsError(
            try updater.plan(operation: UUID(), ownerUID: 501, installedSelection: other, rollback: false)
        ) { XCTAssertTrue("\($0.localizedDescription)".contains("cannot manage"), "\($0)") }

        let refused = try updater.plan(operation: UUID(), ownerUID: 501, installedSelection: selection, rollback: false)
        environment.stop(at: "staging")
        XCTAssertThrowsError(try updater.stageAndSwap(refused, installedSelection: selection))
        try environment.launchInstalled()
        _ = updater.launch()
        XCTAssertEqual(try updater.read()?.phase, .refused)
        // A lost reply: the same operation answers with its outcome, once.
        let again = try updater.plan(
            operation: refused.operation, ownerUID: 501, installedSelection: selection, rollback: false)
        XCTAssertEqual(again.phase, .refused)
        XCTAssertEqual(environment.copies, 0)
        // Once another update replaced it, the ID can never start anything.
        environment.stop(at: nil)
        let next = try updater.plan(operation: UUID(), ownerUID: 501, installedSelection: selection, rollback: false)
        _ = try updater.stageAndSwap(next, installedSelection: selection)
        try environment.launchInstalled()
        _ = updater.launch()
        try updater.confirmTarget()
        var finished = try XCTUnwrap(updater.read())
        try updater.finishWithoutRestart(&finished)
        XCTAssertThrowsError(
            try updater.plan(
                operation: refused.operation, ownerUID: 501, installedSelection: selection, rollback: false)
        ) { XCTAssertTrue("\($0.localizedDescription)".contains("already recorded"), "\($0)") }
    }

    // An explicit rollback restores exactly the bytes the last update
    // replaced, through the same swap, launch and settle.
    func testRollbackRestoresTheRetainedBytes() throws {
        let (updater, environment) = try fixture()
        let before = try environment.installedPayload()
        _ = try stage(updater, environment)
        try environment.launchInstalled()
        _ = updater.launch()
        try updater.confirmTarget()
        var record = try XCTUnwrap(updater.read())
        try updater.finishWithoutRestart(&record)
        XCTAssertEqual(record.phase, .completed)

        let rollback = try updater.plan(operation: UUID(), ownerUID: 501, installedSelection: selection, rollback: true)
        XCTAssertEqual(rollback.target, ComponentEnvironmentFixture.source)
        let swapped = try updater.stageAndSwap(rollback, installedSelection: selection)
        XCTAssertEqual(swapped.phase, .relaunching)
        XCTAssertEqual(try environment.installedPayload(), before)
        try environment.launchInstalled()
        XCTAssertEqual(updater.launch(), .proceed)
        try updater.confirmTarget()
        XCTAssertEqual(try updater.read()?.phase, .helperReady)
    }
}
