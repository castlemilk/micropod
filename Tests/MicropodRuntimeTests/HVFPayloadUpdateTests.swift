import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The HVF payload updater without a VM: staging never activates, the
/// supervisor pins one payload, activation probes before it commits and
/// returns to known-good on failure, the drain fails closed, rollback is
/// idempotent and refuses to interrupt work, and one transaction runs at a
/// time. Live coverage: `scripts/e2e_hvf_update.sh`.
final class HVFPayloadUpdateTests: XCTestCase {
    private var root: URL!
    private var sources: URL!
    private var held: [HVFFileLock] = []
    private var server: FakeDockerServer?

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        let tag = UUID().uuidString.prefix(8).lowercased()
        root = URL(fileURLWithPath: "/tmp/mpu-\(tag)")
        sources = URL(fileURLWithPath: "/tmp/mpu-\(tag)-src")
    }

    override func tearDown() {
        server?.stop()
        for lock in held { lock.release() }
        // Committed payloads are read-only.
        try? HVFPayloadStore.removeTree(root)
        try? HVFPayloadStore.removeTree(sources)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }

    // MARK: Fixtures

    /// A payload source directory whose assets all carry `tag`.
    private func source(_ tag: String, vmmExitCode: Int32 = 0) throws -> URL {
        let fm = FileManager.default
        let dir = sources.appendingPathComponent(tag)
        try fm.createDirectory(at: dir.appendingPathComponent("tools/runner/bin"), withIntermediateDirectories: true)
        let vmm = dir.appendingPathComponent("micropod-vmm")
        try Data("#!/bin/sh\n# \(tag)\nexit \(vmmExitCode)\n".utf8).write(to: vmm)
        XCTAssertEqual(chmod(vmm.path, 0o755), 0)
        try Data("kernel-\(tag)".utf8).write(to: dir.appendingPathComponent("Image"))
        try Data("initrd-\(tag)".utf8).write(to: dir.appendingPathComponent("mp-hvf-init.cpio"))
        try Data("#!/bin/sh\n# start \(tag)\n".utf8).write(to: dir.appendingPathComponent("tools/runner/start.sh"))
        try Data("job-\(tag)".utf8).write(to: dir.appendingPathComponent("tools/runner/bin/job"))
        return dir
    }

    /// What `machine install` leaves: the flat payload and a disk.
    private func installFlat(_ tag: String) throws {
        let fm = FileManager.default
        let flat = HVFMachinePayload(directory: root, isVersioned: false)
        try fm.createDirectory(at: flat.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# \(tag)\n".utf8).write(to: flat.vmm)
        XCTAssertEqual(chmod(flat.vmm.path, 0o755), 0)
        try Data("kernel-\(tag)".utf8).write(to: flat.kernel)
        try Data("initrd-\(tag)".utf8).write(to: flat.initrd)
        try Data("#!/bin/sh\n".utf8).write(to: flat.tools.appendingPathComponent("runner/start.sh"))
        try Data(repeating: 0, count: 4096).write(to: layout.disk)
    }

    @discardableResult
    private func stage(_ tag: String, version: String? = nil) throws -> String {
        try HVFPayloadStore.stage(
            from: .directory(try source(tag)), version: version ?? tag, revision: "unknown", layout: layout,
            verifySignature: false)
        return try XCTUnwrap(HVFPayloadStore.status(layout: layout).stagedPath.map(lastComponent))
    }

    private func lastComponent(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    private func dir(_ id: String) -> URL { layout.versionsDirectory.appendingPathComponent(id) }

    private func canonical(_ id: String) -> String { HVFMachineLayout.canonicalPath(dir(id).path) }

    private var current: String? { HVFPayloadStore.status(layout: layout).currentPath.map(lastComponent) }
    private var knownGood: String? { HVFPayloadStore.status(layout: layout).knownGoodPath.map(lastComponent) }
    private var staged: String? { HVFPayloadStore.status(layout: layout).stagedPath.map(lastComponent) }

    private func environment(
        _ machine: FakeUpdateMachine, drain: FakeDrain = FakeDrain(), probe: FakeProbe? = nil
    ) -> HVFUpdateEnvironment {
        HVFUpdateEnvironment(
            machine: machine, drain: drain, probe: probe ?? FakeProbe(machine: machine),
            drainPollInterval: .milliseconds(10))
    }

    /// A live supervisor as `status` sees it: the lock held and `loaded` published.
    private func publishRunning(_ loaded: URL) throws {
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        held.append(try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero)))
        try HVFMachineState(
            phase: .running, supervisorPID: getpid(), loadedPayloadPath: HVFMachineLayout.canonicalPath(loaded.path)
        ).save(to: layout.state)
    }

    // MARK: Staging never activates

    func testFirstStageOverAFlatInstallImportsItAndMovesNothingThatBoots() throws {
        try installFlat("v1")
        let flatKernel = layout.kernel
        let v2 = try stage("v2", version: "0.2.0")
        let status = HVFPayloadStore.status(layout: layout)
        let legacy = try XCTUnwrap(current)
        XCTAssertTrue(legacy.hasPrefix("legacy-"), legacy)
        XCTAssertEqual(status.current?.origin, HVFPayloadManifest.flatOrigin)
        XCTAssertEqual(knownGood, legacy, "the flat install is the first update's rollback target")
        XCTAssertEqual(staged, v2)
        XCTAssertEqual(status.staged?.version, "0.2.0")
        XCTAssertEqual(try String(contentsOf: layout.kernel, encoding: .utf8), "kernel-v1", "still boots v1")
        XCTAssertEqual(layout.resolvePayload().id, legacy)
        XCTAssertEqual(try String(contentsOf: flatKernel, encoding: .utf8), "kernel-v1", "the flat copy stays")
        XCTAssertTrue(status.updatePending, "stopped: staged differs from current")

        // A second stage replaces what is staged; current and known-good stay.
        let v3 = try stage("v3")
        XCTAssertEqual(staged, v3)
        XCTAssertEqual(current, legacy)
        XCTAssertEqual(knownGood, legacy)
    }

    func testUpdatePendingWheneverAStagedPayloadDiffersFromTheRunningOne() throws {
        try installFlat("v1")
        try publishRunning(root)  // a supervisor that booted the flat layout
        XCTAssertFalse(HVFPayloadStore.status(layout: layout).updatePending)
        let v2 = try stage("v2")
        XCTAssertTrue(HVFPayloadStore.status(layout: layout).updatePending, "v2 staged, flat running")
        // Committing v2 without its boot leaves the live machine behind current: still pending.
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v2)", at: layout.currentLink)
        unlink(layout.stagedLink.path)
        XCTAssertTrue(HVFPayloadStore.status(layout: layout).updatePending, "current v2, flat running")
        for lock in held { lock.release() }
        held = []
        try publishRunning(dir(v2))
        XCTAssertFalse(HVFPayloadStore.status(layout: layout).updatePending, "runs current, nothing staged")
    }

    func testAFlatMachineIsNotBehindItsImportedCopy() throws {
        try installFlat("v1")
        try publishRunning(root)
        try HVFPayloadStore.importFlatInstallIfNeeded(layout: layout, progress: { _ in })
        XCTAssertNotNil(current)
        XCTAssertFalse(HVFPayloadStore.status(layout: layout).updatePending, "the same bytes run")
    }

    func testCommittedPayloadsAreReadOnlyAndMachineInstallCannotWriteIntoThem() async throws {
        try installFlat("v1")
        try stage("v2")
        let legacy = try XCTUnwrap(current)
        var info = stat()
        XCTAssertEqual(stat(dir(legacy).path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o222, 0, "the version directory is read-only")
        XCTAssertEqual(stat(dir(legacy).appendingPathComponent("micropod-vmm").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o555, "executable, not writable")
        XCTAssertThrowsError(try Data("tampered".utf8).write(to: layout.kernel))

        let newKernel = sources.appendingPathComponent("Image-new")
        try Data("kernel-new".utf8).write(to: newKernel)
        do {
            try await HVFMachineInstaller.install(HVFInstallRequest(kernel: newKernel), layout: layout) { _ in }
            XCTFail("machine install wrote into a versioned payload")
        } catch {
            // Refused up front, naming the way that does work.
            XCTAssertTrue(error.localizedDescription.contains("update hvf stage"), error.localizedDescription)
        }
        // And never alongside a payload transaction.
        held.append(try XCTUnwrap(try HVFFileLock.acquire(layout.updateLock, wait: .zero)))
        do {
            try await HVFMachineInstaller.install(HVFInstallRequest(cpus: 2), layout: layout) { _ in }
            XCTFail("machine install ran during a payload update")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("payload update"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: layout.kernel, encoding: .utf8), "kernel-v1", "nothing changed")
        try HVFPayloadStore.verify(payloadDirectory: dir(legacy))
    }

    func testStagingTheSamePayloadTwiceReusesItsDirectory() throws {
        let first = try stage("v2")
        let second = try stage("v2")
        XCTAssertEqual(first, second)
        let entries = try FileManager.default.contentsOfDirectory(atPath: layout.versionsDirectory.path)
        XCTAssertEqual(entries, [first], "no copy and no leftover stage directory")
    }

    // MARK: The supervisor pins one payload

    func testARelaunchKeepsThePayloadItsSupervisorStartedWith() async throws {
        try installFlat("v1")
        try stage("v2")
        let legacy = try XCTUnwrap(current)
        let launcher = FakeLauncher([.crashAfterReady(signal: SIGKILL), .crashAfterReady(signal: SIGKILL), .healthy])
        let supervisor = HVFMachineSupervisor(
            layout: layout, config: HVFMachineConfig(), policy: .fast, launcher: launcher, inspector: FakeInspector(),
            readiness: { _ in launcher.currentIsReady }, log: { _ in }, pid: 4242)
        let run = Task { try await supervisor.run() }
        try await waitFor("the first launch") { launcher.launchCount >= 1 }
        // While it runs: another stage, and `current` moved under it.
        let v3 = try stage("v3")
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v3)", at: layout.currentLink)
        try await waitFor("the second relaunch to become ready") {
            launcher.launchCount == 3 && (try? HVFMachineState.load(from: layout.state))?.phase == .running
        }
        for (executable, arguments) in zip(launcher.executables, launcher.arguments) {
            XCTAssertEqual(executable.deletingLastPathComponent().lastPathComponent, legacy)
            XCTAssertEqual(Set(assetDirectories(executable, arguments)), [dir(legacy).path])
        }
        let state = try XCTUnwrap(try HVFMachineState.load(from: layout.state))
        XCTAssertEqual(state.loadedPayloadPath, canonical(legacy))
        XCTAssertEqual(state.restartCount, 2)
        XCTAssertTrue(HVFPayloadStore.status(layout: layout).updatePending)
        supervisor.requestStop()
        _ = try await run.value
    }

    func testEveryLaunchTakesAllFourAssetsFromOnePayloadWhileCurrentMoves() async throws {
        let a = try stage("a")
        let b = try stage("b")
        try Data(repeating: 0, count: 4096).write(to: layout.disk)
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(a)", at: layout.currentLink)
        let flipping = UpdateFlag(true)
        let link = layout.currentLink
        let flipper = Thread {
            var next = b
            while flipping.value {
                try? HVFPayloadStore.atomicSymlink(destination: "versions/\(next)", at: link)
                next = next == a ? b : a
            }
        }
        flipper.start()
        defer { flipping.value = false }

        // 200 resolutions racing the flips, each built into a launch.
        for _ in 0..<200 {
            let command = try HVFMachineSupervisor.launchCommand(
                layout: layout, payload: layout.resolvePayload(), config: HVFMachineConfig(), parentPID: 1)
            XCTAssertEqual(Set(assetDirectories(command.executable, command.arguments)).count, 1)
        }

        // 200 relaunches of one supervisor while the flips continue.
        let policy = HVFSupervisorPolicy(
            readinessTimeout: .seconds(5), readinessInterval: .milliseconds(2), stopTimeout: .milliseconds(100),
            backoffBase: .milliseconds(1), backoffMax: .milliseconds(1), rapidFailureWindow: .seconds(30),
            maxRapidFailures: 1000, lockWait: .milliseconds(20))
        let launcher = FakeLauncher(Array(repeating: .crashImmediately(code: 3), count: 200) + [.healthy])
        let supervisor = HVFMachineSupervisor(
            layout: layout, config: HVFMachineConfig(), policy: policy, launcher: launcher, inspector: FakeInspector(),
            readiness: { _ in launcher.currentIsReady }, log: { _ in }, pid: 4242)
        let run = Task { try await supervisor.run() }
        try await waitFor("201 launches", timeout: .seconds(60)) {
            launcher.launchCount == 201 && (try? HVFMachineState.load(from: layout.state))?.phase == .running
        }
        flipping.value = false
        let directories = zip(launcher.executables, launcher.arguments).map { assetDirectories($0, $1) }
        XCTAssertEqual(directories.count, 201)
        XCTAssertTrue(directories.allSatisfy { Set($0).count == 1 }, "one directory per launch")
        XCTAssertEqual(Set(directories.flatMap { $0 }).count, 1, "and the same one for every relaunch")
        supervisor.requestStop()
        _ = try await run.value
    }

    /// The directories of the VMM, `--kernel`, `--initrd` and the `oci-tools` share.
    private func assetDirectories(_ executable: URL, _ arguments: [String]) -> [String] {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        let tools = arguments.first { $0.hasPrefix("oci-tools:") }.map {
            String($0.dropFirst("oci-tools:".count).dropLast(":ro".count))
        }
        return [executable.path, value(after: "--kernel"), value(after: "--initrd"), tools].map {
            URL(fileURLWithPath: $0 ?? "/missing/x").deletingLastPathComponent().path
        }
    }

    func testTheTrialIsHonouredOnlyWhileAnUpdateHoldsTheLock() throws {
        try installFlat("v1")
        let v2 = try stage("v2")
        let legacy = try XCTUnwrap(current)
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v2)", at: layout.trialLink)
        XCTAssertEqual(layout.resolvePayload().id, legacy, "a trial nobody's activation holds boots nothing")
        let lock = try XCTUnwrap(try HVFFileLock.acquire(layout.updateLock, wait: .zero))
        XCTAssertEqual(layout.resolvePayload().id, v2, "a live activation's probe boot")
        lock.release()
        _ = try HVFPayloadStore.pruneVersions(layout: layout, keep: 10)
        XCTAssertNil(HVFPayloadStore.readRelativeLink(layout.trialLink), "the next transaction drops a stale trial")
    }

    // MARK: Activation

    func testActivationBootsProbesAndOnlyThenCommits() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        let probe = FakeProbe(machine: machine)
        let v2 = try stage("v2", version: "0.2.0")
        let legacy = try XCTUnwrap(current)
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(result.action, .activated, result.detail)
        XCTAssertEqual(current, v2)
        XCTAssertEqual(knownGood, v2)
        XCTAssertNil(staged)
        XCTAssertEqual(HVFPayloadStore.status(layout: layout).previousPath.map(lastComponent), legacy)
        XCTAssertEqual(machine.boots, [v2])
        XCTAssertEqual(machine.loadedPayloadPath(), canonical(v2))
        XCTAssertEqual(probe.probed, [v2])
        XCTAssertEqual(machine.stops, 1)
        XCTAssertNotNil(result.switchoverMilliseconds)
        XCTAssertNil(HVFPayloadStore.readRelativeLink(layout.trialLink))

        let again = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(again.action, .noop)
        XCTAssertEqual(machine.stops, 1)
    }

    func testActivationReadsTheTargetPayloadBeforeItStopsTheMachine() async throws {
        // The new guest reads its tools while it boots. A staged payload is
        // a fresh copy, not in the page cache: read from disk then, it cost
        // the switchover ~50 ms.
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        let v2 = try stage("v2")
        let warmed = WarmLog()
        var env = environment(machine)
        env.warm = { dir in warmed.record("\(dir.lastPathComponent) after \(machine.stops) stop(s)") }
        let result = try await HVFPayloadStore.activate(layout: layout, environment: env)
        XCTAssertEqual(result.action, .activated, result.detail)
        XCTAssertEqual(warmed.entries, ["\(v2) after 0 stop(s)"])
        XCTAssertEqual(machine.stops, 1)
    }

    func testAnActivationThatIsDeferredReadsNothing() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        try stage("v2")
        let warmed = WarmLog()
        var env = environment(machine, drain: FakeDrain([.success(HVFWorkloads(containers: 1))]))
        env.warm = { dir in warmed.record(dir.lastPathComponent) }
        let result = try await HVFPayloadStore.activate(layout: layout, environment: env)
        XCTAssertEqual(result.action, .deferred, result.detail)
        XCTAssertEqual(warmed.entries, [])
    }

    func testWarmReadsEveryRegularFileOnceAndFollowsNoLink() throws {
        let fm = FileManager.default
        let dir = sources.appendingPathComponent("warm")
        try fm.createDirectory(at: dir.appendingPathComponent("tools/runner/bin"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: dir.appendingPathComponent("Image"))
        try Data(repeating: 2, count: 5000).write(to: dir.appendingPathComponent("tools/runner/start.sh"))
        try Data(repeating: 3, count: (2 << 20) + 17).write(
            to: dir.appendingPathComponent("tools/runner/bin/containerd"))
        let outside = sources.appendingPathComponent("outside")
        try Data(repeating: 4, count: 1 << 20).write(to: outside)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("tools/link"), withDestinationURL: outside)
        XCTAssertEqual(HVFPayloadStore.warm(payloadDirectory: dir), 3 + 5000 + (2 << 20) + 17)
        XCTAssertEqual(HVFPayloadStore.warm(payloadDirectory: sources.appendingPathComponent("absent")), 0)
    }

    func testFlatInstallStageAndAFailedActivationEndOnTheLegacyPayloadRunning() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        let probe = FakeProbe(machine: machine)
        let v2 = try stage("v2")
        let legacy = try XCTUnwrap(current)
        machine.failingBoots = [v2]
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(result.action, .rolledBack, result.detail)
        XCTAssertEqual(current, legacy)
        XCTAssertEqual(knownGood, legacy)
        // It stays staged with why it failed: the release that staged it is
        // still ahead of what runs, and a transient failure can be retried.
        XCTAssertEqual(staged, v2)
        let status = HVFPayloadStore.status(layout: layout)
        XCTAssertTrue(status.updatePending)
        XCTAssertTrue(status.lastActivationFailure?.contains("VMM error") ?? false, "\(status)")
        XCTAssertTrue(machine.isRunning())
        XCTAssertEqual(machine.loadedPayloadPath(), canonical(legacy))
        XCTAssertEqual(machine.boots, [v2, legacy])
        XCTAssertEqual(probe.probed, [legacy], "the rollback boot is probed again")
    }

    func testAProbeFailureRollsBackToKnownGoodAndReprobesIt() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        let probe = FakeProbe(machine: machine)
        let v2 = try stage("v2")
        let legacy = try XCTUnwrap(current)
        probe.failing = [v2]
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(result.action, .rolledBack)
        XCTAssertTrue(result.detail.contains("GET /micropod/caches"), result.detail)
        XCTAssertEqual(probe.probed, [v2, legacy])
        XCTAssertEqual(current, legacy)
        XCTAssertEqual(machine.loadedPayloadPath(), canonical(legacy))
    }

    func testAFailedRollbackIsReportedAsSuch() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        let probe = FakeProbe(machine: machine)
        let v2 = try stage("v2")
        let legacy = try XCTUnwrap(current)
        probe.failing = [v2, legacy]
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(result.action, .failedRollback, result.detail)
        XCTAssertEqual(current, legacy)
    }

    func testAStoppedMachineIsBootedToVerifyAndLeftStopped() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout)
        let probe = FakeProbe(machine: machine)
        let v2 = try stage("v2")
        let activated = try await HVFPayloadStore.activate(
            layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(activated.action, .activated, "never without a boot")
        XCTAssertEqual(machine.boots, [v2])
        XCTAssertEqual(probe.probed, [v2])
        XCTAssertFalse(machine.isRunning(), "stopped again")
        XCTAssertEqual(current, v2)

        let v3 = try stage("v3")
        machine.failingBoots = [v3]
        let failed = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(failed.action, .rolledBack)
        XCTAssertEqual(machine.boots, [v2, v3, v2])
        XCTAssertFalse(machine.isRunning())
        XCTAssertEqual(current, v2)
    }

    func testWithoutKnownGoodAFailedActivationSaysSo() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: layout.disk)
        let machine = FakeUpdateMachine(layout: layout)
        let v1 = try stage("v1")
        XCTAssertNil(current, "nothing to import: a fresh root")
        machine.failingBoots = [v1]
        let failed = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine))
        XCTAssertEqual(failed.action, .failed, failed.detail)
        XCTAssertNil(current)
        XCTAssertFalse(machine.isRunning())

        // A working first payload bootstraps the root through the same gate.
        let v2 = try stage("v2")
        let activated = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine))
        XCTAssertEqual(activated.action, .activated)
        XCTAssertEqual(current, v2)
        XCTAssertEqual(knownGood, v2)
        XCTAssertTrue(HVFMachineClient(layout: layout).status().installed)
    }

    // MARK: The drain fails closed

    func testADrainCheckThatFailsDefersAndStopsNothing() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        let v2 = try stage("v2")
        let drain = FakeDrain([.failure(MicropodError.message("deadlineExceeded: GET /containers/json timed out"))])
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, drain: drain))
        XCTAssertEqual(result.action, .deferred)
        XCTAssertTrue(result.detail.contains("could not confirm the machine is idle"), result.detail)
        XCTAssertEqual(machine.stops, 0)
        XCTAssertEqual(machine.starts, 0)
        XCTAssertEqual(staged, v2, "still staged")
    }

    func testAContainerListThatTimesOutIsNotZero() async throws {
        try installFlat("v1")
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        server = try FakeDockerServer(path: layout.dockerSocket.path) { request in
            if request.path == "/containers/json" { Thread.sleep(forTimeInterval: 2.5) }
            return (200, Data("[]".utf8))
        }
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        try stage("v2")
        let drain = HVFGuestWorkloadDrain(client: HVFMachineClient(layout: layout), timeout: .seconds(1))
        let env = HVFUpdateEnvironment(machine: machine, drain: drain, probe: FakeProbe(machine: machine))
        let result = try await HVFPayloadStore.activate(layout: layout, environment: env)
        XCTAssertEqual(result.action, .deferred, result.detail)
        XCTAssertEqual(machine.stops, 0)
    }

    func testTheGuestDrainCountsContainersAndReaperSessionsAndRefusesBadAnswers() async throws {
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let failMetrics = UpdateFlag(false)
        server = try FakeDockerServer(path: layout.dockerSocket.path) { request in
            switch request.path {
            case "/containers/json": return (200, Data(#"[{"Id":"a"},{"Id":"b"}]"#.utf8))
            case "/micropod/metrics":
                return failMetrics.value
                    ? (500, Data(#"{"message":"boom"}"#.utf8))
                    : (200, Data(#"{"reaper":{"active_sessions":1}}"#.utf8))
            default: return (404, Data())
            }
        }
        let drain = HVFGuestWorkloadDrain(client: HVFMachineClient(layout: layout), timeout: .seconds(2))
        let workloads = try await drain.activeWorkloads()
        XCTAssertEqual(workloads, HVFWorkloads(containers: 2, sessions: 1))
        XCTAssertEqual(workloads.total, 3)
        failMetrics.value = true
        do {
            _ = try await drain.activeWorkloads()
            XCTFail("an HTTP 500 is not a count")
        } catch {}
    }

    func testTheHealthProbeChecksPingMetricsAndCacheStatus() async throws {
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let failCaches = UpdateFlag(false)
        server = try FakeDockerServer(path: layout.dockerSocket.path) { request in
            switch request.path {
            case "/micropod/metrics": return (200, Data("{}".utf8))
            case "/micropod/caches":
                return failCaches.value
                    ? (500, Data())
                    : (200, Data(#"{"root":"/r","mountPoint":"/m","policyDigest":"d","scopes":{}}"#.utf8))
            default: return (404, Data())
            }
        }
        let probe = HVFGuestHealthProbe(client: HVFMachineClient(layout: layout), timeout: .seconds(2))
        let healthy = await probe.failure()
        XCTAssertNil(healthy)
        XCTAssertEqual(server?.requests.filter { $0.path == "/micropod/caches" }.first?.query["stats"], "0")
        failCaches.value = true
        let failure = await probe.failure()
        XCTAssertTrue(failure?.contains("/micropod/caches") == true, failure ?? "nil")
    }

    func testTheHealthProbeFailsAGuestWithoutItsAttachedCacheDisk() async throws {
        // B26 S10: a payload whose VMM dropped --cache-disk booted with shared
        // caches off and was still made current and known-good.
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let reported = UpdateBox(#""cacheDisk":{"state":"mounted","device":"/dev/vdb","mounted":true}"#)
        server = try FakeDockerServer(path: layout.dockerSocket.path) { request in
            switch request.path {
            case "/micropod/metrics": return (200, Data("{}".utf8))
            case "/micropod/caches":
                return (
                    200,
                    Data(#"{"root":"/r","mountPoint":"/m","policyDigest":"d","scopes":{},\#(reported.value)}"#.utf8)
                )
            default: return (404, Data())
            }
        }
        let probe = HVFGuestHealthProbe(client: HVFMachineClient(layout: layout), timeout: .seconds(2))
        func failure(_ inventory: String) async -> String? {
            reported.value = inventory
            return await probe.failure()
        }
        let lost =
            #""cacheDisk":{"state":"unavailable","mounted":false},"#
            + #""unavailable":"guest init found the cache disk missing or unmountable""#
        let detached = #""cacheDisk":{"state":"none","mounted":false}"#
        let unmounted = #""cacheDisk":{"state":"mounted","device":"/dev/vdb","mounted":false}"#
        let mounted = #""cacheDisk":{"state":"mounted","device":"/dev/vdb","mounted":true}"#
        let unknown = #""cacheDisk":{"mounted":false,"mountInfoError":"permission denied"}"#

        // Without caches.ext4 the stores live on the OS disk by design.
        let withoutDisk = await failure(detached)
        XCTAssertNil(withoutDisk)
        let withoutDiskUnmounted = await failure(unmounted)
        XCTAssertNil(withoutDiskUnmounted, "no disk attached: nothing to have mounted")

        FileManager.default.createFile(atPath: layout.cacheDisk.path, contents: Data())
        let healthy = await failure(mounted)
        XCTAssertNil(healthy)
        let older = await failure(#""cacheDiskless":1"#)
        XCTAssertNil(older, "an engine that predates the report cannot say; it is not failed for that")
        let cannotTell = await failure(unknown)
        XCTAssertNil(cannotTell)
        for (inventory, reason) in [
            (lost, "shared caches are off"), (detached, "did not mount"), (unmounted, "did not mount"),
        ] {
            let failed = await failure(inventory)
            XCTAssertTrue(failed?.contains(reason) == true, "\(inventory): \(failed ?? "passed")")
        }
        try FileManager.default.removeItem(at: layout.cacheDisk)
        let lostWithoutDisk = await failure(lost)
        XCTAssertTrue(
            lostWithoutDisk?.contains("shared caches are off") == true,
            "the guest says so itself: \(lostWithoutDisk ?? "")")
    }

    func testBusyWorkloadsDeferUnlessTheyDrainInTimeAndForceSkipsTheCheck() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        try stage("v2")
        let busy = FakeDrain([.success(HVFWorkloads(containers: 1))])
        let deferred = try await HVFPayloadStore.activate(
            layout: layout, environment: environment(machine, drain: busy))
        XCTAssertEqual(deferred.action, .deferred)
        XCTAssertEqual(deferred.activeContainers, 1)
        XCTAssertEqual(machine.stops, 0)

        let draining = FakeDrain([
            .success(HVFWorkloads(containers: 1)), .success(HVFWorkloads(containers: 0, sessions: 1)),
            .success(HVFWorkloads(containers: 0)),
        ])
        let drained = try await HVFPayloadStore.activate(
            layout: layout, drainTimeout: .seconds(10), environment: environment(machine, drain: draining))
        XCTAssertEqual(drained.action, .activated, drained.detail)
        XCTAssertEqual(draining.calls, 3)

        let v3 = try stage("v3")
        let ignored = FakeDrain([.success(HVFWorkloads(containers: 4))])
        let forced = try await HVFPayloadStore.activate(
            layout: layout, force: true, environment: environment(machine, drain: ignored))
        XCTAssertEqual(forced.action, .activated)
        XCTAssertEqual(ignored.calls, 0)
        XCTAssertEqual(current, v3)
    }

    // MARK: Rollback

    /// v1 current and known-good while the machine runs `running` (what an
    /// activator that died after its trial boot leaves).
    private func machineAhead(stopDelay: Duration = .zero) throws -> (FakeUpdateMachine, v1: String, v2: String) {
        let v1 = try stage("v1")
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v1)", at: layout.currentLink)
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v1)", at: layout.knownGoodLink)
        let v2 = try stage("v2")
        return (FakeUpdateMachine(layout: layout, runningOn: dir(v2), stopDelay: stopDelay), v1, v2)
    }

    func testTwoConcurrentRollbacksRunOneRestartAndTheOtherIsBusy() async throws {
        let (machine, v1, _) = try machineAhead(stopDelay: .seconds(1))
        let env = environment(machine)
        let layout = self.layout
        let first = Task { () -> Result<HVFActivationResult, any Error> in
            do { return .success(try await HVFPayloadStore.rollback(layout: layout, environment: env)) } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let second = Task { () -> Result<HVFActivationResult, any Error> in
            do { return .success(try await HVFPayloadStore.rollback(layout: layout, environment: env)) } catch {
                return .failure(error)
            }
        }
        let results = [await first.value, await second.value]
        let actions = results.compactMap { try? $0.get().action }
        let busy = results.compactMap { result -> String? in
            guard case .failure(let error) = result else { return nil }
            return error.localizedDescription
        }
        XCTAssertEqual(actions, [.rolledBack])
        XCTAssertEqual(busy.count, 1)
        XCTAssertTrue(busy.first?.contains("in progress") == true, busy.first ?? "")
        XCTAssertEqual(machine.stops, 1)
        XCTAssertEqual(machine.starts, 1)
        XCTAssertEqual(machine.loadedPayloadPath(), canonical(v1))

        // A replayed request changes nothing.
        let replay = try await HVFPayloadStore.rollback(layout: layout, environment: env)
        XCTAssertEqual(replay.action, .noop)
        XCTAssertEqual(machine.stops, 1)
    }

    func testRollbackRefusesToInterruptRunningContainersUnlessForced() async throws {
        let (machine, v1, v2) = try machineAhead()
        let busy = FakeDrain([.success(HVFWorkloads(containers: 1))])
        let refused = try await HVFPayloadStore.rollback(layout: layout, environment: environment(machine, drain: busy))
        XCTAssertEqual(refused.action, .deferred)
        XCTAssertEqual(refused.activeContainers, 1)
        XCTAssertEqual(machine.stops, 0)
        XCTAssertEqual(machine.loadedPayloadPath(), canonical(v2))

        let failing = FakeDrain([.failure(MicropodError.message("unavailable: no answer"))])
        let unknown = try await HVFPayloadStore.rollback(
            layout: layout, environment: environment(machine, drain: failing))
        XCTAssertEqual(unknown.action, .deferred, "an unknown count is not zero")
        XCTAssertEqual(machine.stops, 0)

        let forced = try await HVFPayloadStore.rollback(
            layout: layout, force: true, environment: environment(machine, drain: busy))
        XCTAssertEqual(forced.action, .rolledBack)
        XCTAssertEqual(machine.stops, 1)
        XCTAssertEqual(machine.loadedPayloadPath(), canonical(v1))
    }

    func testRollbackTargetsKnownGoodByNameSoRepeatingItChangesNothing() async throws {
        // `current` on a payload that never booted, as the old swap-based stage left it.
        let v1 = try stage("v1")
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v1)", at: layout.knownGoodLink)
        let v2 = try stage("v2")
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v2)", at: layout.currentLink)
        let machine = FakeUpdateMachine(layout: layout)
        let first = try await HVFPayloadStore.rollback(layout: layout, environment: environment(machine))
        XCTAssertEqual(first.action, .rolledBack)
        XCTAssertEqual(current, v1)
        let second = try await HVFPayloadStore.rollback(layout: layout, environment: environment(machine))
        XCTAssertEqual(second.action, .noop)
        XCTAssertEqual(current, v1, "not swapped back to v2")
        XCTAssertEqual(machine.starts, 0, "a stopped machine is not booted for a rollback")
    }

    func testARollbackWhoseBootFailsTheProbeIsAFailedRollback() async throws {
        let (machine, v1, _) = try machineAhead()
        let probe = FakeProbe(machine: machine)
        probe.failing = [v1]
        let result = try await HVFPayloadStore.rollback(
            layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(result.action, .failedRollback, result.detail)
        XCTAssertEqual(probe.probed, [v1])
    }

    func testRollbackWithoutKnownGoodRefuses() async throws {
        try installFlat("v1")
        do {
            _ = try await HVFPayloadStore.rollback(
                layout: layout, environment: environment(FakeUpdateMachine(layout: layout)))
            XCTFail("rolled back to nothing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no known-good"), error.localizedDescription)
        }
    }

    // MARK: Stores the updater before known-good wrote

    /// Its `stage` moved `current` straight to the new payload, kept the old
    /// one at `previous`, recorded no staged or known-good payload, and left
    /// the version directories writable.
    private func oldUpdaterStore() throws -> (ran: String, pending: String) {
        let ran = try stage("w1")
        let pending = try stage("x2")
        unlink(layout.stagedLink.path)
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(pending)", at: layout.currentLink)
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(ran)", at: layout.previousLink)
        HVFPayloadStore.setReadOnly(dir(ran), false)
        HVFPayloadStore.setReadOnly(dir(pending), false)
        XCTAssertNil(knownGood)
        return (ran, pending)
    }

    func testAPayloadTheOldUpdaterLeftPendingIsAppliedThroughTheProbe() async throws {
        let (ran, pending) = try oldUpdaterStore()
        try publishRunning(dir(ran))
        let machine = FakeUpdateMachine(layout: layout, runningOn: dir(ran))
        let probe = FakeProbe(machine: machine)
        XCTAssertTrue(HVFPayloadStore.status(layout: layout).updatePending, "status points at apply")
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(result.action, .activated, result.detail)
        XCTAssertEqual(machine.boots, [pending])
        XCTAssertEqual(probe.probed, [pending])
        XCTAssertEqual(current, pending)
        XCTAssertEqual(knownGood, pending)
        var info = stat()
        for id in [ran, pending] {
            XCTAssertEqual(stat(dir(id).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o222, 0, "\(id) is read-only once migrated")
        }
    }

    func testRollbackOnAnOldStoreReturnsToWhatRanAndKeepsThePendingPayloadStaged() async throws {
        let (ran, pending) = try oldUpdaterStore()
        try publishRunning(dir(ran))
        let machine = FakeUpdateMachine(layout: layout, runningOn: dir(ran))
        let result = try await HVFPayloadStore.rollback(layout: layout, environment: environment(machine))
        XCTAssertEqual(result.action, .noop, "the machine already runs what is now known-good: \(result.detail)")
        XCTAssertEqual(machine.stops, 0)
        XCTAssertEqual(current, ran)
        XCTAssertEqual(knownGood, ran)
        XCTAssertEqual(staged, pending)
    }

    func testAStoppedOldStoreBootsWhatLastRanNotTheUnverifiedPayload() throws {
        let (ran, pending) = try oldUpdaterStore()
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        try HVFMachineState(
            phase: .stopped, supervisorPID: 1, loadedPayloadPath: HVFMachineLayout.canonicalPath(dir(ran).path)
        ).save(to: layout.state)
        XCTAssertEqual(layout.resolvePayload().id, pending, "before: a start would boot the unverified payload")
        HVFPayloadStore.migrateLegacyStoreBeforeBoot(layout: layout)
        XCTAssertEqual(layout.resolvePayload().id, ran)
        XCTAssertEqual(knownGood, ran)
        XCTAssertEqual(staged, pending)
        XCTAssertTrue(HVFPayloadStore.status(layout: layout).updatePending)
    }

    func testAnOldStoreWithNoRecordFallsBackToPreviousAndOneThatRunsCurrentKeepsIt() throws {
        let (ran, pending) = try oldUpdaterStore()
        try HVFPayloadStore.pruneVersions(layout: layout, keep: 5)
        XCTAssertEqual(current, ran, "nothing recorded what ran: previous")
        XCTAssertEqual(staged, pending)
        try HVFPayloadStore.removeTree(root)

        let (_, runs) = try oldUpdaterStore()
        try publishRunning(dir(runs))
        try HVFPayloadStore.pruneVersions(layout: layout, keep: 5)
        XCTAssertEqual(current, runs)
        XCTAssertEqual(knownGood, runs, "what the rig serves with")
        XCTAssertNil(staged)
    }

    // MARK: Leaving the machine as it was found

    func testAMachineSomeoneStartsUsingDuringTheProbeBootIsLeftRunning() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout)
        let v2 = try stage("v2")
        // Stopped at the start, so the first drain check is the one before stopping it again.
        let busy = FakeDrain([.success(HVFWorkloads(containers: 1))])
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, drain: busy))
        XCTAssertEqual(result.action, .activated, result.detail)
        XCTAssertTrue(result.detail.contains("left running"), result.detail)
        XCTAssertTrue(machine.isRunning())
        XCTAssertEqual(machine.stops, 0)
        XCTAssertEqual(current, v2)
    }

    func testAMachineThatCameUpOnTheFallbackIsProbedNotRestarted() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        machine.ignoresTrial = true  // a supervisor that started before `trial` existed
        let v2 = try stage("v2")
        let legacy = try XCTUnwrap(current)
        let probe = FakeProbe(machine: machine)
        let result = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(result.action, .rolledBack, result.detail)
        XCTAssertTrue(result.detail.contains("not "), result.detail)
        XCTAssertEqual(machine.boots, [legacy], "one boot, onto the fallback; no second restart")
        XCTAssertEqual(machine.stops, 1)
        XCTAssertEqual(probe.probed, [legacy])
        XCTAssertEqual(staged, v2)
    }

    func testRollbackPreviousGoesBackPastKnownGoodThroughTheProbe() async throws {
        try installFlat("v1")
        let machine = FakeUpdateMachine(layout: layout, runningOn: root)
        let probe = FakeProbe(machine: machine)
        let v2 = try stage("v2")
        let legacy = try XCTUnwrap(current)
        _ = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(knownGood, v2)
        let noop = try await HVFPayloadStore.rollback(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(noop.action, .noop, "known-good is v2 now")

        let manifest = try HVFPayloadStore.restagePrevious(layout: layout)
        XCTAssertEqual(manifest.origin, HVFPayloadManifest.flatOrigin)
        XCTAssertEqual(staged, legacy)
        let back = try await HVFPayloadStore.activate(layout: layout, environment: environment(machine, probe: probe))
        XCTAssertEqual(back.action, .activated, back.detail)
        XCTAssertEqual(current, legacy)
        XCTAssertEqual(knownGood, legacy)
        XCTAssertEqual(probe.probed.last, legacy)
        XCTAssertEqual(HVFPayloadStore.status(layout: layout).previousPath.map(lastComponent), v2)
    }

    // MARK: One transaction at a time; prune

    func testStageIsBusyWhileAnotherTransactionHoldsTheLock() throws {
        try FileManager.default.createDirectory(at: layout.versionsDirectory, withIntermediateDirectories: true)
        held.append(try XCTUnwrap(try HVFFileLock.acquire(layout.updateLock, wait: .zero)))
        XCTAssertThrowsError(try stage("v1")) { error in
            XCTAssertTrue(error.localizedDescription.contains("in progress"), error.localizedDescription)
        }
        XCTAssertThrowsError(try HVFPayloadStore.pruneVersions(layout: layout))
    }

    func testPruneNeverRemovesCurrentStagedKnownGoodOrTheRunningPayload() throws {
        try installFlat("v1")
        let v2 = try stage("v2")
        let legacy = try XCTUnwrap(current)
        let v3 = try stage("v3")
        let v4 = try stage("v4")
        let v5 = try stage("v5")
        try HVFPayloadStore.atomicSymlink(destination: "versions/\(v4)", at: layout.knownGoodLink)
        let leftover = layout.versionsDirectory.appendingPathComponent(".stage-interrupted")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try publishRunning(dir(v2))

        let removed = try HVFPayloadStore.pruneVersions(layout: layout, keep: 1)
        XCTAssertEqual(removed, [v3], "v2 runs, v4 is known-good, v5 staged, legacy current")
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: layout.versionsDirectory.path))
        XCTAssertEqual(left, [legacy, v2, v4, v5], "and the interrupted stage is gone")

        for lock in held { lock.release() }
        held = []
        XCTAssertEqual(try HVFPayloadStore.pruneVersions(layout: layout, keep: 1), [v2], "stopped: v2 can go")
        XCTAssertEqual(knownGood, v4)
        XCTAssertEqual(current, legacy)
        XCTAssertEqual(staged, v5)
        XCTAssertEqual(try HVFPayloadStore.pruneVersions(layout: layout, keep: 0), [], "nothing else is unprotected")
    }
}

// MARK: - Fakes

final class UpdateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A machine whose start resolves its payload the way a new supervisor does
/// (`resolvePayload()`, which honours an activation's trial) and boots it
/// unless its id is in `failingBoots` (a VMM that exits 1).
final class FakeUpdateMachine: HVFUpdateMachine, @unchecked Sendable {
    let layout: HVFMachineLayout
    let stopDelay: Duration
    private let lock = NSLock()
    private var running: String?
    private var trialIgnored = false
    private var stopCount = 0
    private var startCount = 0
    private var booted: [String] = []
    private var failing: Set<String> = []

    init(layout: HVFMachineLayout, runningOn payload: URL? = nil, stopDelay: Duration = .zero) {
        self.layout = layout
        self.stopDelay = stopDelay
        running = payload.map { HVFMachineLayout.canonicalPath($0.path) }
    }

    var failingBoots: Set<String> {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    /// Boots `current` even during an activation, as a supervisor that
    /// resolved its payload before `trial` existed does.
    var ignoresTrial: Bool {
        get { lock.withLock { trialIgnored } }
        set { lock.withLock { trialIgnored = newValue } }
    }
    var stops: Int { lock.withLock { stopCount } }
    var starts: Int { lock.withLock { startCount } }
    var boots: [String] { lock.withLock { booted } }

    func isRunning() -> Bool { lock.withLock { running != nil } }

    func loadedPayloadPath() -> String? { lock.withLock { running } }

    func stop() async throws {
        if stopDelay > .zero { try await Task.sleep(for: stopDelay) }
        lock.withLock {
            stopCount += 1
            running = nil
        }
    }

    func start() async throws {
        var payload = layout.resolvePayload()
        if ignoresTrial, let current = HVFPayloadStore.resolveVersion(layout.currentLink, in: layout) {
            payload = HVFMachinePayload(directory: current, isVersioned: true)
        }
        let fails = lock.withLock { () -> Bool in
            startCount += 1
            booted.append(payload.isVersioned ? payload.id : HVFMachinePayload.flatID)
            return failing.contains(payload.id)
        }
        if fails {
            throw MicropodError.message(
                "unavailable: hvf machine failed to start: micropod-vmm exited with status 1: VMM error")
        }
        lock.withLock { running = payload.canonicalPath }
    }
}

/// Fails for the payload ids in `failing`; records what it probed.
final class FakeProbe: HVFHealthProbing, @unchecked Sendable {
    let machine: FakeUpdateMachine
    private let lock = NSLock()
    private var failingIDs: Set<String> = []
    private var seen: [String] = []

    init(machine: FakeUpdateMachine) { self.machine = machine }

    var failing: Set<String> {
        get { lock.withLock { failingIDs } }
        set { lock.withLock { failingIDs = newValue } }
    }
    var probed: [String] { lock.withLock { seen } }

    func failure() async -> String? {
        let id = machine.loadedPayloadPath().map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
        let fails = lock.withLock { () -> Bool in
            seen.append(id)
            return failingIDs.contains(id)
        }
        return fails ? "GET /micropod/caches answered HTTP 500" : nil
    }
}

/// Answers in order; the last answer repeats.
final class FakeDrain: HVFDrainCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [Result<HVFWorkloads, any Error>]
    private var count = 0

    init(_ answers: [Result<HVFWorkloads, any Error>] = [.success(HVFWorkloads(containers: 0))]) {
        self.answers = answers
    }

    var calls: Int { lock.withLock { count } }

    func activeWorkloads() async throws -> HVFWorkloads {
        let answer = lock.withLock { () -> Result<HVFWorkloads, any Error> in
            defer { count += 1 }
            return answers[min(count, answers.count - 1)]
        }
        return try answer.get()
    }
}

/// What an activation's `warm` was called with.
final class WarmLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ entry: String) { lock.withLock { seen.append(entry) } }
    var entries: [String] { lock.withLock { seen } }
}

extension HVFPayloadUpdateTests {
    fileprivate func waitFor(_ what: String, timeout: Duration = .seconds(10), _ condition: () throws -> Bool)
        async throws
    {
        let deadline = ContinuousClock.now + timeout
        while !(try condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
