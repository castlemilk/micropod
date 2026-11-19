import Darwin
import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodRuntimeHostKit

final class RuntimeAuthorityTests: XCTestCase {
    /// A protected authority layout owned by this account below `boundary`.
    private struct Layout {
        let boundary: URL
        let bundle: URL
        let program: URL
        let plist: URL
        let group: gid_t
        var printed: String {
            "system/\(IsolatedRuntimePolicy.authorityLabel) = {\n\tactive count = 1\n\tpath = \(plist.path)\n"
                + "\ttype = LaunchDaemon\n\tstate = running\n\n\tprogram = \(program.path)\n\tendpoints = {\n"
                + "\t\t\"\(IsolatedRuntimePolicy.authorityServiceName)\" = {\n\t\t\tport = 0x1\n\t\t}\n\t}\n}\n"
        }
    }

    private func layout() throws -> Layout {
        let boundary = FileManager.default.temporaryDirectory.appendingPathComponent("auth-" + UUID().uuidString)
        addTeardownBlock { try? RuntimeSecureCopy.remove(boundary) }
        let bundle = boundary.appendingPathComponent("RuntimeHost/authority/current/Micropod Runtime Setup.app")
        let program = bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")
        try FileManager.default.createDirectory(
            at: program.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try Data("helper".utf8).write(to: program)
        XCTAssertEqual(chmod(program.path, 0o755), 0)
        let daemons = boundary.appendingPathComponent("LaunchDaemons")
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        let plist = daemons.appendingPathComponent(IsolatedRuntimePolicy.authorityLabel + ".plist")
        try PropertyListSerialization.data(
            fromPropertyList: RuntimeAuthority.definition(program: program), format: .xml, options: 0
        ).write(to: plist)
        XCTAssertEqual(chmod(plist.path, 0o644), 0)
        var info = stat()
        XCTAssertEqual(lstat(boundary.path, &info), 0)
        return .init(boundary: boundary, bundle: bundle, program: program, plist: plist, group: info.st_gid)
    }

    private func protection(
        _ layout: Layout, executable: URL? = nil, printed: String?? = nil,
        legacy: RuntimeAuthority.LegacyJob? = .init(loaded: false, disabled: true)
    ) -> RuntimeAuthority.Protection {
        RuntimeAuthority.protection(
            executable: executable ?? layout.program, program: layout.program, plist: layout.plist, owner: getuid(),
            group: layout.group, boundary: layout.boundary.path, launchctlPrint: { printed ?? layout.printed },
            legacy: { legacy })
    }

    // R1: while the legacy SMAppService job is loaded or merely enabled, a
    // root path through /Applications remains, so the authority is not
    // protected (and component updates refuse).
    func testProtectionRequiresTheLegacyJobBootedOutAndDisabled() throws {
        let layout = try layout()
        XCTAssertEqual(protection(layout), .ok)
        XCTAssertEqual(
            protection(layout, legacy: .init(loaded: true, disabled: true)).reason,
            "the legacy SMAppService helper job is still loaded")
        XCTAssertEqual(
            protection(layout, legacy: .init(loaded: false, disabled: false)).reason,
            "the legacy SMAppService helper job is not disabled")
        XCTAssertFalse(protection(layout, legacy: nil).protected, "unreadable state fails closed")
    }

    func testTheLegacyJobStateIsReadFromLaunchctl() throws {
        let label = IsolatedRuntimePolicy.serviceName
        let printed = "system/\(label) = {\n\tpath = /Applications/x.plist\n\tstate = running\n\tpid = 41\n}\n"
        let modern = "disabled services = {\n\t\"com.apple.ftpd\" => disabled\n\t\"\(label)\" => disabled\n}\n"
        let older = "disabled services = {\n\t\"\(label)\" => true\n}\n"
        let enabled = "disabled services = {\n\t\"\(label)\" => enabled\n\t\"\(label).other\" => disabled\n}\n"
        XCTAssertEqual(
            RuntimeAuthority.LegacyJob(printed: printed, printDisabled: enabled), .init(loaded: true, disabled: false))
        XCTAssertEqual(
            RuntimeAuthority.LegacyJob(printed: nil, printDisabled: modern), .init(loaded: false, disabled: true))
        XCTAssertEqual(
            RuntimeAuthority.LegacyJob(printed: nil, printDisabled: older), .init(loaded: false, disabled: true))
        XCTAssertNil(RuntimeAuthority.LegacyJob(printed: nil, printDisabled: nil))
    }

    // R1: once the authority plist exists, clients never call the legacy
    // service.
    func testClientsDoNotFallBackToTheLegacyServiceOnceTheAuthorityIsInstalled() {
        XCTAssertEqual(
            IsolatedRuntimePolicy.clientServiceNames(authorityInstalled: true),
            [IsolatedRuntimePolicy.authorityServiceName])
        XCTAssertEqual(
            IsolatedRuntimePolicy.clientServiceNames(authorityInstalled: false),
            [IsolatedRuntimePolicy.authorityServiceName, IsolatedRuntimePolicy.serviceName])
    }

    // R1: "serving" is the authority job's live process, born when it wrote
    // its record, on the authority's service.
    func testTheServingRecordMustDescribeTheLiveAuthorityProcess() throws {
        let record = RuntimeAuthority.Serving(
            pid: 41, birthSeconds: 100, birthMicroseconds: 7,
            serviceName: IsolatedRuntimePolicy.authorityServiceName, version: "0.13.10", helperSHA256: "c")
        let job = RuntimeAuthority.LiveJob("system/x = {\n\tpath = /p\n\tstate = running\n\tpid = 41\n}\n")
        let birth = RuntimeProcessBirth(pid: 41, uid: 0, seconds: 100, microseconds: 7, bootSession: "b")
        XCTAssertTrue(record.describes(job, birth: birth))
        XCTAssertFalse(record.describes(job, birth: nil), "the process is gone")
        XCTAssertFalse(
            record.describes(job, birth: .init(pid: 41, uid: 0, seconds: 100, microseconds: 8, bootSession: "b")),
            "a reused pid")
        XCTAssertFalse(
            record.describes(
                RuntimeAuthority.LiveJob("system/x = {\n\tpath = /p\n\tstate = not running\n}\n"),
                birth: birth))
        let legacy = RuntimeAuthority.Serving(
            pid: 41, birthSeconds: 100, birthMicroseconds: 7, serviceName: IsolatedRuntimePolicy.serviceName,
            version: "0.13.10", helperSHA256: "c")
        XCTAssertFalse(legacy.describes(job, birth: birth), "a legacy-job helper is not the authority")
    }

    // N1(c): the constraint carries the Developer ID validation category.
    func testTheDefinitionIsARootOnlyProgramWithADeveloperIDSpawnConstraint() throws {
        let definition = RuntimeAuthority.definition()
        XCTAssertEqual(definition["Label"] as? String, IsolatedRuntimePolicy.authorityLabel)
        XCTAssertEqual(definition["Program"] as? String, IsolatedRuntimePolicy.authorityProgram.path)
        XCTAssertTrue(IsolatedRuntimePolicy.authorityProgram.path.hasPrefix(IsolatedRuntimePolicy.root.path + "/"))
        XCTAssertNil(definition["BundleProgram"], "Never a program inside a bundle in /Applications")
        let constraint = try XCTUnwrap(definition["SpawnConstraint"] as? [String: Any])
        XCTAssertEqual(constraint["team-identifier"] as? String, "WFTX6CN23F")
        XCTAssertEqual(constraint["signing-identifier"] as? String, IsolatedRuntimePolicy.helperIdentifier)
        XCTAssertEqual(constraint["validation-category"] as? Int, 6)
        XCTAssertEqual(
            (definition["MachServices"] as? [String: Bool])?.keys.sorted(), [IsolatedRuntimePolicy.authorityServiceName]
        )
        XCTAssertEqual(RuntimeAuthority.definitionSHA256.count, 64)
    }

    // N1(b) and requirement 2: the live check at every start.
    func testProtectionHoldsOnlyForTheExactRootOnlyAuthority() throws {
        let layout = try layout()
        XCTAssertEqual(protection(layout), .ok)

        // Started from anywhere else (the legacy job in /Applications).
        XCTAssertFalse(
            protection(layout, executable: URL(fileURLWithPath: "/Applications/x/MicropodRuntimeHost")).protected)
        // launchd's live job cannot be read, or runs another program.
        XCTAssertFalse(protection(layout, printed: .some(nil)).protected)
        XCTAssertFalse(
            protection(
                layout, printed: layout.printed.replacingOccurrences(of: layout.program.path, with: "/tmp/other")
            )
            .protected)

        // A plist whose constraint was stripped is not the expected definition.
        var stripped = RuntimeAuthority.definition(program: layout.program)
        stripped["SpawnConstraint"] = nil
        try PropertyListSerialization.data(fromPropertyList: stripped, format: .xml, options: 0).write(to: layout.plist)
        XCTAssertTrue(protection(layout).reason?.contains("not the definition") == true, "\(protection(layout))")
    }

    func testEveryAncestorMustBeOwnedUnwritableACLFreeAndNoLink() throws {
        let layout = try layout()
        let authority = layout.bundle.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(chmod(authority.path, 0o775), 0)
        XCTAssertTrue(protection(layout).reason?.contains("writable by group") == true)
        XCTAssertEqual(chmod(authority.path, 0o755), 0)

        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow add_file", authority.path]
        try acl.run()
        acl.waitUntilExit()
        XCTAssertTrue(protection(layout).reason?.contains("ACL") == true, "\(protection(layout))")
        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
        clear.arguments = ["-N", authority.path]
        try clear.run()
        clear.waitUntilExit()
        XCTAssertEqual(protection(layout), .ok)

        // A symbolic link anywhere on the path is refused, never followed.
        let real = authority.deletingLastPathComponent().appendingPathComponent("authority-real")
        XCTAssertEqual(rename(authority.path, real.path), 0)
        try FileManager.default.createSymbolicLink(atPath: authority.path, withDestinationPath: real.path)
        XCTAssertFalse(protection(layout).protected)
    }

    func testLaunchctlPrintIsReadForTopLevelPathAndProgramOnly() throws {
        let job = try XCTUnwrap(
            RuntimeAuthority.LiveJob(
                "system/x = {\n\tpath = /Library/LaunchDaemons/x.plist\n\tprogram = /a/b\n\tsub = {\n\t\tprogram = /evil\n\t}\n}"
            ))
        XCTAssertEqual(job.path, "/Library/LaunchDaemons/x.plist")
        XCTAssertEqual(job.program, "/a/b")
        XCTAssertNil(job.pid)
        let running = try XCTUnwrap(
            RuntimeAuthority.LiveJob(
                "system/x = {\n\tpath = /p\n\tstate = running\n\tpid = 812\n\tsub = {\n\t\tpid = 9\n\t}\n}"))
        XCTAssertEqual(running.state, "running")
        XCTAssertEqual(running.pid, 812)
        XCTAssertNil(RuntimeAuthority.LiveJob("Could not find service \"x\" in domain for system"))
    }

    // The legacy job yields only to a protected authority plist.
    func testTheLegacyJobYieldsOnlyToAProtectedAuthority() throws {
        let layout = try layout()
        XCTAssertTrue(
            RuntimeAuthority.legacyJobShouldYield(plist: layout.plist, owner: getuid(), boundary: layout.boundary.path))
        XCTAssertEqual(chmod(layout.plist.path, 0o666), 0)
        XCTAssertFalse(
            RuntimeAuthority.legacyJobShouldYield(plist: layout.plist, owner: getuid(), boundary: layout.boundary.path))
        XCTAssertFalse(
            RuntimeAuthority.legacyJobShouldYield(
                plist: layout.boundary.appendingPathComponent("missing.plist"), owner: getuid(),
                boundary: layout.boundary.path))
    }

    // N8: verification, restore and the probe follow the release table.
    func testAppleBuildsFollowTheReleaseTable() {
        let supported = ManagedRuntimeLocation.Selection(
            version: AppleRuntimeRelease.supported.version, packageSHA256: AppleRuntimeRelease.supported.packageSHA256,
            incarnation: UUID())
        XCTAssertTrue(supported.isSupported)
        XCTAssertEqual(AppleRuntimeRelease.payload(for: supported), AppleRuntimeRelease.payloadSHA256)
        let unknown = ManagedRuntimeLocation.Selection(
            version: "1.5.0", packageSHA256: String(repeating: "7", count: 64))
        XCTAssertFalse(unknown.isSupported)
        XCTAssertNil(AppleRuntimeRelease.payload(for: unknown))
        XCTAssertEqual(
            RuntimeComponentProbe.current(version: "0.13.10", revision: "").appleRuntimes.count,
            AppleRuntimeRelease.releases.count)
    }

    // N9: the legacy identifier has a sunset.
    func testTheLegacyHelperIdentifierIsAcceptedOnlyUntilItsSunset() {
        XCTAssertTrue(IsolatedRuntimePolicy.legacyHelperAccepted(at: Date(timeIntervalSince1970: 1_795_000_000)))
        XCTAssertFalse(
            IsolatedRuntimePolicy.legacyHelperAccepted(
                at: IsolatedRuntimePolicy.legacyHelperSunset.addingTimeInterval(1)))
    }

    // N3: removal never follows a link out of the tree it removes.
    func testRemovalNeverFollowsALinkOutOfTheTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let precious = outside.appendingPathComponent("component-state.json")
        try Data("keep".utf8).write(to: precious)
        XCTAssertEqual(chflags(precious.path, UInt32(UF_NODUMP)), 0)
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: tree.appendingPathComponent("a/link").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(
            atPath: tree.appendingPathComponent("file-link").path, withDestinationPath: precious.path)
        try RuntimeSecureCopy.remove(tree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(try Data(contentsOf: precious), Data("keep".utf8))
        var info = stat()
        XCTAssertEqual(lstat(precious.path, &info), 0)
        XCTAssertEqual(info.st_flags, UInt32(UF_NODUMP), "Flags outside the tree are untouched")
    }

    // F6: a gate fault applies only to the exact release and helper digest
    // it names, and only until it expires (never for longer than six hours).
    func testGateFaultsNameOneHelperAndExpire() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func data(_ fault: String = "crash", digest: String = "c", expires: Double = 1_800_003_600) -> Data {
            Data(#"{"version":"0.13.11","helperSHA256":"\#(digest)","fault":"\#(fault)","expiresAt":\#(expires)}"#.utf8)
        }
        func fault(_ data: Data?, version: String = "0.13.11", digest: String = "c") -> String? {
            RuntimeGateHooks.fault(in: data, version: version, helperSHA256: { digest }, now: now)
        }
        XCTAssertEqual(fault(data()), "crash")
        XCTAssertEqual(fault(data("hang")), "hang")
        XCTAssertNil(fault(data(), version: "0.13.10"), "another release")
        XCTAssertNil(fault(data(), digest: "d"), "another helper build of the same release")
        XCTAssertNil(fault(data(expires: 1_799_999_999)), "expired")
        XCTAssertNil(fault(data(expires: 1_800_000_000 + 7 * 3600)), "armed for longer than allowed")
        XCTAssertNil(fault(data("rm")))
        XCTAssertNil(fault(Data(#"{"version":"0.13.11","fault":"crash"}"#.utf8)), "no digest or expiry")
        XCTAssertNil(fault(nil))
        XCTAssertNil(fault(Data("{".utf8)))
        XCTAssertEqual(
            IsolatedRuntimeHostController.describeProtection("protected", gateFaultArmed: true),
            "protected; release-gate fault armed")
        XCTAssertEqual(
            IsolatedRuntimeHostController.describeProtection("protected", gateFaultArmed: false), "protected")
    }

    // F5: the install-authority kill is armed by a root-owned file naming the
    // checkpoint and the CLI's CDHash, and expires.
    func testGateKillsNameOneCheckpointAndOneCLI() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let armed = Data(#"{"checkpoint":"bootstrapped","cdhash":"ab","expiresAt":1800000600}"#.utf8)
        func kill(_ data: Data?, at checkpoint: String = "bootstrapped", cdhash: String? = "ab") -> Bool {
            RuntimeGateHooks.kill(in: data, checkpoint: checkpoint, cdhash: { cdhash }, now: now)
        }
        XCTAssertTrue(kill(armed))
        XCTAssertFalse(kill(armed, at: "staged"))
        XCTAssertFalse(kill(armed, cdhash: "cd"), "another CLI build")
        XCTAssertFalse(kill(armed, cdhash: nil), "an unsigned CLI")
        XCTAssertFalse(kill(Data(#"{"checkpoint":"bootstrapped","cdhash":"ab","expiresAt":1799999999}"#.utf8)))
        XCTAssertFalse(kill(nil))
    }

    // F7: protection names the legacy job as the reason when it is.
    func testProtectionFlagsTheLegacyJobAsItsOwnReason() throws {
        let layout = try layout()
        XCTAssertFalse(protection(layout).legacyActive)
        XCTAssertTrue(protection(layout, legacy: .init(loaded: true, disabled: true)).legacyActive)
        XCTAssertTrue(protection(layout, legacy: .init(loaded: false, disabled: false)).legacyActive)
        XCTAssertFalse(protection(layout, legacy: nil).legacyActive, "unreadable is unprotected, not legacy")
        XCTAssertFalse(protection(layout, printed: .some(nil)).legacyActive)
    }

    // R4: removal descends a bounded depth and refuses a deeper tree.
    func testRemovalDepthIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deep-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var leaf = root
        for _ in 0..<6 { leaf.appendPathComponent("d") }
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RuntimeSecureCopy.remove(root, maximumDepth: 4)) {
            XCTAssertTrue("\($0)".contains("deeper than removal descends"), "\($0)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        try RuntimeSecureCopy.remove(root, maximumDepth: 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertGreaterThanOrEqual(RuntimeSecureCopy.maximumRemovalDepth, 32)
    }
}

/// Requirement 3 and R1/R3: migration from the SMAppService install,
/// modelled. launchd, the lock and the file system are replaced by state; each
/// installer step is one atomic change of that state.
private final class AuthorityModel: RuntimeAuthorityInstallHost, @unchecked Sendable {
    static let old = "old-helper"
    let target: RuntimeComponentBundle
    var authority: RuntimeComponentBundle?
    /// The helper the legacy job's bundle in /Applications holds (nil: no
    /// legacy install), and whether it is root's sealed copy, and immutable.
    var legacyCode: String? = AuthorityModel.old
    var legacySealed = false
    var legacyImmutable = false
    /// SMAppService registration (Login Items), launchd's loaded job, and the
    /// persistent disable override.
    var legacyRegistered = true
    var legacyLoaded = true
    var legacyDisabled = false
    /// The code a running legacy-job process executes; it holds `host.lock`.
    var legacyProcess: String? = AuthorityModel.old
    var plist = false
    var loaded = false
    /// The helper the live authority process serves (it holds `host.lock`).
    var authorityProcess: String?
    /// launchd refuses the authority's spawn, or the release is below the
    /// security floor: it never serves.
    var authorityCannotRun = false
    /// `launchctl disable` silently not taking effect.
    var disableIgnored = false
    var crashAt: String?

    init(target: RuntimeComponentBundle) { self.target = target }

    func authorityIdentity() -> RuntimeComponentBundle? { authority }
    func stageAuthority(from source: URL, manifest: RuntimeComponentManifest) throws -> RuntimeComponentBundle {
        authority = target
        return target
    }
    func legacyBundle() -> (helperSHA256: String, sealed: Bool)? { legacyCode.map { ($0, legacySealed) } }
    func neutralizeLegacy() throws {
        legacyCode = authority?.helperSHA256
        legacySealed = true
        legacyImmutable = false
    }
    func authorityPlistInstalled() -> Bool { plist }
    func writeAuthorityPlist() throws { plist = true }
    func authorityLoaded() -> Bool { loaded }
    func bootstrapAuthority() throws {
        loaded = true
        respawnAuthority()
    }
    func legacyRetired() -> Bool {
        !legacyLoaded && legacyDisabled && (legacyCode == nil || (legacySealed && legacyImmutable))
    }
    func retireLegacy() throws {
        // bootout ends the process and unloads the job, so nothing respawns it.
        legacyProcess = nil
        legacyLoaded = false
        if !disableIgnored { legacyDisabled = true }
        if legacySealed { legacyImmutable = true }
    }
    func authorityServing(wait: Bool) -> String? {
        // KeepAlive respawns an authority that gave up on the lock.
        if wait { respawnAuthority() }
        return authorityProcess
    }
    func startAuthority(kill: Bool) throws {
        if kill { authorityProcess = nil }
        respawnAuthority()
    }
    func runtimeIdle() throws -> Bool { true }
    func checkpoint(_ name: String) throws {
        if name == crashAt { throw RuntimeComponentInterruption(checkpoint: name) }
    }

    private func respawnAuthority() {
        guard loaded, legacyProcess == nil, authorityProcess == nil, !authorityCannotRun else { return }
        authorityProcess = authority?.helperSHA256
    }

    /// What a legacy-job spawn runs: old code serves; new code yields to a
    /// protected authority plist and serves otherwise.
    func legacyStart() -> String? {
        guard legacyRegistered, legacyLoaded, let code = legacyCode else { return nil }
        if code != Self.old, plist { return nil }
        return code
    }

    /// The helpers holding `host.lock` now (at most one by construction).
    func servingNow() -> [String] {
        if let legacyProcess { return ["legacy:" + legacyProcess] }
        return authorityProcess.map { ["authority:" + $0] } ?? []
    }

    /// The helpers a client reaches: never the legacy service once the
    /// authority plist exists.
    func reachableNow() -> [String] {
        let services = IsolatedRuntimePolicy.clientServiceNames(authorityInstalled: plist)
        return servingNow().filter {
            services.contains(
                $0.hasPrefix("legacy:")
                    ? IsolatedRuntimePolicy.serviceName
                    : IsolatedRuntimePolicy.authorityServiceName)
        }
    }

    /// After a reboot, in either start order: launchd loads the authority
    /// from /Library/LaunchDaemons and the legacy job unless it is disabled.
    func servingAfterBoot(authorityFirst: Bool) -> [String] {
        let legacy = legacyDisabled ? nil : legacyStart().map { "legacy:" + $0 }
        let authorityRuns = plist && !authorityCannotRun ? authority.map { "authority:" + $0.helperSHA256 } : nil
        let contenders = authorityFirst ? [authorityRuns, legacy] : [legacy, authorityRuns]
        return contenders.compactMap { $0 }.prefix(1).map { $0 }
    }
}

final class RuntimeAuthorityMigrationTests: XCTestCase {
    private let target = ComponentEnvironmentFixture.target
    private let manifest = ComponentEnvironmentFixture.manifest(ComponentEnvironmentFixture.target)
    private let source = URL(fileURLWithPath: "/nonexistent/sealed-copy")
    private var serving: String { "authority:" + target.helperSHA256 }
    private let checkpoints = ["staged", "neutralized", "plistWritten", "bootstrapped", "retired", "started"]

    private func assertAtMostOneServes(
        _ model: AuthorityModel, _ when: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(model.servingNow().count, 1, "now, \(when)", file: file, line: line)
        for order in [true, false] {
            let boot = model.servingAfterBoot(authorityFirst: order)
            XCTAssertLessThanOrEqual(boot.count, 1, "after a reboot, \(when)", file: file, line: line)
            if model.legacyCode != AuthorityModel.old {
                XCTAssertNotEqual(
                    boot.first, "legacy:" + AuthorityModel.old, "old code after \(when)", file: file, line: line)
            }
        }
        // Once the plist exists a client never reaches the legacy service.
        if model.plist {
            XCTAssertFalse(model.reachableNow().contains { $0.hasPrefix("legacy:") }, when, file: file, line: line)
        }
    }

    private func assertFinished(
        _ model: AuthorityModel, _ when: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let installer = RuntimeAuthorityInstaller(host: model)
        XCTAssertEqual(installer.pending(target: target), [], when, file: file, line: line)
        XCTAssertEqual(model.servingNow(), [serving], when, file: file, line: line)
        XCTAssertEqual(model.reachableNow(), [serving], when, file: file, line: line)
        XCTAssertEqual(model.servingAfterBoot(authorityFirst: false), [serving], when, file: file, line: line)
        XCTAssertEqual(model.servingAfterBoot(authorityFirst: true), [serving], when, file: file, line: line)
        // R1: the legacy job is booted out, disabled, and its bundle immutable.
        XCTAssertFalse(model.legacyLoaded, when, file: file, line: line)
        XCTAssertTrue(model.legacyDisabled, when, file: file, line: line)
        if model.legacyCode != nil {
            XCTAssertTrue(model.legacySealed && model.legacyImmutable, when, file: file, line: line)
        }
    }

    // A kill after every step leaves at most one helper able to serve, now and
    // after a reboot, and a re-run finishes the migration.
    func testAKillAtAnyStepLeavesAtMostOneHelperAndARerunFinishes() throws {
        for crash in checkpoints.map(Optional.some) + [nil] {
            let model = AuthorityModel(target: target)
            assertAtMostOneServes(model, "before migrating")
            XCTAssertEqual(model.reachableNow(), ["legacy:" + AuthorityModel.old])
            model.crashAt = crash
            let installer = RuntimeAuthorityInstaller(host: model)
            if let crash {
                XCTAssertThrowsError(try installer.run(source: source, manifest: manifest, target: target))
                assertAtMostOneServes(model, "a kill after \(crash)")
                model.crashAt = nil
            }
            try installer.run(source: source, manifest: manifest, target: target)
            assertFinished(model, "after \(crash ?? "an uninterrupted run")")
            // Running it again changes nothing.
            XCTAssertEqual(try installer.run(source: source, manifest: manifest, target: target), [])
        }
    }

    // R3: the windows where no helper is reachable are exactly the ones the
    // design note lists, and a reboot inside one recovers on its own.
    func testTheNoHelperWindowsAreTheDocumentedOnes() throws {
        var unreachable: [String] = []
        for crash in checkpoints {
            let model = AuthorityModel(target: target)
            model.crashAt = crash
            XCTAssertThrowsError(
                try RuntimeAuthorityInstaller(host: model).run(source: source, manifest: manifest, target: target))
            // Give launchd's KeepAlive its throttle interval to respawn.
            _ = model.authorityServing(wait: true)
            if model.reachableNow().isEmpty {
                unreachable.append(crash)
                // A reboot loads the authority from /Library/LaunchDaemons.
                XCTAssertEqual(model.servingAfterBoot(authorityFirst: false), [serving], crash)
            }
        }
        XCTAssertEqual(unreachable, ["plistWritten", "bootstrapped"])
    }

    // R1: install-authority does not finish while the legacy job could load.
    func testItDoesNotFinishUntilTheLegacyJobIsRetired() throws {
        let model = AuthorityModel(target: target)
        model.disableIgnored = true
        let installer = RuntimeAuthorityInstaller(host: model)
        XCTAssertThrowsError(try installer.run(source: source, manifest: manifest, target: target)) {
            XCTAssertTrue("\($0)".contains("still loaded or enabled"), "\($0)")
        }
        XCTAssertEqual(installer.pending(target: target), [.retireLegacy, .start])
        model.disableIgnored = false
        try installer.run(source: source, manifest: manifest, target: target)
        assertFinished(model, "once the disable took")
    }

    // R3: launchd refusing the authority's spawn (or a release below the
    // floor) leaves no helper; install-authority says so, and a re-run with a
    // good release recovers.
    func testAnAuthorityThatCannotRunIsReportedAndARerunRecovers() throws {
        let model = AuthorityModel(target: target)
        model.authorityCannotRun = true
        let installer = RuntimeAuthorityInstaller(host: model)
        XCTAssertThrowsError(try installer.run(source: source, manifest: manifest, target: target)) {
            XCTAssertTrue("\($0)".contains("does not serve"), "\($0)")
        }
        XCTAssertEqual(model.servingNow(), [])
        XCTAssertEqual(installer.pending(target: target), [.start])
        model.authorityCannotRun = false
        XCTAssertEqual(try installer.run(source: source, manifest: manifest, target: target), [.start])
        assertFinished(model, "after the re-run")
    }

    // A re-run with a newer release replaces and restarts a serving authority.
    func testANewerReleaseRestartsAServingAuthority() throws {
        let model = AuthorityModel(target: target)
        model.legacyCode = nil
        model.legacyRegistered = false
        model.legacyLoaded = false
        model.legacyDisabled = true
        model.legacyProcess = nil
        model.plist = true
        model.loaded = true
        model.authority = ComponentEnvironmentFixture.bundle("0.13.9", "9", cdhash: "8", helper: "7", api: "6")
        model.authorityProcess = model.authority?.helperSHA256
        let installer = RuntimeAuthorityInstaller(host: model)
        XCTAssertEqual(installer.pending(target: target), [.stage, .start])
        XCTAssertEqual(try installer.run(source: source, manifest: manifest, target: target), [.stage, .start])
        assertFinished(model, "after the restart")
    }

    func testRemovingTheLoginItemAfterwardsChangesNothingThatServes() throws {
        let model = AuthorityModel(target: target)
        try RuntimeAuthorityInstaller(host: model).run(source: source, manifest: manifest, target: target)
        model.legacyRegistered = false
        XCTAssertEqual(model.servingAfterBoot(authorityFirst: false), [serving])
    }

    func testAFreshHostWithoutALegacyInstallNeedsNoNeutralizing() throws {
        let model = AuthorityModel(target: target)
        model.legacyCode = nil
        model.legacyRegistered = false
        model.legacyLoaded = false
        model.legacyProcess = nil
        let done = try RuntimeAuthorityInstaller(host: model).run(source: source, manifest: manifest, target: target)
        XCTAssertEqual(done, [.stage, .plist, .bootstrap, .retireLegacy])
        assertFinished(model, "a fresh host")
    }
}
