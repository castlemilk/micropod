import CryptoKit
import Foundation
import XCTest

@testable import MicropodCore

/// Mutable state shared between fakes, guarded by one lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    @discardableResult func update<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// A clock the engine's sleeps advance instantly.
final class TestClock: @unchecked Sendable {
    let time = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.get() }
    func advance(_ duration: Duration) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        time.update { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// launchd: which labels are loaded, and the definition each was loaded
/// with. A job keeps running what it was loaded with until it is reloaded,
/// whatever its plist says now.
final class FakeLaunchctl: RigLaunchControlling, @unchecked Sendable {
    struct Job: Equatable {
        let plist: URL
        let program: String
    }
    let loaded = Locked<[String: Job]>([:])
    let calls = Locked<[String]>([])
    let failBootstrap = Locked<Set<String>>([])
    /// Labels whose next bootout fails, once each.
    let failBootoutOnce = Locked<Set<String>>([])

    func load(_ label: String, _ plist: URL) {
        loaded.update { $0[label] = Job(plist: plist, program: RigUpgradeEngine.programPath(plist) ?? "") }
    }
    func isLoaded(_ label: String) async -> Bool { loaded.get()[label] != nil }
    func loadedProgram(_ label: String) async -> String? { loaded.get()[label]?.program }
    func bootout(_ label: String) async throws {
        calls.update { $0.append("bootout " + label) }
        let fail = failBootoutOnce.update { $0.remove(label) != nil }
        if fail { throw MicropodError.message("bootout \(label) timed out") }
        loaded.update { $0[label] = nil }
    }
    func bootstrap(_ plist: URL, label: String) async throws {
        calls.update { $0.append("bootstrap " + label) }
        if failBootstrap.get().contains(label) { throw MicropodError.message("bootstrap \(label) refused") }
        guard FileManager.default.fileExists(atPath: plist.path) else {
            throw MicropodError.message("no plist at \(plist.path)")
        }
        if loaded.get()[label]?.program == RigUpgradeEngine.programPath(plist) { return }
        load(label, plist)
    }
    func kickstart(_ label: String) async throws { calls.update { $0.append("kickstart " + label) } }
    /// The executable each loaded job runs.
    func executables() -> [String: String] { loaded.get().mapValues(\.program) }

    /// A reboot or re-login: launchd loads every agent on disk that runs at load.
    func reboot(launchAgents: URL) {
        loaded.update { $0 = [:] }
        for plist in (try? FileManager.default.contentsOfDirectory(at: launchAgents, includingPropertiesForKeys: nil))
            ?? []
        {
            guard let data = FileManager.default.contents(atPath: plist.path),
                let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let label = value["Label"] as? String, value["RunAtLoad"] as? Bool == true
            else { continue }
            load(label, plist)
        }
    }
}

/// The app: running or not, and which bundle's bytes it launched from.
final class FakeApp: RigAppControlling, @unchecked Sendable {
    let running = Locked<String?>(nil)
    let calls = Locked<[String]>([])
    /// Stops that fail before the app is stopped.
    let failStops = Locked(0)
    /// Runs as the app goes, before it is reported stopped (a Sparkle install on quit).
    let onStop = Locked<(@Sendable () -> Void)?>(nil)
    /// Real time each stop takes.
    let stopDelay = Locked<Duration>(.zero)
    func isRunning(_ app: URL) async -> Bool { running.get() != nil }
    func stop(_ app: URL, timeout: Duration) async throws {
        calls.update { $0.append("stop") }
        let delay = stopDelay.get()
        if delay > .zero { try await Task.sleep(for: delay) }
        let fail = failStops.update { value -> Bool in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
        if fail { throw MicropodError.message("the app did not exit") }
        if running.get() != nil,
            let hook = onStop.update({ value -> (@Sendable () -> Void)? in
                defer { value = nil }
                return value
            })
        {
            hook()
        }
        running.update { $0 = nil }
    }
    func launch(_ app: URL) async throws {
        calls.update { $0.append("launch") }
        let main = app.appendingPathComponent("Contents/MacOS/Micropod")
        let bytes = try String(contentsOf: main, encoding: .utf8)
        running.update { $0 = bytes }
    }
}

/// Cuttlefish: answers `waiting` until `drainAfter` calls (nil: never), then drained.
final class FakeDrain: RigDrainCoordinating, @unchecked Sendable {
    let configured: Bool
    let drainAfter: Int?
    let waiting: RigDrainReply.State
    let drains = Locked(0)
    let releases = Locked<[UUID]>([])
    let specs = Locked<Set<RigDrainSpec>>([])
    let releaseFails = Locked(false)
    init(configured: Bool = true, drainAfter: Int? = 1, waiting: RigDrainReply.State = .draining) {
        self.configured = configured
        self.drainAfter = drainAfter
        self.waiting = waiting
    }
    func isConfigured() -> Bool { configured }
    func drain(_ spec: RigDrainSpec) async -> RigDrainReply {
        specs.update { _ = $0.insert(spec) }
        let count = drains.update { value -> Int in
            value += 1
            return value
        }
        if waiting == .draining, let drainAfter, count >= drainAfter { return RigDrainReply(.drained) }
        return RigDrainReply(waiting, reason: "fake \(waiting.rawValue)")
    }
    func release(_ spec: RigDrainSpec) async throws -> RigDrainRelease {
        if releaseFails.get() { throw MicropodError.message("release unconfirmed") }
        releases.update { $0.append(spec.operation) }
        return .released
    }
}

/// Healthy when every loaded job and the app run bytes of the expected release.
final class FakeHealth: RigHealthProbing, @unchecked Sendable {
    let launch: FakeLaunchctl
    let app: FakeApp
    let failVersions = Locked<Set<String>>([])
    /// Versions whose Connect API does not answer.
    let connectDown = Locked<Set<String>>([])
    let smokes = Locked<[String]>([])
    let smokeFails = Locked(false)
    init(launch: FakeLaunchctl, app: FakeApp) {
        self.launch = launch
        self.app = app
    }
    func check(_ expectation: RigHealthExpectation) async -> RigHealthReport {
        var report = RigHealthReport(runtimeAvailable: true)
        if failVersions.get().contains(expectation.version) {
            report.failures.append("\(expectation.version) is configured to fail")
        }
        if expectation.connectRequired, connectDown.get().contains(expectation.version) {
            report.failures.append("The Connect API did not answer Ping")
        }
        for (label, executable) in launch.executables() {
            let bytes = (try? String(contentsOfFile: executable, encoding: .utf8)) ?? ""
            if !bytes.hasSuffix(" " + expectation.version) {
                report.failures.append("\(label) runs '\(bytes)', not \(expectation.version)")
            }
        }
        if expectation.appRunning, app.running.get() != "Micropod " + expectation.version {
            report.failures.append("the app runs '\(app.running.get() ?? "nothing")'")
        }
        return report
    }
    func smoke(_ expectation: RigHealthExpectation, image: String) async throws {
        smokes.update { $0.append(expectation.version) }
        if smokeFails.get() { throw MicropodError.message("smoke failed") }
    }
    func connectAnswers(port: UInt16) async -> Bool { true }
}

/// Stands in for codesign: a bundle carries a seal over all its files.
struct FakeVerifier: RigBundleVerifying {
    static func seal(_ bundle: URL) -> String {
        let fm = FileManager.default
        var hasher = SHA256()
        let files = (fm.enumerator(atPath: bundle.path)?.allObjects as? [String] ?? []).sorted()
        for file in files where file != "Contents/_CodeSignature/seal" {
            var isDirectory: ObjCBool = false
            let path = bundle.appendingPathComponent(file).path
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            hasher.update(data: Data(file.utf8))
            hasher.update(data: fm.contents(atPath: path) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func verifyApp(_ bundle: URL) throws {
        let stored = try? String(
            contentsOf: bundle.appendingPathComponent("Contents/_CodeSignature/seal"), encoding: .utf8)
        guard stored == Self.seal(bundle) else { throw MicropodError.message("\(bundle.path) is not sealed") }
    }
    func verifyExecutable(_ url: URL, identifier: String) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MicropodError.message("\(url.path) is not signed")
        }
    }
}

/// Stops an engine at the first visit of `target`, and lists every checkpoint.
final class CrashPlan: @unchecked Sendable {
    let target = Locked<String?>(nil)
    let seen = Locked<[String]>([])
    func visit(_ name: String) throws {
        seen.update { $0.append(name) }
        let hit = target.update { value -> Bool in
            guard value == name else { return false }
            value = nil
            return true
        }
        if hit { throw RigUpgradeInterruption(checkpoint: name) }
    }
}

/// A host with Micropod 0.14.0 installed, its retained docker-shim and
/// shared-fs on a 0.14.0 payload, a hand-installed Connect API, and 0.14.1
/// staged.
final class RigFixture: @unchecked Sendable {
    static let sourceRevision = String(repeating: "a", count: 40)
    static let targetRevision = String(repeating: "b", count: 40)
    let root: URL
    let layout: RigUpgradeLayout
    let launch = FakeLaunchctl()
    let app = FakeApp()
    let drain: FakeDrain
    let health: FakeHealth
    let clock = TestClock()
    let crash = CrashPlan()
    let running = Locked<[String]>([])
    let runtimeMaintenance = Locked(false)
    let installerRunning = Locked(false)
    var heartbeat: Duration = .seconds(20)
    let dedicated: Bool
    var staged: RigStagedRelease!
    var sourcePayload: URL!
    /// Every file the upgrade may replace, with its bytes before it.
    var originals: [String: Data] = [:]

    init(drain: FakeDrain = FakeDrain(), dedicated: Bool = false, connect: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rig-upgrade-" + UUID().uuidString)
        layout = RigUpgradeLayout(
            home: root.appendingPathComponent("home"), appPath: root.appendingPathComponent("Applications/Micropod.app")
        )
        self.drain = drain
        self.dedicated = dedicated
        health = FakeHealth(launch: launch, app: app)
        try build(connect: connect)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func makeBundle(_ bundle: URL, version: String, revision: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: bundle.appendingPathComponent("Contents/_CodeSignature"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleShortVersionString": version, "CFBundleVersion": version, "CFBundleExecutable": "Micropod",
            "CFBundleIdentifier": "com.skunkworq.micropod", "MicropodSourceRevision": revision,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: bundle.appendingPathComponent("Contents/Info.plist"))
        for name in ["Micropod", "micropod-docker-shim", "micropod-sharedfs", "MicropodAPI", "micropod-cli"] {
            let url = bundle.appendingPathComponent("Contents/MacOS/" + name)
            try Data("\(name) \(version)".utf8).write(to: url)
            chmod(url.path, 0o755)
        }
        let guest = bundle.appendingPathComponent("Contents/Resources/micropod-guest")
        try Data("micropod-guest \(version)".utf8).write(to: guest)
        chmod(guest.path, 0o755)
        try FakeVerifier.seal(bundle).write(
            to: bundle.appendingPathComponent("Contents/_CodeSignature/seal"), atomically: true, encoding: .utf8)
    }

    private func build(connect: Bool) throws {
        let fm = FileManager.default
        try Self.makeBundle(layout.appPath, version: "0.14.0", revision: Self.sourceRevision)
        let source = try RigBundleIdentity.read(layout.appPath)
        sourcePayload = layout.payloadsRoot.appendingPathComponent("0.14.0-" + source.executableSHA256)
            .appendingPathComponent("Micropod.app")
        try fm.createDirectory(at: sourcePayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: layout.appPath, to: sourcePayload)
        try fm.createDirectory(at: layout.launchAgents, withIntermediateDirectories: true)
        for (id, binary) in [("docker-shim", "micropod-docker-shim"), ("shared-fs", "micropod-sharedfs")] {
            let executable = sourcePayload.appendingPathComponent("Contents/MacOS/" + binary)
            let record = RetainedServiceRecord(
                schema: 1, sourceVersion: "0.14.0", executable: executable.path,
                identifier: RetainedServiceLaunchAgent.identifier(id),
                sha256: try UpdateServiceWitness.digest(executable), arguments: [],
                environment: [
                    "MICROPOD_RUNTIME_CONTEXT": "existing", "MICROPOD_PARENT_PID": "",
                    "MICROPOD_GUEST_TOOL": sourcePayload.path + "/Contents/Resources/micropod-guest",
                ])
            try RuntimeDurableFile.write(
                record, to: RetainedServiceLaunchAgent.recordURL(id, servicesRoot: layout.servicesRoot))
            let plist = RetainedServiceLaunchAgent.plistURL(id, launchAgents: layout.launchAgents)
            try RetainedServiceLaunchAgent.plistData(id, record: record, servicesRoot: layout.servicesRoot).write(
                to: plist)
            launch.load(RetainedServiceLaunchAgent.label(id), plist)
        }
        if connect {
            let bin = layout.connectBinary.deletingLastPathComponent()
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data("MicropodAPI 0.14.0".utf8).write(to: layout.connectBinary)
            chmod(layout.connectBinary.path, 0o755)
            try Data("micropod-guest 0.14.0".utf8).write(to: bin.appendingPathComponent("micropod-guest"))
            try Data("0.11.0\n".utf8).write(to: layout.connectRoot.appendingPathComponent("VERSION"))
            let plist: [String: Any] = [
                "Label": RigUpgradeLayout.connectLabel, "ProgramArguments": [layout.connectBinary.path],
                "KeepAlive": true, "RunAtLoad": true,
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
                to: layout.connectPlist)
            launch.load(RigUpgradeLayout.connectLabel, layout.connectPlist)
        }
        app.running.update { $0 = "Micropod 0.14.0" }
        staged = try stage(version: "0.14.1", revision: Self.targetRevision)
        originals = snapshot()
    }

    /// Unpacks a verified release into `releases/` as the stager does.
    func stage(version: String, revision: String, at date: Date? = nil) throws -> RigStagedRelease {
        let directory = layout.releasesRoot.appendingPathComponent(version + "-" + revision.prefix(12))
        try Self.makeBundle(directory.appendingPathComponent("Micropod.app"), version: version, revision: revision)
        let marker = RigStagedRelease(
            identity: try RigBundleIdentity.read(directory.appendingPathComponent("Micropod.app")),
            artifactURL: "https://example.invalid/Micropod.dmg", artifactSHA256: "00", stagedAt: date ?? clock.now)
        try RuntimeDurableFile.write(marker, to: directory.appendingPathComponent(RigStagedRelease.fileName))
        return marker
    }

    var tracked: [URL] {
        var urls = [
            layout.appPath.appendingPathComponent("Contents/MacOS/Micropod"),
            RetainedServiceLaunchAgent.recordURL("docker-shim", servicesRoot: layout.servicesRoot),
            RetainedServiceLaunchAgent.recordURL("shared-fs", servicesRoot: layout.servicesRoot),
            RetainedServiceLaunchAgent.plistURL("docker-shim", launchAgents: layout.launchAgents),
            RetainedServiceLaunchAgent.plistURL("shared-fs", launchAgents: layout.launchAgents),
        ]
        if FileManager.default.fileExists(atPath: layout.connectPlist.path) {
            urls += [
                layout.connectBinary,
                layout.connectBinary.deletingLastPathComponent().appendingPathComponent("micropod-guest"),
                layout.connectRoot.appendingPathComponent("VERSION"),
            ]
        }
        return urls
    }

    func snapshot() -> [String: Data] {
        Dictionary(
            uniqueKeysWithValues: tracked.compactMap { url in
                FileManager.default.contents(atPath: url.path).map { (url.path, $0) }
            })
    }

    var environment: RigUpgradeEnvironment {
        let launch = launch
        let app = app
        let running = running
        let crash = crash
        let clock = clock
        let layout = layout
        let dedicated = dedicated
        return RigUpgradeEnvironment(
            launch: launch, app: app, drain: drain, health: health, verifier: FakeVerifier(),
            dedicatedRuntime: { dedicated },
            runtimeMaintenance: { [runtimeMaintenance] in runtimeMaintenance.get() },
            desktopInstallerRunning: { [installerRunning] in installerRunning.get() },
            runningExecutables: {
                Array(launch.executables().values) + running.get()
                    + (app.running.get() == nil ? [] : [layout.appPath.path + "/Contents/MacOS/Micropod"])
            },
            portOwner: { _ in layout.connectBinary.path },
            now: { clock.now },
            sleep: { duration in
                clock.advance(duration)
                await Task.yield()
            },
            heartbeatInterval: heartbeat,
            checkpoint: { try crash.visit($0) })
    }

    var engine: RigUpgradeEngine { RigUpgradeEngine(layout: layout, environment: environment) }

    var options: RigUpgradeOptions {
        RigUpgradeOptions(
            drainTimeout: 120, healthTimeout: 30, smokeImage: "alpine:test",
            dockerShimSocket: root.appendingPathComponent("no-shim.sock").path,
            sharedFSSocket: root.appendingPathComponent("no-sharedfs.sock").path,
            appControlSocket: root.appendingPathComponent("no-app.sock").path)
    }

    func journal() throws -> RigUpgradeJournal { try XCTUnwrap(RigUpgradeStore(layout: layout).read()) }

    /// A reboot or re-login: the app is gone and launchd loads what is on disk.
    func reboot() {
        app.running.update { $0 = nil }
        launch.reboot(launchAgents: layout.launchAgents)
    }

    /// Every launch agent that was loaded before the upgrade is loaded.
    func assertServicesLoaded(file: StaticString = #filePath, line: UInt = #line) {
        var labels = [RetainedServiceLaunchAgent.label("docker-shim"), RetainedServiceLaunchAgent.label("shared-fs")]
        if FileManager.default.fileExists(atPath: layout.connectPlist.path) {
            labels.append(RigUpgradeLayout.connectLabel)
        }
        for label in labels {
            XCTAssertNotNil(launch.loaded.get()[label], "\(label) is not loaded", file: file, line: line)
        }
    }

    /// Runs the engine until it reports a terminal phase, as launchd would.
    @discardableResult
    func runToEnd(limit: Int = 8) async throws -> RigUpgradeJournal {
        for _ in 0..<limit {
            do {
                let journal = try await engine.run()
                if journal.phase.isTerminal { return journal }
            } catch is RigUpgradeInterruption {
                continue
            } catch {
                continue
            }
        }
        return try journal()
    }

    // MARK: Assertions

    func assertUpgraded(_ journal: RigUpgradeJournal, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(journal.phase, .completed, journal.reason ?? "", file: file, line: line)
        XCTAssertEqual(try RigBundleIdentity.read(layout.appPath), staged.identity, file: file, line: line)
        let payload = URL(fileURLWithPath: journal.targetPayload)
        XCTAssertTrue(staged.identity.matches(payload), file: file, line: line)
        for (id, binary) in [("docker-shim", "micropod-docker-shim"), ("shared-fs", "micropod-sharedfs")] {
            let record = try RetainedServiceLaunchAgent.readRecord(
                RetainedServiceLaunchAgent.recordURL(id, servicesRoot: layout.servicesRoot))
            XCTAssertEqual(record.executable, payload.path + "/Contents/MacOS/" + binary, file: file, line: line)
            XCTAssertEqual(record.sourceVersion, "0.14.1", file: file, line: line)
            XCTAssertEqual(
                record.environment["MICROPOD_GUEST_TOOL"], payload.path + "/Contents/Resources/micropod-guest",
                file: file, line: line)
            XCTAssertEqual(
                RigUpgradeEngine.programPath(
                    RetainedServiceLaunchAgent.plistURL(id, launchAgents: layout.launchAgents)),
                record.executable, file: file, line: line)
            XCTAssertNotNil(launch.loaded.get()[RetainedServiceLaunchAgent.label(id)], file: file, line: line)
        }
        if FileManager.default.fileExists(atPath: layout.connectPlist.path) {
            XCTAssertEqual(
                try String(contentsOf: layout.connectBinary, encoding: .utf8), "MicropodAPI 0.14.1", file: file,
                line: line)
            XCTAssertEqual(
                try String(contentsOf: layout.connectRoot.appendingPathComponent("VERSION"), encoding: .utf8),
                "0.14.1\n", file: file, line: line)
            XCTAssertNotNil(launch.loaded.get()[RigUpgradeLayout.connectLabel], file: file, line: line)
        }
        XCTAssertEqual(app.running.get(), "Micropod 0.14.1", file: file, line: line)
        // The previous app is kept as the previous release; the staged one is installed.
        let source = journal.source
        XCTAssertTrue(source.matches(URL(fileURLWithPath: journal.previousBundle)), file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: journal.stagedBundle).deletingLastPathComponent().path),
            file: file, line: line)
        XCTAssertFalse(RigUpgradeStore(layout: layout).engineIsRunning, file: file, line: line)
    }

    func assertRestored(_ journal: RigUpgradeJournal, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(journal.phase, .rolledBack, journal.reason ?? "", file: file, line: line)
        let now = snapshot()
        for (path, bytes) in originals {
            XCTAssertEqual(now[path], bytes, "\(path) was not restored", file: file, line: line)
        }
        XCTAssertEqual(Set(now.keys), Set(originals.keys), file: file, line: line)
        XCTAssertTrue(staged.identity.matches(staged.bundle(in: layout)), file: file, line: line)
        XCTAssertEqual(app.running.get(), "Micropod 0.14.0", file: file, line: line)
        for label in [
            RetainedServiceLaunchAgent.label("docker-shim"), RetainedServiceLaunchAgent.label("shared-fs"),
            RigUpgradeLayout.connectLabel,
        ] {
            XCTAssertNotNil(launch.loaded.get()[label], "\(label) was not restarted", file: file, line: line)
        }
    }
}
