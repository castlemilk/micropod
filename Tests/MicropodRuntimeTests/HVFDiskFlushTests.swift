import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The OS disk's flush mode (machine.json `osDiskFlush`, micropod-vmm
/// `--disk-flush-os`): opt-in only, the default unchanged (barrier on both
/// disks), and shown in `machine status`.
final class HVFDiskFlushTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-f-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func installAssets() throws {
        let layout = HVFMachineLayout(root: root)
        try FileManager.default.createDirectory(at: layout.tools, withIntermediateDirectories: true)
        for url in [layout.vmm, layout.kernel, layout.initrd, layout.disk] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
    }

    func testTheDefaultKeepsBarrierOnBothDisksAndPassesNoFlag() throws {
        try installAssets()
        let config = HVFMachineConfig()
        XCTAssertNil(config.osDiskFlush)
        XCTAssertEqual(HVFDiskFlush(config: config), HVFDiskFlush(osDisk: "barrier", cacheDisk: "barrier"))
        let argv = try HVFVMMCommand.arguments(layout: HVFMachineLayout(root: root), config: config, parentPID: 1)
        XCTAssertFalse(argv.contains("--disk-flush-os"), "\(argv)")
        XCTAssertFalse(argv.contains("--disk-flush"), "\(argv)")
    }

    func testOSDiskFlushReachesTheVMMForTheOSDiskAlone() throws {
        try installAssets()
        let config = HVFMachineConfig(osDiskFlush: "fsync")
        let argv = try HVFVMMCommand.arguments(layout: HVFMachineLayout(root: root), config: config, parentPID: 1)
        let at = try XCTUnwrap(argv.firstIndex(of: "--disk-flush-os"), "\(argv)")
        XCTAssertEqual(argv[at + 1], "fsync")
        XCTAssertFalse(argv.contains("--disk-flush"), "the cache disk keeps the VMM's default: \(argv)")
        let flush = HVFDiskFlush(config: config)
        XCTAssertEqual(flush, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        XCTAssertTrue(flush.description.contains("OS disk fsync, cache disk barrier"), flush.description)
        XCTAssertTrue(
            flush.description.contains("power loss or kernel panic can corrupt the OS disk"), flush.description)
        XCTAssertTrue(flush.description.contains("machine install --replace-disk"), flush.description)
        // A --disk-flush among the extra arguments still sets both; osDiskFlush overrides the OS disk.
        let both = HVFMachineConfig(extraArguments: ["--disk-flush", "full"], osDiskFlush: "fsync")
        XCTAssertEqual(HVFDiskFlush(config: both), HVFDiskFlush(osDisk: "fsync", cacheDisk: "full"))
        let fsyncBoth = HVFDiskFlush(config: HVFMachineConfig(extraArguments: ["--disk-flush", "fsync"]))
        XCTAssertEqual(fsyncBoth, HVFDiskFlush(osDisk: "fsync", cacheDisk: "fsync"))
        XCTAssertFalse(fsyncBoth.description.contains("keeps"), fsyncBoth.description)
        XCTAssertTrue(fsyncBoth.description.contains("corrupt the cache disk"), fsyncBoth.description)
        XCTAssertTrue(flush.description.contains("(the cache disk keeps barrier ordering)"), flush.description)
        XCTAssertEqual(HVFDiskFlush().description, "barrier (both disks)")
    }

    func testOSDiskFlushIsValidated() throws {
        for mode in HVFDiskFlush.modes {
            XCTAssertNoThrow(try HVFMachineConfig(osDiskFlush: mode).validate(), mode)
        }
        for bad in ["", "FSYNC", "fullfsync", "none"] {
            XCTAssertThrowsError(try HVFMachineConfig(osDiskFlush: bad).validate(), bad) { error in
                XCTAssertTrue("\(error)".contains("osDiskFlush"), "\(error)")
            }
        }
        XCTAssertThrowsError(try HVFMachineConfig(extraArguments: ["--disk-flush-os", "fsync"]).validate()) { error in
            XCTAssertTrue("\(error)".contains("set osDiskFlush"), "\(error)")
        }
    }

    func testMachineJSONCarriesTheKeyOnlyWhenSet() throws {
        let url = root.appendingPathComponent("machine.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try HVFMachineConfig().save(to: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("osDiskFlush"))
        try HVFMachineConfig(osDiskFlush: "fsync").save(to: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"osDiskFlush\" : \"fsync\""))
        XCTAssertEqual(try HVFMachineConfig.load(from: url).osDiskFlush, "fsync")
        // A hand-written file with a bad value is refused, not guessed at.
        try Data(#"{"schema":1,"osDiskFlush":"later"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try HVFMachineConfig.load(from: url))
    }

    func testStatusShowsWhatRunsAndWhatTheNextStartUses() {
        let fsync = HVFMachineConfig(osDiskFlush: "fsync")
        var running = HVFMachineState(phase: .running, supervisorPID: 1, vmmPID: 2, diskFlush: HVFDiskFlush())
        let pending = HVFDiskFlushStatus(config: fsync, state: running, supervisorAlive: true)
        XCTAssertEqual(pending.running, HVFDiskFlush())
        XCTAssertEqual(pending.nextStart, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        XCTAssertTrue(pending.restartPending)
        XCTAssertTrue(
            pending.summary.hasPrefix("barrier (both disks); the next start uses OS disk fsync"), pending.summary)
        XCTAssertTrue(pending.summary.hasSuffix("(restart to apply)"), pending.summary)

        running.diskFlush = HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier")
        let current = HVFDiskFlushStatus(config: fsync, state: running, supervisorAlive: true)
        XCTAssertFalse(current.restartPending)
        XCTAssertTrue(
            current.summary.hasPrefix("OS disk fsync, cache disk barrier: a host power loss"), current.summary)

        let stopped = HVFDiskFlushStatus(config: HVFMachineConfig(), state: running, supervisorAlive: false)
        XCTAssertNil(stopped.running)
        XCTAssertEqual(stopped.summary, "barrier (both disks) at the next start")

        running.diskFlush = nil
        let legacy = HVFDiskFlushStatus(config: HVFMachineConfig(), state: running, supervisorAlive: true)
        XCTAssertTrue(legacy.summary.hasPrefix("unknown"), legacy.summary)
    }

    func testTheSupervisorRecordsAndLogsTheModesItLaunchedWith() async throws {
        let launcher = FakeLauncher([.healthy])
        let log = LogRecorder()
        let layout = HVFMachineLayout(root: root)
        let supervisor = HVFMachineSupervisor(
            layout: layout, config: HVFMachineConfig(osDiskFlush: "fsync"), policy: .fast, launcher: launcher,
            inspector: FakeInspector(), readiness: { _ in launcher.currentIsReady },
            osDiskFlushSupport: { _ in .supported }, log: { log.append($0) }, pid: 4242)
        let run = Task { try await supervisor.run() }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? HVFMachineState.load(from: layout.state))?.phase != .running {
            guard ContinuousClock.now < deadline else { return XCTFail("the machine never became ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let state = try XCTUnwrap(try HVFMachineState.load(from: layout.state))
        XCTAssertEqual(state.diskFlush, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        XCTAssertNil(state.diskFlushNotInEffect)
        XCTAssertFalse(log.lines.contains { $0.hasPrefix("WARNING") }, "\(log.lines)")
        let argv = try XCTUnwrap(launcher.arguments.first)
        XCTAssertEqual(argv.indices.filter { argv[$0] == "--disk-flush-os" }.map { argv[$0 + 1] }, ["fsync"])
        XCTAssertTrue(
            log.lines.contains { $0.hasPrefix("disk flush: OS disk fsync, cache disk barrier") }, "\(log.lines)")
        supervisor.requestStop()
        _ = try await run.value
    }

    // MARK: A payload whose VMM predates --disk-flush-os

    /// The usage of a micropod-vmm built before the flag (payload 72faad28).
    private static let oldUsage = """
        Usage: micropod-vmm (--kernel <Image> | --restore-from <dir>) [--initrd <cpio>]
          [--disk <raw> [--disk-ro]] [--cache-disk <raw>] [--disk-flush barrier|full|fsync]
          [--share tag:path[:ro]] [--workspace <dir>]

        --disk-flush is the host sync both disks run when the guest flushes.
        """
    private static let newUsage = """
        Usage: micropod-vmm (--kernel <Image> | --restore-from <dir>) [--initrd <cpio>]
          [--disk <raw> [--disk-ro]] [--cache-disk <raw>] [--disk-flush barrier|full|fsync]
          [--disk-flush-os barrier|full|fsync]
        """

    /// A micropod-vmm stand-in: `--help` prints `usage` and exits `status`.
    private func writeVMM(usage: String, status: Int = 0, to url: URL? = nil) throws -> URL {
        let url = url ?? HVFMachineLayout(root: root).vmm
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let script = "#!/bin/sh\ncat <<'USAGE'\n\(usage)\nUSAGE\nexit \(status)\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testTheUsageTextSaysWhetherTheFlagExists() {
        XCTAssertEqual(HVFVMMFeatures.support(for: "--disk-flush-os", inUsage: Self.oldUsage), .unsupported)
        XCTAssertEqual(HVFVMMFeatures.support(for: "--disk-flush-os", inUsage: Self.newUsage), .supported)
        // Whole flags only: neither is a prefix match of the other.
        XCTAssertEqual(HVFVMMFeatures.support(for: "--disk-flush", inUsage: "[--disk-flush-os MODE]"), .unsupported)
        XCTAssertEqual(HVFVMMFeatures.support(for: "--disk", inUsage: "[--cache-disk <raw>]"), .unsupported)
        XCTAssertEqual(HVFVMMFeatures.support(for: "--disk-flush", inUsage: Self.oldUsage), .supported)
        XCTAssertEqual(HVFVMMFeatures.support(for: "--disk-flush-os", inUsage: "--disk-flush-os"), .supported)
    }

    func testTheBinaryIsAskedOncePerFile() throws {
        let vmm = try writeVMM(usage: Self.oldUsage)
        let before = HVFVMMFeatures.probes
        XCTAssertEqual(HVFVMMFeatures.osDiskFlush(vmm: vmm), .unsupported)
        XCTAssertEqual(HVFVMMFeatures.osDiskFlush(vmm: vmm), .unsupported)
        XCTAssertEqual(HVFVMMFeatures.probes, before + 1, "the second answer comes from the kept usage")
        // Another file at the same path (an install replaced it) is asked again.
        _ = try writeVMM(usage: Self.newUsage)
        XCTAssertEqual(HVFVMMFeatures.osDiskFlush(vmm: vmm), .supported)
        XCTAssertEqual(HVFVMMFeatures.probes, before + 2)
    }

    func testABinaryThatDoesNotAnswerIsUnknownAndNeverKept() throws {
        func unknown(_ support: HVFVMMFlagSupport, _ part: String, line: UInt = #line) {
            guard case .unknown(let reason) = support else { return XCTFail("\(support)", line: line) }
            XCTAssertTrue(reason.contains(part), reason, line: line)
        }
        let vmm = HVFMachineLayout(root: root).vmm
        unknown(HVFVMMFeatures.osDiskFlush(vmm: vmm), "No such file")
        try installAssets()  // "x", not executable
        unknown(HVFVMMFeatures.osDiskFlush(vmm: vmm), "did not run")
        _ = try writeVMM(usage: Self.newUsage, status: 2)
        unknown(HVFVMMFeatures.osDiskFlush(vmm: vmm), "exited with status 2")
        _ = try writeVMM(usage: "")
        unknown(HVFVMMFeatures.osDiskFlush(vmm: vmm), "printed no usage")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: vmm)
        let started = ContinuousClock.now
        unknown(
            HVFVMMFeatures.support(for: "--disk-flush-os", vmm: vmm, timeout: .milliseconds(200)), "did not exit")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        _ = try writeVMM(usage: Self.newUsage)
        XCTAssertEqual(HVFVMMFeatures.osDiskFlush(vmm: vmm), .supported)
    }

    func testThePlanDropsTheFlagAnOlderVMMDoesNotTake() throws {
        try installAssets()
        let layout = HVFMachineLayout(root: root)
        let fsync = HVFMachineConfig(osDiskFlush: "fsync")
        let applied = HVFDiskFlushPlan(config: fsync, support: .supported, payload: "master-new")
        XCTAssertEqual(applied.flush, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        XCTAssertTrue(applied.passesOSDiskFlag)
        XCTAssertNil(applied.notInEffect)

        let dropped = HVFDiskFlushPlan(config: fsync, support: .unsupported, payload: "master-72faad28")
        XCTAssertEqual(dropped.flush, HVFDiskFlush(), "barrier on both disks")
        XCTAssertFalse(dropped.passesOSDiskFlag)
        let reason = try XCTUnwrap(dropped.notInEffect)
        XCTAssertTrue(reason.hasPrefix("osDiskFlush fsync is not in effect: "), reason)
        XCTAssertTrue(reason.contains("payload master-72faad28 predates --disk-flush-os"), reason)
        XCTAssertTrue(reason.contains("the OS disk keeps barrier ordering"), reason)
        XCTAssertTrue(reason.contains("micropod update hvf"), reason)
        let argv = try HVFVMMCommand.arguments(
            layout: layout, config: fsync, parentPID: 1, osDiskFlushFlag: dropped.passesOSDiskFlag)
        XCTAssertFalse(argv.contains("--disk-flush-os"), "\(argv)")
        XCTAssertFalse(argv.contains("fsync"), "\(argv)")

        // A VMM that would not say gets no flag either, and the reason says why.
        let unsure = HVFDiskFlushPlan(config: fsync, support: .unknown("it did not run"), payload: "flat")
        XCTAssertFalse(unsure.passesOSDiskFlag)
        XCTAssertEqual(unsure.flush, HVFDiskFlush())
        XCTAssertTrue(try XCTUnwrap(unsure.notInEffect).contains("did not say whether it takes"), "\(unsure)")
        XCTAssertTrue(try XCTUnwrap(unsure.notInEffect).contains("it did not run"), "\(unsure)")

        // Without the flag the OS disk follows --disk-flush, which an older VMM does take.
        let both = HVFMachineConfig(extraArguments: ["--disk-flush", "full"], osDiskFlush: "fsync")
        let full = HVFDiskFlushPlan(config: both, support: .unsupported, payload: "old")
        XCTAssertEqual(full.flush, HVFDiskFlush(osDisk: "full", cacheDisk: "full"))
        XCTAssertTrue(try XCTUnwrap(full.notInEffect).contains("the OS disk keeps full ordering"), "\(full)")

        // The mode both disks have anyway: nothing to warn about, and still no flag.
        let same = HVFDiskFlushPlan(
            config: HVFMachineConfig(osDiskFlush: "barrier"), support: .unsupported, payload: "old")
        XCTAssertEqual(same, HVFDiskFlushPlan(flush: HVFDiskFlush(), passesOSDiskFlag: false, notInEffect: nil))
        // Nothing configured: no flag, nothing to say, whatever the VMM takes.
        let none = HVFDiskFlushPlan(config: HVFMachineConfig(), support: .unsupported, payload: "old")
        XCTAssertEqual(none, HVFDiskFlushPlan(flush: HVFDiskFlush(), passesOSDiskFlag: false, notInEffect: nil))
    }

    /// A micropod-vmm that predates the flag: exits 2 ("Unknown argument")
    /// when the command line carries it, boots otherwise.
    private final class OldVMMLauncher: HVFVMMLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var argv: [[String]] = []
        private var last: FakeVMM?

        func launch(executable: URL, arguments: [String]) throws -> any HVFVMMProcess {
            lock.withLock {
                argv.append(arguments)
                let script: FakeVMM.Script =
                    arguments.contains("--disk-flush-os") ? .crashImmediately(code: 2) : .healthy
                let process = FakeVMM(pid: Int32(9000 + argv.count), script: script)
                last = process
                return process
            }
        }

        var arguments: [[String]] { lock.withLock { argv } }
        var currentIsReady: Bool { lock.withLock { last }?.ready ?? false }
    }

    func testTheSupervisorStartsAnOlderVMMWithoutTheFlagAndWarns() async throws {
        try installAssets()
        try HVFMachineConfig(osDiskFlush: "fsync").save(to: HVFMachineLayout(root: root).config)
        // The supervisor asks the payload's own binary.
        _ = try writeVMM(usage: Self.oldUsage)
        let launcher = OldVMMLauncher()
        let log = LogRecorder()
        let layout = HVFMachineLayout(root: root)
        let supervisor = HVFMachineSupervisor(
            layout: layout, config: HVFMachineConfig(osDiskFlush: "fsync"), policy: .fast, launcher: launcher,
            inspector: FakeInspector(), readiness: { _ in launcher.currentIsReady }, log: { log.append($0) }, pid: 4242)
        let run = Task { try await supervisor.run() }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let state = try? HVFMachineState.load(from: layout.state)
            if state?.phase == .running { break }
            guard state?.phase != .failed, ContinuousClock.now < deadline else {
                supervisor.requestStop()
                _ = try? await run.value
                return XCTFail("the machine did not come up: \(String(describing: state)) \(log.lines)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let state = try XCTUnwrap(try HVFMachineState.load(from: layout.state))
        XCTAssertEqual(launcher.arguments.count, 1, "the first launch succeeds")
        XCTAssertFalse(try XCTUnwrap(launcher.arguments.first).contains("--disk-flush-os"))
        XCTAssertEqual(state.diskFlush, HVFDiskFlush(), "barrier on both disks")
        XCTAssertEqual(state.restartCount, 0)
        let reason = try XCTUnwrap(state.diskFlushNotInEffect)
        XCTAssertTrue(reason.contains("osDiskFlush fsync is not in effect"), reason)
        XCTAssertTrue(log.lines.contains("WARNING: \(reason)"), "\(log.lines)")
        XCTAssertFalse(log.lines.contains { $0.hasPrefix("disk flush:") }, "barrier is the default: \(log.lines)")

        // `machine status` of the running machine: barrier, and why fsync is not in effect.
        let status = HVFDiskFlushStatus.current(layout: layout, state: state, supervisorAlive: true)
        XCTAssertEqual(status.running, HVFDiskFlush())
        XCTAssertEqual(status.nextStart, HVFDiskFlush())
        XCTAssertEqual(status.configured, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        XCTAssertFalse(status.restartPending, "a restart on this payload changes nothing")
        XCTAssertTrue(
            status.summary.hasPrefix("barrier (both disks); osDiskFlush fsync is not in effect"), status.summary)
        supervisor.requestStop()
        _ = try await run.value
    }

    func testStatusSaysTheConfiguredModeIsNotInEffectAndWhy() throws {
        try installAssets()
        let layout = HVFMachineLayout(root: root)
        try HVFMachineConfig(osDiskFlush: "fsync").save(to: layout.config)
        _ = try writeVMM(usage: Self.oldUsage)
        let stopped = HVFDiskFlushStatus.current(layout: layout, state: nil, supervisorAlive: false)
        XCTAssertEqual(stopped.nextStart, HVFDiskFlush())
        XCTAssertEqual(stopped.configured, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        XCTAssertNil(stopped.nextStartRefused)
        let reason = try XCTUnwrap(stopped.notInEffect)
        XCTAssertTrue(reason.contains("payload flat predates --disk-flush-os"), reason)
        XCTAssertEqual(stopped.summary, "barrier (both disks) at the next start; \(reason)")
        let json = String(decoding: try JSONEncoder().encode(stopped), as: UTF8.self)
        XCTAssertTrue(json.contains("\"notInEffect\":\"osDiskFlush fsync is not in effect"), json)

        // A payload whose VMM takes the flag: in effect at the next start, nothing more to say.
        _ = try writeVMM(usage: Self.newUsage)
        let current = HVFDiskFlushStatus.current(layout: layout, state: nil, supervisorAlive: false)
        XCTAssertEqual(current.nextStart, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        XCTAssertNil(current.notInEffect)
        XCTAssertTrue(current.summary.hasPrefix("OS disk fsync, cache disk barrier: "), current.summary)
        XCTAssertTrue(current.summary.hasSuffix(" at the next start"), current.summary)

        // Running on the old VMM while `current` now takes the flag: a restart applies it.
        var running = HVFMachineState(phase: .running, supervisorPID: 1, vmmPID: 2, diskFlush: HVFDiskFlush())
        running.diskFlushNotInEffect = reason
        let pending = HVFDiskFlushStatus.current(layout: layout, state: running, supervisorAlive: true)
        XCTAssertTrue(pending.restartPending)
        XCTAssertNil(pending.notInEffect, "the next start applies it")
        XCTAssertTrue(
            pending.summary.hasPrefix("barrier (both disks); \(reason); the next start uses OS disk fsync"),
            pending.summary)
        XCTAssertTrue(pending.summary.hasSuffix("(restart to apply)"), pending.summary)

        // Nothing configured: the binary is not asked at all.
        try HVFMachineConfig().save(to: layout.config)
        let probes = HVFVMMFeatures.probes
        let plain = HVFDiskFlushStatus.current(
            layout: layout, state: nil, supervisorAlive: false,
            support: { _ in
                XCTFail("asked")
                return .unsupported
            })
        XCTAssertEqual(plain.summary, "barrier (both disks) at the next start")
        XCTAssertEqual(HVFVMMFeatures.probes, probes)
    }

    func testStatusSaysAnInvalidValueRefusesTheNextStart() throws {
        try installAssets()
        let layout = HVFMachineLayout(root: root)
        try Data(#"{"schema":1,"osDiskFlush":"later"}"#.utf8).write(to: layout.config)
        let stopped = HVFDiskFlushStatus.current(layout: layout, state: nil, supervisorAlive: false)
        XCTAssertNil(stopped.nextStart)
        XCTAssertNil(stopped.configured)
        XCTAssertFalse(stopped.restartPending)
        let refused = try XCTUnwrap(stopped.nextStartRefused)
        XCTAssertTrue(refused.contains("osDiskFlush must be one of barrier, full, fsync, got 'later'"), refused)
        XCTAssertEqual(stopped.summary, "the next start is refused: \(refused)")
        XCTAssertFalse(stopped.summary.contains("at the next start"), stopped.summary)

        // A machine still running on the configuration it started with keeps its line.
        let running = HVFMachineState(
            phase: .running, supervisorPID: 1, vmmPID: 2, diskFlush: HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier")
        )
        let live = HVFDiskFlushStatus.current(layout: layout, state: running, supervisorAlive: true)
        XCTAssertEqual(live.running, running.diskFlush)
        XCTAssertTrue(live.summary.hasPrefix("OS disk fsync, cache disk barrier: "), live.summary)
        XCTAssertTrue(live.summary.hasSuffix("; the next start is refused: \(refused)"), live.summary)
    }
}
