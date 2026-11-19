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

    private func protection(_ layout: Layout, executable: URL? = nil, printed: String?? = nil)
        -> RuntimeAuthority.Protection
    {
        RuntimeAuthority.protection(
            executable: executable ?? layout.program, program: layout.program, plist: layout.plist, owner: getuid(),
            group: layout.group, boundary: layout.boundary.path, launchctlPrint: { printed ?? layout.printed })
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
}

/// Requirement 3: migration from the SMAppService install, modelled. launchd
/// and the file system are replaced by state; each step of the installer is
/// one atomic change of that state.
private final class AuthorityModel: RuntimeAuthorityInstallHost, @unchecked Sendable {
    static let old = "old-helper"
    let target: RuntimeComponentBundle
    var authority: RuntimeComponentBundle?
    /// The helper the legacy job's bundle holds (nil: no legacy install).
    var legacyBundle: String? = AuthorityModel.old
    var legacyRegistered = true
    /// The code a running legacy-job process executes.
    var legacyProcess: String? = AuthorityModel.old
    var plist = false
    var loaded = false
    var crashAt: String?

    init(target: RuntimeComponentBundle) { self.target = target }

    func authorityIdentity() -> RuntimeComponentBundle? { authority }
    func stageAuthority(from source: URL, manifest: RuntimeComponentManifest) throws -> RuntimeComponentBundle {
        authority = target
        return target
    }
    func legacyBundleHelper() -> String? { legacyBundle }
    func neutralizeLegacy() throws { legacyBundle = authority?.helperSHA256 }
    func authorityPlistInstalled() -> Bool { plist }
    func writeAuthorityPlist() throws { plist = true }
    func authorityLoaded() -> Bool { loaded }
    func bootstrapAuthority() throws { loaded = true }
    func legacyRunsOldCode() -> Bool { legacyProcess == Self.old }
    func stopLegacy() throws {
        legacyProcess = nil
        // launchd respawns the legacy job (killed, not a clean exit).
        legacyProcess = legacyStart()
    }
    func runtimeIdle() throws -> Bool { true }
    func checkpoint(_ name: String) throws {
        if name == crashAt { throw RuntimeComponentInterruption(checkpoint: name) }
    }

    /// What a legacy-job spawn runs: old code serves; new code yields to a
    /// protected authority plist and serves otherwise.
    func legacyStart() -> String? {
        guard legacyRegistered, let code = legacyBundle else { return nil }
        if code != Self.old, plist { return nil }
        return code
    }

    /// Helpers that would hold `host.lock` now: a running legacy process
    /// keeps it; otherwise a loaded authority takes it.
    func servingNow() -> [String] {
        if let legacyProcess { return ["legacy:" + legacyProcess] }
        return loaded ? ["authority"] : []
    }

    /// After a reboot, in either start order.
    func servingAfterBoot(authorityFirst: Bool) -> [String] {
        let legacy = legacyStart().map { "legacy:" + $0 }
        let authorityRuns = plist && authority != nil
        let contenders =
            authorityFirst
            ? [authorityRuns ? "authority" : nil, legacy] : [legacy, authorityRuns ? "authority" : nil]
        return contenders.compactMap { $0 }.prefix(1).map { $0 }
    }
}

final class RuntimeAuthorityMigrationTests: XCTestCase {
    private let target = ComponentEnvironmentFixture.target
    private let manifest = ComponentEnvironmentFixture.manifest(ComponentEnvironmentFixture.target)
    private let source = URL(fileURLWithPath: "/nonexistent/sealed-copy")

    private func assertExactlyOneServes(
        _ model: AuthorityModel, _ when: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(model.servingNow().count, 1, "now, \(when)", file: file, line: line)
        for order in [true, false] {
            let boot = model.servingAfterBoot(authorityFirst: order)
            XCTAssertEqual(boot.count, 1, "after a reboot, \(when)", file: file, line: line)
            if model.legacyBundle != AuthorityModel.old {
                XCTAssertNotEqual(
                    boot.first, "legacy:" + AuthorityModel.old, "old code after \(when)", file: file, line: line)
            }
        }
    }

    // A kill after every step leaves exactly one helper able to serve, now and
    // after a reboot, and a re-run finishes the migration.
    func testAKillAtAnyStepLeavesExactlyOneHelperAndARerunFinishes() throws {
        for crash in ["staged", "neutralized", "plistWritten", "bootstrapped", nil] {
            let model = AuthorityModel(target: target)
            assertExactlyOneServes(model, "before migrating")
            model.crashAt = crash
            let installer = RuntimeAuthorityInstaller(host: model)
            if crash != nil {
                XCTAssertThrowsError(try installer.run(source: source, manifest: manifest, target: target))
                assertExactlyOneServes(model, "a kill after \(crash!)")
                model.crashAt = nil
            }
            try installer.run(source: source, manifest: manifest, target: target)
            XCTAssertEqual(installer.pending(target: target), [], "after \(crash ?? "an uninterrupted run")")
            XCTAssertEqual(model.servingNow(), ["authority"])
            XCTAssertEqual(model.servingAfterBoot(authorityFirst: false), ["authority"])
            XCTAssertEqual(model.servingAfterBoot(authorityFirst: true), ["authority"])
            // Running it again changes nothing.
            XCTAssertEqual(try installer.run(source: source, manifest: manifest, target: target), [])
        }
    }

    func testRetiringTheLegacyItemAfterwardsChangesNothingThatServes() throws {
        let model = AuthorityModel(target: target)
        try RuntimeAuthorityInstaller(host: model).run(source: source, manifest: manifest, target: target)
        model.legacyRegistered = false
        XCTAssertEqual(model.servingAfterBoot(authorityFirst: false), ["authority"])
    }

    func testAFreshHostWithoutALegacyInstallNeedsNoNeutralizing() throws {
        let model = AuthorityModel(target: target)
        model.legacyBundle = nil
        model.legacyRegistered = false
        model.legacyProcess = nil
        let done = try RuntimeAuthorityInstaller(host: model).run(source: source, manifest: manifest, target: target)
        XCTAssertEqual(done, [.stage, .plist, .bootstrap])
        XCTAssertEqual(model.servingNow(), ["authority"])
    }
}
