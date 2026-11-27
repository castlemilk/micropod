import Foundation
import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodCLI

/// `micropod setup` (routing, flags, the printed steps) and `micropod
/// runtime ls`'s fresh-install story. Throwaway roots only; nothing starts.
final class SetupCommandsTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: "/tmp").appendingPathComponent("mpsc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    func testSetupRoutesBeforeServicesWithGlobalFlagsAnywhere() {
        XCTAssertEqual(SetupCommands.route(["--json", "setup", "--dry-run"])?.args, ["--dry-run"])
        XCTAssertEqual(SetupCommands.route(["--json", "setup"])?.json, true)
        XCTAssertEqual(SetupCommands.route(["setup", "--no-color", "--no-start"])?.args, ["--no-start"])
        XCTAssertEqual(SetupCommands.route(["--cli", "/x/container", "setup"])?.args, [])
        XCTAssertNil(SetupCommands.route(["machine", "install"]))
        XCTAssertNil(DockerCommands.route(["setup"]))
        XCTAssertNil(MachineCommands.route(["setup"]))
        XCTAssertTrue(MicropodCLI.helpText.contains("setup [--payload <app|dir>]"))
        XCTAssertFalse(MicropodCLI.helpText.hasPrefix("micropod — CLI for the Apple container runtime"))
    }

    func testFlags() throws {
        let parsed = try SetupCommands.parse([
            "--payload", "/Applications/Micropod.app", "--disk-image", "default", "--disk-size", "16g",
            "--cache-disk-size", "8g", "--cpus", "2", "--memory-mib", "2048", "--no-start", "--use", "--autostart",
        ])
        XCTAssertEqual(parsed.options.payload?.path, "/Applications/Micropod.app")
        XCTAssertEqual(parsed.options.diskImage, HVFMachineInstaller.defaultDiskImage)
        XCTAssertEqual(parsed.options.diskBytes, 16 << 30)
        XCTAssertEqual(parsed.options.cacheDiskBytes, 8 << 30)
        XCTAssertEqual(parsed.options.cpus, 2)
        XCTAssertEqual(parsed.options.memoryMiB, 2048)
        XCTAssertFalse(parsed.options.start)
        XCTAssertNil(parsed.options.startedBy, "--no-start: nothing starts it")
        XCTAssertTrue(parsed.docker, "--use implies the docker context")
        XCTAssertTrue(parsed.use)
        XCTAssertTrue(parsed.autostart)

        let launchd = try SetupCommands.parse(["--autostart"])
        XCTAssertFalse(launchd.options.start, "launchd starts it once the LaunchAgent loads, not setup first")
        XCTAssertEqual(launchd.options.startedBy, "launchd starts it (--autostart, below)")

        let plain = try SetupCommands.parse([])
        XCTAssertNil(plain.options.diskImage, "nothing is downloaded unless asked")
        XCTAssertNil(plain.options.cacheDiskBytes)
        XCTAssertTrue(plain.options.start)
        XCTAssertFalse(plain.docker || plain.use || plain.autostart, "nothing is selected or loaded unasked")

        for bad in [
            ["--disk-from", "/a.ext4", "--disk-image", "default"], ["--no-cache-disk", "--cache-disk-size", "1g"],
            ["--cpus", "0"], ["extra"], ["--disk-size", "lots"],
        ] {
            XCTAssertThrowsError(try SetupCommands.parse(bad), "\(bad)") { XCTAssertTrue($0 is UsageError, "\(bad)") }
        }
        XCTAssertThrowsError(try SetupCommands.parse(["--help"])) { XCTAssertTrue($0 is SetupCommands.Help) }
    }

    /// A root whose machine is installed already (stand-in files), so every
    /// install step is kept and nothing is started.
    private func installedRoot() throws -> HVFMachineLayout {
        let layout = HVFMachineLayout(root: base.appendingPathComponent("hvf"))
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        for url in [layout.vmm, layout.kernel, layout.initrd, layout.tools.appendingPathComponent("runner/start.sh")] {
            try Data("x".utf8).write(to: url)
        }
        chmod(layout.vmm.path, 0o755)
        var disk = Data(count: 4096)
        disk[1024 + 0x38] = 0x53
        disk[1024 + 0x39] = 0xEF
        try disk.write(to: layout.disk)
        return layout
    }

    private func run(_ args: [String], layout: HVFMachineLayout, json: Bool = false) async throws -> (
        code: Int32, out: [String], err: [String]
    ) {
        let parsed = try SetupCommands.parse(args)
        let bootstrap = HVFMachineBootstrap(
            layout: layout, options: parsed.options, environment: ["MICROPOD_HVF_ROOT": layout.root.path],
            packagedExecutable: nil,
            runtimes: .init(defaultName: { "hvf" }, origin: { .fresh }))
        let out = Lines()
        let err = Lines()
        let code = await SetupCommands.run(
            bootstrap, parsed: parsed,
            environment: [
                "MICROPOD_HVF_ROOT": layout.root.path, "DOCKER_CONFIG": base.appendingPathComponent("docker").path,
            ],
            json: json, out: { out.append($0) }, err: { err.append($0) })
        return (code, out.lines, err.lines)
    }

    func testAnInstalledMachineKeepsEveryStepAndSuggestsTheNextCommands() async throws {
        let layout = try installedRoot()
        let result = try await run(["--no-start"], layout: layout)
        XCTAssertEqual(result.code, ExitCode.ok, "\(result)")
        XCTAssertEqual(
            Array(result.out.dropFirst()),
            [
                "[1/5] runtime files   present, kept",
                "[2/5] disk            present, kept",
                "[3/5] cache disk      none (the installed machine has none; --cache-disk-size 32g adds one)",
                "[4/5] start           not started (--no-start): `micropod machine start` boots it",
                "[5/5] default runtime hvf",
                "next: micropod machine start    micropod docker install --use    micropod machine autostart on",
            ])
    }

    func testADryRunCountsTheExtraStepsAndFailsWhenAStepWould() async throws {
        let layout = HVFMachineLayout(root: base.appendingPathComponent("empty"))
        let result = try await run(["--dry-run", "--use", "--autostart"], layout: layout)
        XCTAssertEqual(result.code, ExitCode.failure, "no package: the runtime files would fail")
        XCTAssertTrue(result.out.contains { $0.hasPrefix("[1/7] runtime files   failed: pass --payload") }, "\(result)")
        XCTAssertTrue(result.out.contains { $0.hasPrefix("[2/7] disk            failed: no base disk") }, "\(result)")
        XCTAssertTrue(result.out.contains("[6/7] autostart       pending"), "\(result.out)")
        XCTAssertTrue(result.out.contains("[7/7] docker          pending"), "\(result.out)")
        XCTAssertTrue(
            result.out.contains("[4/7] start           launchd starts it (--autostart, below)"), "\(result.out)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.root.path), "a dry run writes nothing")
    }

    func testAFailedSetupExitsNonZeroAndSaysWhere() async throws {
        let layout = HVFMachineLayout(root: base.appendingPathComponent("empty"))
        let result = try await run([], layout: layout)
        XCTAssertEqual(result.code, ExitCode.failure)
        XCTAssertEqual(result.err.first?.hasPrefix("error: setup stopped at runtime files: pass --payload"), true)
        let json = try await run([], layout: layout, json: true)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.out.joined().utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual((object["steps"] as? [[String: Any]])?.count, 5)
    }

    // MARK: runtime ls

    private func runtime(
        _ name: String, default isDefault: Bool = false, enabled: Bool, available: Bool, reason: String = ""
    )
        -> Micropod_V1_RuntimeInfo
    {
        .with {
            $0.name = name
            $0.kind = "microvm"
            $0.default = isDefault
            $0.enabled = enabled
            $0.available = available
            $0.reason = reason
            $0.endpoint = "unix:///x.sock"
        }
    }

    func testRuntimeListingSaysAppleIsOptInAndHowToSetUpTheMachine() {
        let response = Micropod_V1_ListRuntimesResponse.with {
            $0.default = "hvf"
            $0.runtimes = [
                runtime("apple", enabled: false, available: true),
                runtime("sandbox", enabled: true, available: true),
                runtime(
                    "hvf", default: true, enabled: true, available: false,
                    reason: "HVF machine not installed under /r: missing disk.ext4 — run `micropod setup`"),
            ]
        }
        let fresh = RuntimeCommands.listing(response, origin: .fresh)
        let apple = fresh.split(separator: "\n").first { $0.contains(" apple ") }.map(String.init) ?? ""
        XCTAssertTrue(apple.contains("opt-in"), apple)
        XCTAssertTrue(apple.contains("`micropod runtime enable apple`"), apple)
        let hvf = fresh.split(separator: "\n").first { $0.hasPrefix("* hvf") }.map(String.init) ?? ""
        XCTAssertTrue(hvf.contains("not set up: `micropod setup`"), hvf)
        XCTAssertTrue(
            fresh.hasSuffix("default: hvf (chosen for a fresh install; `micropod runtime use <name>` changes it)"),
            fresh)

        // An existing install reads as before, plus where the default stands.
        let existing = RuntimeCommands.listing(response, origin: .existing)
        XCTAssertFalse(existing.contains("opt-in"))
        XCTAssertTrue(existing.hasSuffix("default: hvf (`micropod runtime use <name>` changes it)"), existing)
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
