import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `micropod setup`'s steps on a throwaway root, from a temp package: the
/// runtime files and base disk come from a directory or an app bundle that
/// holds stand-ins (a signed copy of /usr/bin/true for the VMM, an ext4
/// magic for disks). No machine is started and nothing is downloaded.
final class HVFMachineBootstrapTests: XCTestCase {
    private var base: URL!
    private var layout: HVFMachineLayout!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: "/tmp").appendingPathComponent("mpbs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        layout = HVFMachineLayout(root: base.appendingPathComponent("hvf"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private static let fresh = HVFMachineBootstrap.Runtimes(defaultName: { "hvf" }, origin: { .fresh })

    // MARK: Fixtures

    /// An ad-hoc signed copy of a system binary (never executed), with the
    /// hypervisor entitlement unless `entitled` is false.
    private func vmm(entitled: Bool = true) throws -> URL {
        let binary = base.appendingPathComponent(entitled ? "vmm-entitled" : "vmm-plain")
        if FileManager.default.fileExists(atPath: binary.path) { return binary }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        guard entitled else { return binary }
        let plist = base.appendingPathComponent("ent.plist")
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
            """.utf8
        ).write(to: plist)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--sign", "-", "--force", "--entitlements", plist.path, binary.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw XCTSkip("ad-hoc codesign unavailable") }
        return binary
    }

    private func ext4(_ url: URL, marker: UInt8 = 1) throws {
        var disk = Data(count: 4096)
        disk[1024 + 0x38] = 0x53
        disk[1024 + 0x39] = 0xEF
        disk[0] = marker
        try disk.write(to: url)
    }

    /// A package: flat (the CLI tarball's layout) or an app bundle, with
    /// payload-version names (`Image`, `tools`) when `versionNames`.
    @discardableResult
    private func package(
        app: Bool = false, baseDisk: Bool = true, entitled: Bool = true, versionNames: Bool = false
    ) throws -> URL {
        let fm = FileManager.default
        let root = base.appendingPathComponent(app ? "Micropod.app" : "dist")
        let bin = app ? root.appendingPathComponent("Contents/MacOS") : root
        let resources = app ? root.appendingPathComponent("Contents/Resources") : root
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.copyItem(at: try vmm(entitled: entitled), to: bin.appendingPathComponent("micropod-vmm"))
        try Data("kernel".utf8).write(to: resources.appendingPathComponent(versionNames ? "Image" : "vmlinux-hvf"))
        try Data("initrd".utf8).write(to: resources.appendingPathComponent("mp-hvf-init.cpio"))
        let tools = resources.appendingPathComponent(versionNames ? "tools" : "micropod-oci-tools")
        try fm.createDirectory(at: tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tools.appendingPathComponent("runner/start.sh"))
        if baseDisk { try ext4(resources.appendingPathComponent(HVFMachineInstaller.baseDiskName), marker: 7) }
        return root
    }

    private func bootstrap(
        _ options: HVFMachineBootstrap.Options, packagedExecutable: URL? = nil,
        runtimes: HVFMachineBootstrap.Runtimes = fresh
    ) -> HVFMachineBootstrap {
        HVFMachineBootstrap(
            layout: layout, options: options, environment: ["MICROPOD_HVF_ROOT": layout.root.path],
            packagedExecutable: packagedExecutable, runtimes: runtimes)
    }

    private func states(_ steps: [HVFMachineBootstrap.Step]) -> [String] {
        steps.map { "\($0.id.rawValue)=\($0.state.rawValue)" }
    }

    private var rootContents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.root.path)) ?? []).sorted()
    }

    // MARK: Plan

    func testThePlanListsTheFiveStepsInOrderFromThePackage() throws {
        let dist = try package()
        let steps = bootstrap(.init(payload: dist, start: false)).plan()
        XCTAssertEqual(steps.map(\.id), HVFMachineBootstrap.StepID.allCases)
        XCTAssertEqual(
            states(steps),
            ["runtime-files=pending", "disk=pending", "cache-disk=pending", "start=skipped", "default-runtime=pending"])
        let canonical = HVFMachineLayout.canonicalPath(dist.path)
        XCTAssertEqual(steps[0].detail, "micropod-vmm, Image, mp-hvf-init.cpio, tools/ from \(canonical)")
        XCTAssertEqual(steps[1].detail, "from \(canonical)/\(HVFMachineInstaller.baseDiskName)")
        XCTAssertEqual(steps[2].detail, "32 GiB sparse", "a new machine gets a 32 GiB cache disk")
        XCTAssertTrue(steps[3].detail.contains("--no-start"))
        XCTAssertEqual(steps[4].detail, "hvf")
        XCTAssertEqual(rootContents, [], "planning changes nothing")
    }

    func testOnlyAnExplicitDiskImageDownloads() throws {
        let dist = try package(baseDisk: false)
        let local = bootstrap(.init(payload: dist, start: false)).plan()
        XCTAssertEqual(local[1].state, .failed)
        XCTAssertFalse(local.contains { $0.detail.contains("downloads") })
        let pulled = bootstrap(.init(payload: dist, diskImage: "docker.io/library/alpine:3.20", start: false)).plan()
        XCTAssertEqual(pulled[1].state, .pending)
        XCTAssertEqual(pulled[1].detail, "unpacked from docker.io/library/alpine:3.20 (downloads it)")
    }

    // MARK: Run

    func testSetupInstallsFromAnAppBundleThenKeepsEverything() async throws {
        let app = try package(app: true)
        let options = HVFMachineBootstrap.Options(payload: app, cacheDiskBytes: 256 << 20, start: false)
        let events = EventLog()
        let first = await bootstrap(options).run { events.append($0) }
        XCTAssertEqual(
            states(first),
            ["runtime-files=done", "disk=done", "cache-disk=done", "start=skipped", "default-runtime=done"])
        let resources = HVFMachineLayout.canonicalPath(app.appendingPathComponent("Contents/Resources").path)
        XCTAssertEqual(first[1].detail, "cloned from \(resources)/\(HVFMachineInstaller.baseDiskName)")
        XCTAssertEqual(first[2].detail, "created (256 MiB sparse)")
        XCTAssertEqual(layout.missingAssets(), [], "the machine is installed")
        XCTAssertEqual(try Data(contentsOf: layout.disk).first, 7, "the disk is the bundled base disk")
        XCTAssertTrue(HVFMachineLayout.isRegularFile(layout.cacheDisk))
        XCTAssertNoThrow(try HVFMachineInstaller.verifyHypervisorEntitlement(layout.vmm))
        XCTAssertEqual(
            events.finished.map(\.id), [.runtimeFiles, .disk, .cacheDisk, .start, .defaultRuntime],
            "each step is reported as it finishes")
        XCTAssertTrue(events.details.contains { $0.contains("installed micropod-vmm") }, "\(events.details)")

        let disk = try Data(contentsOf: layout.disk)
        let again = await bootstrap(options).run()
        XCTAssertEqual(
            states(again),
            ["runtime-files=kept", "disk=kept", "cache-disk=kept", "start=skipped", "default-runtime=done"])
        XCTAssertEqual(again[0].detail, "present, kept")
        XCTAssertEqual(again[1].detail, "present, kept")
        XCTAssertTrue(again[2].detail.hasPrefix("present, kept ("), again[2].detail)
        XCTAssertEqual(try Data(contentsOf: layout.disk), disk, "re-running changes nothing")

        // A disk named on a re-run is not a replacement.
        let named = HVFMachineBootstrap.Options(diskFrom: app, start: false)
        let kept = bootstrap(named).plan()[1]
        XCTAssertEqual(kept.state, .kept)
        XCTAssertTrue(kept.detail.contains("--replace-disk"), kept.detail)
    }

    func testNoDiskSourceNamesBothWaysAndChangesNothing() async throws {
        let dist = try package(baseDisk: false)
        let steps = await bootstrap(.init(payload: dist, start: false)).run()
        XCTAssertEqual(
            states(steps),
            ["runtime-files=pending", "disk=failed", "cache-disk=pending", "start=pending", "default-runtime=pending"])
        XCTAssertEqual(
            steps[1].detail,
            "no base disk: this package ships none. Pass --disk-from <ext4> (a local image), or --disk-image "
                + "default to download docker:29.9.3-dind from Docker Hub.")
        XCTAssertEqual(steps[0].detail, "nothing was changed")
        XCTAssertEqual(rootContents, [], "nothing was written")
    }

    func testADevelopmentBinaryNeedsAPayload() async throws {
        let dev = URL(fileURLWithPath: "/src/micropod/.build/debug/micropod")
        let steps = await bootstrap(.init(start: false), packagedExecutable: dev).run()
        XCTAssertEqual(steps[0].state, .failed)
        XCTAssertEqual(
            steps[0].detail,
            "pass --payload <Micropod.app or a directory holding micropod-vmm, vmlinux-hvf, mp-hvf-init.cpio, "
                + "micropod-oci-tools>")
        XCTAssertEqual(steps[1].state, .failed, "and the disk has no source either")
        XCTAssertEqual(rootContents, [])
    }

    func testAnExtractedCLIPackageIsItsOwnPayload() throws {
        let dist = try package()
        try Data().write(to: dist.appendingPathComponent("micropod"))
        let steps = bootstrap(.init(start: false), packagedExecutable: dist.appendingPathComponent("micropod")).plan()
        XCTAssertEqual(steps[0].state, .pending, steps[0].detail)
        XCTAssertEqual(steps[1].state, .pending, steps[1].detail)
    }

    func testAnUnentitledVMMIsRefusedBeforeAnythingChanges() async throws {
        let dist = try package(entitled: false)
        let steps = await bootstrap(.init(payload: dist, start: false)).run()
        XCTAssertEqual(steps[0].state, .failed)
        XCTAssertTrue(
            steps[0].detail.contains("code signature") || steps[0].detail.contains("entitlement"), steps[0].detail)
        XCTAssertEqual(rootContents, [])
    }

    func testAPayloadMissingAFileSaysWhich() throws {
        let dist = try package()
        try FileManager.default.removeItem(at: dist.appendingPathComponent("mp-hvf-init.cpio"))
        let step = bootstrap(.init(payload: dist, start: false)).plan()[0]
        XCTAssertEqual(step.state, .failed)
        XCTAssertTrue(step.detail.contains("has no mp-hvf-init.cpio"), step.detail)
    }

    func testAPayloadVersionDirectoryWorksToo() async throws {
        let dist = try package(versionNames: true)
        let steps = await bootstrap(.init(payload: dist, cacheDiskBytes: 256 << 20, start: false)).run()
        XCTAssertEqual(steps[0].state, .done, steps[0].detail)
        XCTAssertEqual(layout.missingAssets(), [])
    }

    func testDiskFromWinsOverTheBaseDiskAndMustBeExt4() async throws {
        let dist = try package()
        let notExt4 = base.appendingPathComponent("plain.img")
        try Data(count: 4096).write(to: notExt4)
        let refused = bootstrap(.init(payload: dist, diskFrom: notExt4, start: false)).plan()[1]
        XCTAssertEqual(refused.state, .failed)
        XCTAssertTrue(refused.detail.contains("is not an ext4 image"), refused.detail)

        let own = base.appendingPathComponent("own.ext4")
        try ext4(own, marker: 9)
        let steps = await bootstrap(.init(payload: dist, diskFrom: own, noCacheDisk: true, start: false)).run()
        XCTAssertEqual(steps[1].state, .done, steps[1].detail)
        XCTAssertEqual(try Data(contentsOf: layout.disk).first, 9)
        XCTAssertEqual(steps[2].state, .skipped, "--no-cache-disk")
        XCTAssertFalse(HVFMachineLayout.isRegularFile(layout.cacheDisk))
    }

    /// A machine that already serves is kept running, whether or not a
    /// start was asked for (the API's second SetupMachine sends none).
    func testAServingMachineIsKeptRunningWithOrWithoutAStart() async throws {
        let dist = try package()
        _ = await bootstrap(.init(payload: dist, cacheDiskBytes: 256 << 20, start: false)).run()
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        try Data().write(to: layout.dockerSocket)
        for start in [false, true] {
            let steps = await bootstrap(.init(payload: dist, start: start)).run()
            XCTAssertEqual(steps[3].state, .kept, "start: \(start)")
            XCTAssertTrue(steps[3].detail.hasPrefix("running"), steps[3].detail)
        }
    }

    func testAnExistingInstallKeepsItsDefaultRuntime() async throws {
        let dist = try package()
        let existing = HVFMachineBootstrap.Runtimes(defaultName: { "apple" }, origin: { .existing })
        let steps = await bootstrap(.init(payload: dist, cacheDiskBytes: 256 << 20, start: false), runtimes: existing)
            .run()
        XCTAssertEqual(steps[4].state, .kept)
        XCTAssertEqual(
            steps[4].detail, "apple (kept: an existing install keeps its default; `micropod runtime use hvf` switches)")
    }

    func testSizesReadAsWholeUnits() {
        XCTAssertEqual(HVFMachineBootstrap.size(32 << 30), "32 GiB")
        XCTAssertEqual(HVFMachineBootstrap.size(3 << 29), "1.5 GiB")
        XCTAssertEqual(HVFMachineBootstrap.size(256 << 20), "256 MiB")
    }

    func testStepLinesAreNumbered() {
        XCTAssertEqual(
            HVFMachineBootstrap.line(.init(.disk, .done, "cloned from /x")), "[2/5] disk            cloned from /x")
        XCTAssertEqual(
            HVFMachineBootstrap.line(.init(.runtimeFiles, .failed, "why")), "[1/5] runtime files   failed: why")
    }

    // MARK: Installer

    func testTheInstallerCopiesADiskItCannotCloneAcrossVolumes() throws {
        let source = base.appendingPathComponent("src.ext4")
        try ext4(source, marker: 3)
        let into = base.appendingPathComponent("into.ext4")
        let crossVolume: (String, String) -> Int32 = { _, _ in EXDEV }
        XCTAssertThrowsError(
            try HVFMachineInstaller.stageDisk(
                source, into: into, root: base, copyAcrossVolumes: false, clone: crossVolume, progress: { _ in })
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("same APFS volume"), "\(error)")
        }
        var lines: [String] = []
        let copied = try HVFMachineInstaller.stageDisk(
            source, into: into, root: base, copyAcrossVolumes: true, clone: crossVolume, progress: { lines.append($0) })
        XCTAssertTrue(copied)
        XCTAssertEqual(try Data(contentsOf: into), try Data(contentsOf: source))
        XCTAssertTrue(lines.contains { $0.contains("another volume") }, "\(lines)")
        var info = stat()
        XCTAssertEqual(stat(into.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        // Any other clone failure is still refused.
        try? FileManager.default.removeItem(at: into)
        XCTAssertThrowsError(
            try HVFMachineInstaller.stageDisk(
                source, into: into, root: base, copyAcrossVolumes: true, clone: { _, _ in EACCES }, progress: { _ in }))
    }

    func testMachineInstallTakesTheBundledBaseDiskWhenNoDiskIsNamed() async throws {
        let app = try package(app: true)
        try await HVFMachineInstaller.install(HVFInstallRequest(distribution: app), layout: layout) { _ in }
        XCTAssertEqual(layout.missingAssets(), [])
        XCTAssertEqual(try Data(contentsOf: layout.disk).first, 7)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HVFMachineBootstrap.Event] = []
    func append(_ event: HVFMachineBootstrap.Event) { lock.withLock { events.append(event) } }
    var finished: [HVFMachineBootstrap.Step] {
        lock.withLock {
            events.compactMap {
                if case .finished(let step) = $0 { return step }
                return nil
            }
        }
    }
    var details: [String] {
        lock.withLock {
            events.compactMap {
                if case .detail(_, let line) = $0 { return line }
                return nil
            }
        }
    }
}
