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
            inspector: FakeInspector(), readiness: { _ in launcher.currentIsReady }, log: { log.append($0) }, pid: 4242)
        let run = Task { try await supervisor.run() }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? HVFMachineState.load(from: layout.state))?.phase != .running {
            guard ContinuousClock.now < deadline else { return XCTFail("the machine never became ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let state = try XCTUnwrap(try HVFMachineState.load(from: layout.state))
        XCTAssertEqual(state.diskFlush, HVFDiskFlush(osDisk: "fsync", cacheDisk: "barrier"))
        let argv = try XCTUnwrap(launcher.arguments.first)
        XCTAssertEqual(argv.indices.filter { argv[$0] == "--disk-flush-os" }.map { argv[$0 + 1] }, ["fsync"])
        XCTAssertTrue(
            log.lines.contains { $0.hasPrefix("disk flush: OS disk fsync, cache disk barrier") }, "\(log.lines)")
        supervisor.requestStop()
        _ = try await run.value
    }
}
