import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The hvf machine without a VM: layout, config and argv, the supervisor
/// state machine over a scripted fake VMM, orphan decisions, the installer
/// and the engine's probe states. Live coverage: `scripts/e2e_hvf.sh`.
final class HVFMachineTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-t-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }

    /// Placeholder assets: enough for probes and argv, never booted.
    private func installPlaceholders() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
    }

    // MARK: Layout

    func testLayoutPathsAndRootResolution() {
        XCTAssertEqual(layout.dockerSocket.path, root.path + "/run/docker.sock")
        XCTAssertEqual(layout.state.path, root.path + "/run/state.json")
        XCTAssertEqual(layout.supervisorLock.path, root.path + "/run/supervisor.lock")
        XCTAssertEqual(layout.consoleLog.path, root.path + "/logs/console.log")
        XCTAssertEqual(layout.dockerEndpoint, "unix://\(root.path)/run/docker.sock")
        XCTAssertEqual(layout.buildkitEndpoint, "unix://\(root.path)/run/buildkit.sock")
        XCTAssertEqual(HVFMachineLayout(environment: ["MICROPOD_HVF_ROOT": "/x/y"]).root.path, "/x/y")
        XCTAssertTrue(HVFMachineLayout(environment: [:]).root.path.hasSuffix("/.micropod/hvf"))
    }

    func testMissingAssetsNamesEachPiece() throws {
        XCTAssertEqual(layout.missingAssets(), ["micropod-vmm", "Image", "mp-hvf-init.cpio", "disk.ext4", "tools/"])
        try installPlaceholders()
        XCTAssertEqual(layout.missingAssets(), [])
        try FileManager.default.removeItem(at: layout.tools.appendingPathComponent("runner/start.sh"))
        XCTAssertEqual(layout.missingAssets(), ["tools/runner/start.sh"])
    }

    func testSocketPathLengthAndColonsAreValidated() {
        let long = HVFMachineLayout(root: URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 90)))
        XCTAssertThrowsError(try long.validatePaths()) {
            XCTAssertTrue($0.localizedDescription.contains("unix sockets allow 103"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try HVFMachineLayout(root: URL(fileURLWithPath: "/tmp/a:b")).validatePaths())
        XCTAssertNoThrow(try layout.validatePaths())

        // run/docker.sock fits in 102 bytes; run/buildkit.sock (104) does not.
        let edge = HVFMachineLayout(root: URL(fileURLWithPath: "/tmp/" + String(repeating: "e", count: 81)))
        XCTAssertEqual(edge.dockerSocket.path.utf8.count, 102)
        XCTAssertThrowsError(try edge.validatePaths(), "the BuildKit socket is validated like the Docker one") {
            XCTAssertTrue($0.localizedDescription.contains("/run/buildkit.sock is 104 bytes"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try HVFVMMCommand.arguments(layout: edge, config: HVFMachineConfig(), parentPID: 1))
    }

    func testBuildKitIsDetectedFromTheInstalledBundle() throws {
        try installPlaceholders()
        XCTAssertEqual(layout.missingBuildKitFiles(), ["runner/bin/buildkitd", "runner/buildkitd.toml"])
        let fm = FileManager.default
        let daemon = layout.tools.appendingPathComponent("runner/bin/buildkitd")
        try fm.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: daemon.path, contents: Data("x".utf8)))
        XCTAssertEqual(
            layout.missingBuildKitFiles(), ["runner/bin/buildkitd", "runner/buildkitd.toml"],
            "a buildkitd that is not executable does not count")
        XCTAssertEqual(chmod(daemon.path, 0o755), 0)
        XCTAssertEqual(layout.missingBuildKitFiles(), ["runner/buildkitd.toml"])
        XCTAssertTrue(
            fm.createFile(atPath: layout.tools.appendingPathComponent("runner/buildkitd.toml").path, contents: Data()))
        XCTAssertEqual(layout.missingBuildKitFiles(), [])
        let capabilities = HVFMachineCapabilities(layout: layout, config: HVFMachineConfig(), engine: nil)
        XCTAssertTrue(capabilities.buildkit)
        XCTAssertEqual(capabilities.buildkitMissing, [])
    }

    func testCapabilitiesReportThePublishedPathAndEngineRange() throws {
        func path(_ config: HVFMachineConfig) -> String {
            HVFMachineCapabilities(layout: layout, config: config, engine: nil).publishedPath
        }
        XCTAssertEqual(path(HVFMachineConfig()), "macvlan", "guest init's default with --published-net")
        XCTAssertEqual(path(HVFMachineConfig(publishedNet: false)), "off")
        XCTAssertEqual(path(HVFMachineConfig(kernelArguments: ["mp.published_path=bridge"])), "bridge")
        XCTAssertEqual(
            path(HVFMachineConfig(kernelArguments: ["mp.published_path=bridge", "mp.published_path=default"])),
            "default", "the last one wins, as on a kernel command line")
        let engine = try XCTUnwrap(
            HVFMachineCapabilities.Engine(
                version: Data(
                    #"{"ApiVersion":"1.47","MinAPIVersion":"1.44","Version":"micropod","Os":"linux","Arch":"arm64"}"#
                        .utf8)))
        XCTAssertEqual(engine.minAPIVersion, "1.44")
        XCTAssertEqual(engine.apiVersion, "1.47")
        XCTAssertEqual(engine.version, "micropod")
        XCTAssertNil(HVFMachineCapabilities.Engine(version: Data("{}".utf8)), "no ApiVersion, no range")
        let none = HVFMachineCapabilities(layout: layout, config: HVFMachineConfig(), engine: nil)
        XCTAssertFalse(none.buildkit)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any]
        XCTAssertEqual(encoded?["buildkit"] as? Bool, false)
        XCTAssertTrue(encoded?["engine"] is NSNull, "a stopped machine reports no engine range: \(encoded ?? [:])")
    }

    // MARK: Config

    func testConfigDefaultsPartialFilesAndValidation() throws {
        XCTAssertEqual(try HVFMachineConfig.load(from: layout.config), HVFMachineConfig(), "missing file → defaults")
        XCTAssertEqual(
            HVFMachineConfig().workspace, HVFMachineLayout.canonicalPath(NSHomeDirectory()),
            "bind mounts work under the home directory by default")
        XCTAssertEqual(HVFMachineConfig().shutdownTimeoutSeconds, 10)
        XCTAssertEqual(HVFMachineConfig(shutdownTimeoutSeconds: 30).stopGrace, .seconds(35), "SIGKILL waits it out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"cpus": 2}"#.utf8).write(to: layout.config)
        let partial = try HVFMachineConfig.load(from: layout.config)
        XCTAssertEqual(partial.cpus, 2)
        XCTAssertEqual(partial.memoryMiB, 4096)
        XCTAssertTrue(partial.publishedNet)
        XCTAssertEqual(partial.workspace, HVFMachineConfig.defaultWorkspace)

        try Data(#"{"schema": 9}"#.utf8).write(to: layout.config)
        XCTAssertThrowsError(try HVFMachineConfig.load(from: layout.config)) {
            XCTAssertEqual(ConnectCodeMapping.code(for: $0), "failed_precondition")
        }
        try Data("not json".utf8).write(to: layout.config)
        XCTAssertThrowsError(try HVFMachineConfig.load(from: layout.config))

        var config = HVFMachineConfig(cpus: 6, memoryMiB: 8192, workspace: "/Users/me/src")
        try config.save(to: layout.config)
        XCTAssertEqual(try HVFMachineConfig.load(from: layout.config), config)
        config.workspace = nil
        try config.save(to: layout.config)
        XCTAssertNil(try HVFMachineConfig.load(from: layout.config).workspace, "no workspace survives a reload")
        for bad in [
            HVFMachineConfig(cpus: 0), HVFMachineConfig(memoryMiB: 64), HVFMachineConfig(workspace: "relative"),
            HVFMachineConfig(workspace: "/a/../b"), HVFMachineConfig(workspace: "/a:b"),
            HVFMachineConfig(workspace: "/"),
            HVFMachineConfig(workspace: "/a//b"), HVFMachineConfig(workspace: "/a/"),
            HVFMachineConfig(shutdownTimeoutSeconds: 0), HVFMachineConfig(shutdownTimeoutSeconds: 601),
        ] {
            XCTAssertThrowsError(try bad.validate(), "\(bad)")
        }
        XCTAssertNoThrow(try config.validate())
        config.workspace = "/private/tmp/ws"
        XCTAssertNoThrow(try config.validate(), "a realpath under /private is canonical")
    }

    // MARK: VMM argv

    func testArgumentsWithoutAWorkspace() throws {
        let args = try HVFVMMCommand.arguments(
            layout: layout, config: HVFMachineConfig(workspace: nil), parentPID: 4242)
        XCTAssertEqual(
            args,
            [
                "--kernel", "\(root.path)/Image", "--initrd", "\(root.path)/mp-hvf-init.cpio",
                "--disk", "\(root.path)/disk.ext4", "--share", "oci-tools:\(root.path)/tools:ro",
                "--vsock-expose", "\(root.path)/run/docker.sock:2375",
                "--vsock-expose", "\(root.path)/run/buildkit.sock:2377", "--published-net",
                "--cpus", "4", "--memory-mib", "4096", "--shutdown-timeout", "10", "--json-summary",
                "--parent-pid", "4242",
            ])
        XCTAssertFalse(args.contains("--cmdline"), "the VMM's own kernel command line is never replaced")
        let defaults = try HVFVMMCommand.arguments(layout: layout, config: HVFMachineConfig(), parentPID: 1)
        XCTAssertEqual(
            defaults.firstIndex(of: "--workspace").map { defaults[$0 + 1] }, HVFMachineConfig.defaultWorkspace)
    }

    func testWorkspaceKernelArgumentsAndExtras() throws {
        let config = HVFMachineConfig(
            cpus: 2, memoryMiB: 2048, workspace: "/Users/me/My Projects", publishedNet: false, console: false,
            shutdownTimeoutSeconds: 30, kernelArguments: ["mp.mtu=1500", "loglevel=4"], extraArguments: ["--trace"])
        let args = try HVFVMMCommand.arguments(layout: layout, config: config, parentPID: 7)
        let joined = args.joined(separator: "|")
        XCTAssertTrue(joined.contains("--workspace|/Users/me/My Projects|"), "the VMM shares and encodes it")
        XCTAssertFalse(joined.contains("workspace:"), "no hand-built workspace share")
        XCTAssertTrue(joined.contains("--cmdline-append|mp.mtu=1500|--cmdline-append|loglevel=4"))
        XCTAssertTrue(joined.contains("--shutdown-timeout|30|"))
        XCTAssertFalse(args.contains("--published-net"))
        XCTAssertTrue(args.contains("--quiet"))
        XCTAssertEqual(args.last, "--trace")
        XCTAssertEqual(Array(args.suffix(4).prefix(3)), ["--json-summary", "--parent-pid", "7"])
    }

    // MARK: State and policy

    func testStateRoundTripsAndMissingIsNil() throws {
        XCTAssertNil(try HVFMachineState.load(from: layout.state))
        let state = HVFMachineState(
            phase: .running, supervisorPID: 10, supervisorStartSeconds: 100, vmmPID: 11, vmmStartSeconds: 101,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), restartCount: 2, lastExitReason: "crash",
            lastExitCode: 3, lastExitMeaning: "the guest crashed or reset",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001))
        try state.save(to: layout.state)
        XCTAssertEqual(try HVFMachineState.load(from: layout.state), state)
        try Data("{".utf8).write(to: layout.state)
        XCTAssertThrowsError(try HVFMachineState.load(from: layout.state))
    }

    func testBackoffDoublesAndCaps() {
        let policy = HVFSupervisorPolicy(backoffBase: .seconds(1), backoffMax: .seconds(5))
        XCTAssertEqual((1...5).map { policy.backoff(afterFailures: $0) }, [1, 2, 4, 5, 5].map { .seconds($0) })
        XCTAssertEqual(policy.backoff(afterFailures: 0), .seconds(1))
    }

    func testExitDescriptionsNameTheVMMExitCodeAndGuestReport() {
        XCTAssertEqual(
            HVFVMMExit(code: 4, summary: "poweroff", guestStatus: "engine containerd exited").description,
            "exited with status 4: guest init or the container engine failed (exit_reason=poweroff); "
                + "guest reported: engine containerd exited")
        XCTAssertEqual(HVFVMMExit(signal: SIGKILL).description, "was killed by signal 9 (SIGKILL)")
        XCTAssertEqual(HVFVMMExit(code: 42).description, "exited with status 42")
        XCTAssertEqual(
            HVFDarwinVMMProcess.guestStatus(in: Data("[ 1.2] MICROPOD_VMM_GUEST_STATUS engine-failed boom\r".utf8)),
            "engine-failed boom")
        XCTAssertNil(HVFDarwinVMMProcess.guestStatus(in: Data("MICROPOD_VMM_INIT_READY".utf8)))
    }

    // MARK: Real processes and logs

    func testDarwinLauncherCapturesOutputSummaryAndExit() async throws {
        let launcher = HVFDarwinLauncher(
            consoleLog: layout.consoleLog, maxBytes: 1 << 20, environment: ["PATH": "/usr/bin:/bin"], report: { _ in })
        let script =
            #"echo booting; echo 'MICROPOD_VMM_GUEST_STATUS engine-failed boom' >&2; "#
            + #"echo '{"exit_reason":"poweroff","num_vcpus":1}'; exit 4"#
        let process = try launcher.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        let exit = await process.waitForExit()
        XCTAssertEqual(exit.code, 4)
        XCTAssertEqual(exit.summary, "poweroff")
        XCTAssertEqual(exit.guestStatus, "engine-failed boom")
        let console = try String(contentsOf: layout.consoleLog, encoding: .utf8)
        XCTAssertTrue(console.contains("launching /bin/sh"), console)
        XCTAssertTrue(console.contains("booting\n"), "stdout and stderr both land in the console log")
        XCTAssertTrue(console.contains("MICROPOD_VMM_GUEST_STATUS"))
    }

    func testDarwinProcessSignalsOnlyWhileAlive() async throws {
        let launcher = HVFDarwinLauncher(
            consoleLog: layout.consoleLog, maxBytes: 1 << 20, environment: [:], report: { _ in })
        let process = try launcher.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        XCTAssertEqual(getpgid(process.pid), process.pid, "the VMM gets a process group of its own")
        process.signal(SIGTERM)
        let exit = await process.waitForExit()
        XCTAssertEqual(exit.signal, SIGTERM)
        XCTAssertNil(exit.code)
        process.signal(SIGKILL)  // reaped: must be a no-op, never a recycled pid
        let again = await process.waitForExit()
        XCTAssertEqual(again, exit)
    }

    func testRotatingLogKeepsAtMostTwoCaps() throws {
        let url = root.appendingPathComponent("logs/x.log")
        let log = try HVFRotatingLog(url: url, maxBytes: 12)
        try log.append(Data("first-line\n".utf8))
        try log.append(Data("second-line\n".utf8))
        try log.append(Data("third-line\n".utf8))
        log.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "third-line\n")
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: url.path + ".1"), encoding: .utf8), "second-line\n")
        try HVFRotatingLog.rotateIfLarger(url, than: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Supervisor state machine

    private func supervisor(
        _ launcher: FakeLauncher, policy: HVFSupervisorPolicy = .fast,
        inspector: any HVFProcessInspecting = FakeInspector(),
        log: LogRecorder = LogRecorder()
    ) -> HVFMachineSupervisor {
        HVFMachineSupervisor(
            layout: layout, config: HVFMachineConfig(), policy: policy, launcher: launcher, inspector: inspector,
            readiness: { _ in launcher.currentIsReady }, log: { log.append($0) }, pid: 4242)
    }

    private func state() throws -> HVFMachineState { try XCTUnwrap(try HVFMachineState.load(from: layout.state)) }

    private func waitFor(_ what: String, timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(try condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testStartsBecomesReadyAndStopsGracefully() async throws {
        let launcher = FakeLauncher([.healthy])
        let supervisor = supervisor(launcher)
        let run = Task { try await supervisor.run() }
        try await waitFor("running") { (try? HVFMachineState.load(from: layout.state))?.phase == .running }
        let running = try state()
        XCTAssertEqual(running.vmmPID, launcher.processes.first?.pid)
        XCTAssertEqual(running.supervisorPID, 4242)
        XCTAssertNotNil(running.readyAt)
        XCTAssertTrue(HVFFileLock.isHeld(layout.supervisorLock), "the supervisor holds its lock while it runs")
        XCTAssertEqual(HVFFileLock.recordedPID(layout.supervisorLock), 4242)
        XCTAssertEqual(launcher.arguments.first?.suffix(2), ["--parent-pid", "4242"])

        supervisor.requestStop()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(launcher.processes.first?.signals, [SIGTERM], "one graceful signal, no SIGKILL")
        let stopped = try state()
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertNil(stopped.vmmPID)
        XCTAssertEqual(stopped.restartCount, 0)
        XCTAssertTrue(stopped.lastExitReason?.contains("stopped on request") ?? false)
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock), "released on exit")
    }

    func testUnexpectedExitIsRestartedWithBackoff() async throws {
        let launcher = FakeLauncher([.crashAfterReady(signal: SIGKILL), .healthy])
        let log = LogRecorder()
        let supervisor = supervisor(launcher, log: log)
        let run = Task { try await supervisor.run() }
        try await waitFor("the relaunch to become ready") {
            launcher.launchCount == 2 && (try? HVFMachineState.load(from: layout.state))?.phase == .running
        }
        let restarted = try state()
        XCTAssertEqual(restarted.restartCount, 1)
        XCTAssertEqual(restarted.vmmPID, launcher.processes.last?.pid)
        XCTAssertTrue(restarted.lastExitReason?.contains("killed by signal 9") ?? false, "\(restarted)")
        XCTAssertTrue(log.lines.contains { $0.contains("unexpected exit") && $0.contains("relaunching") })

        supervisor.requestStop()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(try state().restartCount, 1)
    }

    func testRepeatedRapidFailuresGiveUpIntoFailed() async throws {
        let launcher = FakeLauncher(Array(repeating: .crashImmediately(code: 3), count: 5))
        let outcome = try await supervisor(launcher).run()
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("exited with status 3: the guest crashed or reset"), reason)
        XCTAssertEqual(launcher.launchCount, HVFSupervisorPolicy.fast.maxRapidFailures)
        let failed = try state()
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.restartCount, HVFSupervisorPolicy.fast.maxRapidFailures - 1)
        XCTAssertEqual(failed.lastExitReason, reason)
        XCTAssertEqual(failed.lastExitCode, 3)
        XCTAssertEqual(failed.lastExitMeaning, "the guest crashed or reset")
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock))
    }

    func testConfigurationFailuresBeforeReadinessAreNotRetried() async throws {
        for code: Int32 in [1, 2] {
            try? FileManager.default.removeItem(at: layout.state)
            let launcher = FakeLauncher(Array(repeating: .crashImmediately(code: code), count: 5))
            let outcome = try await supervisor(launcher).run()
            guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(launcher.launchCount, 1, "status \(code) fails the same way every time")
            XCTAssertTrue(reason.contains("exited with status \(code)"), reason)
            XCTAssertEqual(try state().phase, .failed)
            XCTAssertEqual(try state().lastExitCode, code)
            XCTAssertEqual(try state().restartCount, 0)
        }
    }

    func testGuestFailuresAndForcedStopsAreRelaunched() async throws {
        let launcher = FakeLauncher([.crashImmediately(code: 4), .crashImmediately(code: 6), .healthy])
        let supervisor = supervisor(launcher)
        let run = Task { try await supervisor.run() }
        try await waitFor("the third launch to become ready") {
            launcher.launchCount == 3 && (try? HVFMachineState.load(from: layout.state))?.phase == .running
        }
        let recovered = try state()
        XCTAssertEqual(recovered.restartCount, 2)
        XCTAssertEqual(recovered.lastExitCode, 6)
        XCTAssertEqual(recovered.lastExitMeaning, "stopped without an orderly guest poweroff")
        supervisor.requestStop()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(try state().lastExitCode, 0, "the requested stop's orderly poweroff is recorded")
    }

    func testALaunchFailureIsAConfigurationFailure() async throws {
        let launcher = FakeLauncher(Array(repeating: .unlaunchable, count: 5))
        let outcome = try await supervisor(launcher).run()
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("could not be launched"), reason)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testStopEscalatesToSIGKILLWhenThePoweroffHangs() async throws {
        let launcher = FakeLauncher([.ignoresSIGTERM])
        let supervisor = supervisor(launcher)
        let run = Task { try await supervisor.run() }
        try await waitFor("running") { (try? HVFMachineState.load(from: layout.state))?.phase == .running }
        supervisor.requestStop()
        supervisor.requestStop()  // a repeated request is not a second signal
        let outcome = try await run.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(launcher.processes.first?.signals, [SIGTERM, SIGKILL])
    }

    func testBootThatNeverAnswersIsKilledAndCountedAsAFailure() async throws {
        let launcher = FakeLauncher(Array(repeating: .neverReady, count: 5))
        var policy = HVFSupervisorPolicy.fast
        policy.readinessTimeout = .milliseconds(50)
        policy.maxRapidFailures = 2
        let outcome = try await supervisor(launcher, policy: policy).run()
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("did not answer"), reason)
        XCTAssertEqual(launcher.launchCount, 2)
        XCTAssertEqual(launcher.processes.first?.signals, [SIGTERM])
    }

    func testStopDuringBackoffFinishesWithoutRelaunching() async throws {
        let launcher = FakeLauncher([.crashImmediately(code: 3), .healthy])
        var policy = HVFSupervisorPolicy.fast
        policy.backoffBase = .seconds(30)
        policy.backoffMax = .seconds(30)
        let supervisor = supervisor(launcher, policy: policy)
        let run = Task { try await supervisor.run() }
        try await waitFor("the backoff") { (try? HVFMachineState.load(from: layout.state))?.restartCount == 1 }
        supervisor.requestStop()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(try state().phase, .stopped)
    }

    func testSecondSupervisorForTheSameRootDefers() async throws {
        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        let launcher = FakeLauncher([.healthy])
        let outcome = try await supervisor(launcher).run()
        XCTAssertEqual(outcome, .alreadyRunning(nil))
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testStaleSocketIsRemovedBeforeLaunch() async throws {
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.dockerSocket.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.buildkitSocket.path, contents: nil))
        let launcher = FakeLauncher([.healthy])
        launcher.onLaunch = { [sockets = [layout.dockerSocket, layout.buildkitSocket]] in
            for socket in sockets {
                XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path), "stale \(socket.path) removed")
            }
        }
        let supervisor = supervisor(launcher)
        let run = Task { try await supervisor.run() }
        try await waitFor("running") { (try? HVFMachineState.load(from: layout.state))?.phase == .running }
        supervisor.requestStop()
        _ = try await run.value
    }

    func testAStopRequestedBeforeRunNeverLaunches() async throws {
        let launcher = FakeLauncher([.healthy])
        let supervisor = supervisor(launcher)
        supervisor.requestStop()  // e.g. SIGTERM while orphans were being reaped
        let outcome = try await supervisor.run()
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(launcher.launchCount, 0, "no VMM is booted only to be stopped")
        let stopped = try state()
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(stopped.supervisorPID, 4242)
        XCTAssertEqual(stopped.lastExitReason, "stopped before launch")
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock))
    }

    func testAStopDuringAReadinessTimeoutPoweroffSendsNoSecondSIGTERM() async throws {
        let launcher = FakeLauncher([.neverReadyIgnoresSIGTERM])
        var policy = HVFSupervisorPolicy.fast
        policy.readinessTimeout = .milliseconds(30)
        policy.stopTimeout = .milliseconds(400)
        let supervisor = supervisor(launcher, policy: policy)
        let run = Task { try await supervisor.run() }
        try await waitFor("the readiness timeout's SIGTERM") { launcher.processes.first?.signals == [SIGTERM] }
        supervisor.requestStop()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(
            launcher.processes.first?.signals, [SIGTERM, SIGKILL],
            "micropod-vmm forces a stop on a second SIGTERM; only the scheduled SIGKILL follows")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testALaunchFailureOnARelaunchBacksOffInsteadOfFailing() async throws {
        let launcher = FakeLauncher([.crashAfterReady(signal: SIGKILL), .unlaunchable, .healthy])
        let supervisor = supervisor(launcher)
        let run = Task { try await supervisor.run() }
        try await waitFor("the third launch to become ready") {
            launcher.launchCount == 3 && (try? HVFMachineState.load(from: layout.state))?.phase == .running
        }
        let recovered = try state()
        XCTAssertEqual(recovered.restartCount, 2)
        supervisor.requestStop()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .stopped)
    }

    func testASupervisorRefusesToStartWhileAnInstallRuns() async throws {
        let installing = try XCTUnwrap(try HVFFileLock.acquire(layout.installLock, wait: .zero))
        defer { installing.release() }
        let launcher = FakeLauncher([.healthy])
        do {
            _ = try await supervisor(launcher).run()
            XCTFail("an install owns the root")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable")
            XCTAssertTrue(error.localizedDescription.contains("being installed"), error.localizedDescription)
        }
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock), "released on refusal")
    }

    func testTheLogSinkNeverRaisesOnABrokenDestination() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        HVFMachineSupervisor.stderrLog("hello", to: fds[1])
        close(fds[1])
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fds[0], &buffer, buffer.count)
        close(fds[0])
        XCTAssertTrue(String(decoding: buffer[0..<max(n, 0)], as: UTF8.self).hasSuffix(" hvf-supervisor: hello\n"))

        // EBADF, and EPIPE with SIGPIPE ignored as `machine serve` runs:
        // the line is lost, the process carries on (FileHandle.write raises).
        XCTAssertFalse(HVFFiles.writeBestEffort(Data("x".utf8), to: -1))
        HVFMachineSupervisor.stderrLog("lost", to: -1)
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        XCTAssertFalse(HVFFiles.writeBestEffort(Data("x".utf8), to: fds[1]))
        HVFMachineSupervisor.stderrLog("lost", to: fds[1])
        close(fds[1])
    }

    func testADetachedSpawnDoesNotPinTheCallersDirectory() throws {
        func pwd(newSession: Bool) throws -> String {
            var fds: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&fds), 0)
            let pid = try HVFSpawn.spawn(
                executable: "/bin/pwd", arguments: ["-P"], environment: [:], output: fds[1], newSession: newSession)
            close(fds[1])
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fds[0], &buffer, buffer.count)
                guard n > 0 else { break }
                output.append(contentsOf: buffer[0..<n])
            }
            close(fds[0])
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try pwd(newSession: true), "/", "the detached supervisor (and so its VMM) runs in /")
        XCTAssertEqual(
            try pwd(newSession: false), HVFMachineLayout.canonicalPath(FileManager.default.currentDirectoryPath))
    }

    // MARK: Orphans

    func testOrphanDecisionRequiresThisRootsBinaryAndDisk() {
        let vmm = layout.vmm.path
        let disk = layout.disk.path
        func facts(_ pid: Int32, _ exe: String?, _ args: [String]) -> HVFProcessFacts {
            HVFProcessFacts(pid: pid, executablePath: exe, arguments: args, startSeconds: 1)
        }
        let candidates = [
            facts(100, vmm, [vmm, "--kernel", "k", "--disk", disk]),  // ours
            facts(101, vmm, [vmm, "--disk", "/elsewhere/disk.ext4"]),  // same binary, other disk
            facts(102, "/usr/local/bin/micropod-vmm", ["micropod-vmm", "--disk", disk]),  // name match only
            facts(103, nil, ["--disk", disk]),  // unknown executable
            facts(4242, vmm, [vmm, "--disk", disk]),  // the supervisor itself
            facts(1, vmm, [vmm, "--disk", disk]),
            facts(104, vmm, [vmm, "--disk"]),  // truncated argv
        ]
        XCTAssertEqual(HVFMachineSupervisor.orphans(among: candidates, layout: layout, supervisorPID: 4242), [100])
    }

    func testOrphanDecisionComparesCanonicalPaths() throws {
        try installPlaceholders()
        // /tmp is a symlink to /private/tmp: the kernel reports the latter.
        let reported = HVFMachineLayout.canonicalPath(layout.vmm.path)
        XCTAssertTrue(reported.hasPrefix("/private/tmp/"), reported)
        let orphan = HVFProcessFacts(
            pid: 100, executablePath: reported, arguments: [reported, "--disk", layout.disk.path], startSeconds: 1)
        XCTAssertEqual(HVFMachineSupervisor.orphans(among: [orphan], layout: layout, supervisorPID: 1), [100])
    }

    func testRecordedOrphanIsReapedBeforeLaunch() async throws {
        try HVFMachineState(phase: .running, supervisorPID: 999, vmmPID: 555).save(to: layout.state)
        let inspector = FakeInspector()
        inspector.add(
            HVFProcessFacts(
                pid: 555, executablePath: layout.vmm.path, arguments: [layout.vmm.path, "--disk", layout.disk.path],
                startSeconds: 5))
        inspector.add(
            HVFProcessFacts(
                pid: 556, executablePath: "/bin/sleep", arguments: ["sleep", "--disk", layout.disk.path],
                startSeconds: 5)
        )
        let launcher = FakeLauncher([.healthy])
        launcher.onLaunch = { XCTAssertFalse(inspector.isAlive(555), "reaped before the new VMM starts") }
        let supervisor = supervisor(launcher, inspector: inspector)
        let run = Task { try await supervisor.run() }
        try await waitFor("the new supervisor running") {
            let state = try? HVFMachineState.load(from: layout.state)
            return state?.supervisorPID == 4242 && state?.phase == .running
        }
        XCTAssertEqual(inspector.signalled, [555: [SIGTERM]])
        XCTAssertTrue(inspector.isAlive(556), "an unrelated process is never signalled")
        supervisor.requestStop()
        _ = try await run.value
    }

    /// Real processes and the real inspector: a stand-in "VMM" (a copy of
    /// /bin/cat at the root's micropod-vmm path, blocked on an open pipe)
    /// on the root's disk is reaped; the same binary on another disk is not.
    func testRealOrphanOnThisDiskIsReapedAndADecoyIsNot() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: layout.vmm)
        var stdins: [Pipe] = []
        func spawn(disk: String) throws -> Process {
            let process = Process()
            process.executableURL = layout.vmm
            // cat reads stdin ("-") until EOF before it looks at "--disk".
            process.arguments = ["-", "--disk", disk]
            let input = Pipe()
            stdins.append(input)
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        let orphan = try spawn(disk: layout.disk.path)
        let decoy = try spawn(disk: "/tmp/elsewhere/disk.ext4")
        defer {
            for process in [orphan, decoy] where process.isRunning { process.terminate() }
        }
        let inspector = HVFDarwinProcessInspector()
        try await waitFor("argv to be readable") {
            inspector.facts(orphan.processIdentifier)?.arguments.contains("--disk") ?? false
        }
        let facts = try XCTUnwrap(inspector.facts(orphan.processIdentifier))
        XCTAssertEqual(
            facts.executablePath.map(HVFMachineLayout.canonicalPath), HVFMachineLayout.canonicalPath(layout.vmm.path))
        XCTAssertEqual(Array(facts.arguments.suffix(2)), ["--disk", layout.disk.path])
        XCTAssertNotNil(facts.startSeconds)
        let found = inspector.processes(executable: HVFMachineLayout.canonicalPath(layout.vmm.path))
        XCTAssertEqual(Set(found), [orphan.processIdentifier, decoy.processIdentifier])
        let decoyFacts = try XCTUnwrap(inspector.facts(decoy.processIdentifier))
        XCTAssertEqual(
            HVFMachineSupervisor.orphans(among: [facts, decoyFacts], layout: layout, supervisorPID: 4242),
            [orphan.processIdentifier])

        let launcher = FakeLauncher([.healthy])
        let supervisor = supervisor(launcher, inspector: inspector)
        let run = Task { try await supervisor.run() }
        try await waitFor("the orphan to be reaped") { !orphan.isRunning }
        try await waitFor("running") { (try? HVFMachineState.load(from: layout.state))?.phase == .running }
        XCTAssertEqual(orphan.terminationReason, .uncaughtSignal)
        XCTAssertEqual(orphan.terminationStatus, SIGTERM)
        XCTAssertTrue(decoy.isRunning, "another disk's VMM is not ours to stop")
        supervisor.requestStop()
        _ = try await run.value
    }

    // MARK: Client status

    func testStatusTreatsAStateWithoutALiveSupervisorAsStopped() throws {
        try installPlaceholders()
        let client = HVFMachineClient(layout: layout, environment: [:])
        XCTAssertEqual(client.status().phase, .stopped)
        XCTAssertNil(client.status().state)

        try HVFMachineState(phase: .running, supervisorPID: 999_999, vmmPID: 1234).save(to: layout.state)
        let stale = client.status()
        XCTAssertEqual(stale.phase, .stopped)
        XCTAssertFalse(stale.supervisorAlive)
        XCTAssertTrue(stale.summary.contains("exited without stopping"), stale.summary)
        XCTAssertFalse(client.isServing)

        try HVFMachineState(phase: .failed, supervisorPID: 999_999, lastExitReason: "boom").save(to: layout.state)
        XCTAssertEqual(client.status().phase, .failed)
        XCTAssertEqual(client.status().summary, "failed: boom")

        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid()).save(to: layout.state)
        XCTAssertEqual(client.status().phase, .running)
        XCTAssertFalse(client.isServing, "no socket yet")
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.dockerSocket.path, contents: nil))
        XCTAssertTrue(client.isServing)
    }

    func testEnsureRunningRefusesAnUninstalledMachine() async {
        do {
            try await HVFMachineClient(layout: layout, environment: [:]).ensureRunning(timeout: .seconds(1))
            XCTFail("nothing is installed")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
            XCTAssertTrue(error.localizedDescription.contains("micropod machine install"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runDirectory.path), "nothing was launched")
    }

    func testSupervisorExecutablePrefersMICROPOD_CLI() throws {
        try installPlaceholders()
        XCTAssertEqual(
            HVFMachineClient.supervisorExecutable(environment: ["MICROPOD_CLI": layout.vmm.path])?.path, layout.vmm.path
        )
    }

    func testEnsureRunningTreatsAStopOfItsOwnSupervisorAsFinal() {
        func state(_ phase: HVFMachinePhase, pid: Int32 = 100) -> HVFMachineState {
            HVFMachineState(phase: phase, supervisorPID: pid, lastExitReason: "why")
        }
        let mine: Set<Int32> = [100]
        func step(_ state: HVFMachineState?, _ launched: Set<Int32>, _ launches: Int)
            -> HVFMachineClient
            .StepWithoutSupervisor
        {
            HVFMachineClient.stepWithoutSupervisor(state: state, launched: launched, launches: launches)
        }
        XCTAssertEqual(step(nil, [], 0), .launch)
        XCTAssertEqual(step(state(.stopped), mine, 1), .stoppedWhileStarting, "an explicit stop is not undone")
        XCTAssertEqual(step(state(.failed), mine, 1), .failedToStart("why"))
        XCTAssertEqual(step(state(.stopped, pid: 7), mine, 1), .launch, "another supervisor's stop is history")
        XCTAssertEqual(step(state(.running), mine, 1), .launch, "one that died without publishing gets a retry")
        XCTAssertEqual(step(nil, mine, 2), .gaveUp)
    }

    func testEnsureRunningRefusesWhileAnInstallRuns() async throws {
        try installPlaceholders()
        let installing = try XCTUnwrap(try HVFFileLock.acquire(layout.installLock, wait: .zero))
        defer { installing.release() }
        do {
            try await HVFMachineClient(layout: layout, environment: [:]).ensureRunning(timeout: .seconds(5))
            XCTFail("an install owns the root")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable")
            XCTAssertTrue(error.localizedDescription.contains("being installed"), error.localizedDescription)
        }
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock), "nothing was launched")
    }

    func testStopWaitsForAStartInFlightAndIgnoresABrokenConfig() async throws {
        try installPlaceholders()
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        try Data(#"{"schema": 2}"#.utf8).write(to: layout.config)
        let starting = try XCTUnwrap(try HVFFileLock.acquire(layout.startLock, wait: .zero))
        let inspector = FakeInspector()
        inspector.add(HVFProcessFacts(pid: 4343, executablePath: "/x", arguments: [], startSeconds: 1))
        let client = HVFMachineClient(layout: layout, environment: [:], inspector: inspector)
        let stop = Task { try await client.stop() }
        try await Task.sleep(for: .milliseconds(150))
        // The starter's supervisor takes its lock; then the starter lets go.
        let supervisor = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        try supervisor.record(pid: 4343)
        starting.release()
        try await waitFor("the SIGTERM") { inspector.signalled[4343] == [SIGTERM] }
        supervisor.release()
        let stopped = try await stop.value
        XCTAssertTrue(stopped, "a machine being started is stopped, not reported as not running")
    }

    func testStopOnARootThatNeverRanCreatesNothing() async throws {
        let stopped = try await HVFMachineClient(layout: layout, environment: [:]).stop()
        XCTAssertFalse(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: Engine

    func testProbeReportsWhatIsMissingWithoutBooting() async throws {
        let engine = HVFEngine(root: root)
        let probe = await engine.probe()
        XCTAssertFalse(probe.available)
        XCTAssertTrue(
            probe.reason.contains("missing micropod-vmm, Image, mp-hvf-init.cpio, disk.ext4, tools/"), probe.reason)
        XCTAssertTrue(probe.reason.contains("micropod machine install"))
        XCTAssertEqual(probe.endpoint, layout.dockerEndpoint)
        XCTAssertEqual(engine.capabilities, HVFEngine.supportedCapabilities)
    }

    func testInstalledStoppedMachineIsAvailableAndReadsStayCold() async throws {
        try installPlaceholders()
        let engine = HVFEngine(root: root)
        let probe = await engine.probe()
        XCTAssertTrue(probe.available, probe.reason)
        XCTAssertTrue(probe.reason.contains("stopped") && probe.reason.contains("starts on first run"), probe.reason)
        XCTAssertEqual(probe.version, "")

        let listed = try await engine.list()
        XCTAssertEqual(listed, [])
        let owned = await engine.owns("anything")
        XCTAssertFalse(owned)
        let stats = try await engine.snapshot(ids: [])
        XCTAssertEqual(stats.containers, [])
        do {
            _ = try await engine.inspect("anything")
            XCTFail("a stopped machine has nothing to inspect")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
        }
        try await engine.stopAll()
        let pruned = try await engine.prune()
        XCTAssertEqual(pruned, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state.path), "no read booted the machine")
        XCTAssertFalse(HVFFileLock.isHeld(layout.supervisorLock))
    }

    func testFailedMachineStaysAvailableForARetry() async throws {
        try installPlaceholders()
        try HVFMachineState(phase: .failed, supervisorPID: 999_999, lastExitReason: "boom").save(to: layout.state)
        let probe = await HVFEngine(root: root).probe()
        XCTAssertTrue(probe.available)
        XCTAssertTrue(probe.reason.contains("failed: boom") && probe.reason.contains("next run retries"), probe.reason)
    }

    func testProbeRejectsUnusableInstallations() async throws {
        try installPlaceholders()
        XCTAssertEqual(chmod(layout.vmm.path, 0o644), 0)
        let probe = await HVFEngine(root: root).probe()
        XCTAssertFalse(probe.available)
        XCTAssertTrue(probe.reason.contains("not executable"), probe.reason)
    }

    func testUnsupportedRequestsAreRefusedExplicitly() async throws {
        let engine = HVFEngine(root: root)
        for request in [
            ContainerRunRequest(image: "alpine", interactive: true), ContainerRunRequest(image: "alpine", tty: true),
        ] {
            do {
                _ = try await engine.run(request)
                XCTFail("refused before the machine is touched")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "unimplemented")
            }
        }
        do {
            try await engine.copy(from: "c:/etc", to: "/tmp/x")
            XCTFail("no archive API")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unimplemented")
        }
        do {
            try await engine.kill("c", signal: "TERM")
            XCTFail("SIGKILL only")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SIGKILL only"))
        }
        do {
            _ = try await engine.exec(ContainerExecRequest(containerID: "c", arguments: ["sh"], tty: true))
            XCTFail("no interactive exec")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unimplemented")
        }
    }

    func testBindSourcesResolveToTheWorkspaceSharePath() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let admitted = try HVFEngine.admit(
            ContainerRunRequest(image: "alpine", volumes: ["\(root.path):/w:ro", "named:/data", "/nonexistent/x:/x"]))
        XCTAssertEqual(
            admitted.volumes,
            ["/private\(root.path):/w:ro", "named:/data", "/nonexistent/x:/x"],
            "host paths are canonical, named volumes untouched")
    }

    func testPublishedPortsComeFromInspect() throws {
        let inspect =
            Data(
                #"{"NetworkSettings":{"Ports":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"18110"}],"#.utf8)
            + Data(#""53/udp":[{"HostIp":"","HostPort":"5353"}],"9000/tcp":null}}}"#.utf8)
        let ports = HVFEngine.publishedPorts(inspect: inspect)
        XCTAssertEqual(ports.map(\.containerPort), [53, 8080], "unbound ports are skipped")
        XCTAssertEqual(ports.map(\.hostPort), [5353, 18110])
        XCTAssertEqual(ports.map(\.protocol), ["udp", "tcp"])
        XCTAssertEqual(ports.last?.hostIp, "127.0.0.1")
        XCTAssertEqual(HVFEngine.publishedPorts(inspect: Data("{}".utf8)), [])
    }

    func testDockerClientNamesItsAPIVersion() {
        XCTAssertTrue(
            DockerClient.head("GET", "/_ping", query: [:], bodyLength: nil, apiVersion: HVFMachineClient.apiVersion)
                .hasPrefix("GET /v1.44/_ping HTTP/1.1\r\n"))
        XCTAssertEqual(HVFMachineClient(layout: layout).docker.apiVersion, "v1.44")
        XCTAssertEqual(DockerClient(endpoint: .unix("/x")).apiVersion, "v1.43", "stock Docker keeps its version")
    }

    // MARK: Installer

    /// A real ad-hoc signature with the hypervisor entitlement, on a copy of
    /// a system binary (never executed).
    private func signedBinary(entitled: Bool) throws -> URL {
        let fm = FileManager.default
        let staging = root.appendingPathComponent("src")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let binary = staging.appendingPathComponent(entitled ? "vmm-entitled" : "vmm-plain")
        if fm.fileExists(atPath: binary.path) { return binary }
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        guard entitled else { return binary }
        let plist = staging.appendingPathComponent("ent.plist")
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

    private func sources() throws -> HVFInstallRequest {
        let fm = FileManager.default
        let staging = root.appendingPathComponent("src")
        try fm.createDirectory(at: staging.appendingPathComponent("tools/runner"), withIntermediateDirectories: true)
        for name in ["Image", "init.cpio", "tools/runner/start.sh"] {
            XCTAssertTrue(fm.createFile(atPath: staging.appendingPathComponent(name).path, contents: Data(name.utf8)))
        }
        var disk = Data(count: 4096)
        disk[1024 + 0x38] = 0x53
        disk[1024 + 0x39] = 0xEF
        try disk.write(to: staging.appendingPathComponent("disk.ext4"))
        return HVFInstallRequest(
            vmm: try signedBinary(entitled: true), kernel: staging.appendingPathComponent("Image"),
            initrd: staging.appendingPathComponent("init.cpio"), tools: staging.appendingPathComponent("tools"),
            diskFrom: staging.appendingPathComponent("disk.ext4"), cpus: 2, memoryMiB: 1024)
    }

    /// The installer's error for `request`, or nil when it succeeded.
    private func installError(_ request: HVFInstallRequest) async -> String? {
        do {
            try await HVFMachineInstaller.install(request, layout: layout) { _ in }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testInstallCopiesAssetsClonesTheDiskAndWritesConfig() async throws {
        let request = try sources()
        let lines = LogRecorder()
        try await HVFMachineInstaller.install(request, layout: layout) { lines.append($0) }
        XCTAssertEqual(layout.missingAssets(), [])
        XCTAssertNoThrow(
            try HVFMachineInstaller.verifyHypervisorEntitlement(layout.vmm), "the copy keeps its signature")
        XCTAssertEqual(try Data(contentsOf: layout.disk), try Data(contentsOf: try XCTUnwrap(request.diskFrom)))
        var info = stat()
        XCTAssertEqual(stat(layout.disk.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let config = try HVFMachineConfig.load(from: layout.config)
        XCTAssertEqual(config.cpus, 2)
        XCTAssertEqual(config.memoryMiB, 1024)
        XCTAssertTrue(lines.lines.contains { $0.contains("cloned disk.ext4") })
        XCTAssertEqual(
            lines.lines.last,
            "guest tools have no BuildKit (missing runner/bin/buildkitd, runner/buildkitd.toml): "
                + "this machine serves no buildx builder", "every install says what the bundle means for buildx")

        // The disk is the machine's data: replacing it is explicit.
        let refused = await installError(request)
        XCTAssertTrue(refused?.contains("--replace-disk") ?? false, refused ?? "installed")
        var fresh = request
        fresh.diskFrom = nil
        fresh.diskImage = "alpine:3.20"
        let refusedImage = await installError(fresh)
        XCTAssertTrue(refusedImage?.contains("--replace-disk") ?? false, "a new image disk is just as destructive")
        var replace = request
        replace.replaceDisk = true
        let replaced = await installError(replace)
        XCTAssertNil(replaced)
        // Asset-only reinstall keeps the disk.
        let reconfigured = await installError(HVFInstallRequest(memoryMiB: 2048))
        XCTAssertNil(reconfigured)
        XCTAssertEqual(try HVFMachineConfig.load(from: layout.config).memoryMiB, 2048)
    }

    func testInstallRefusesAnUnentitledVMMAndChangesNothing() async throws {
        var request = try sources()
        request.vmm = try signedBinary(entitled: false)
        let message = await installError(request)
        XCTAssertTrue(message?.contains("com.apple.security.hypervisor") ?? false, message ?? "installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.vmm.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.disk.path))
    }

    func testInstallNamesTheFlagsAnEmptyRootNeeds() async {
        let message = await installError(HVFInstallRequest()) ?? "installed"
        for flag in ["--vmm", "--kernel", "--initrd", "--tools", "--disk-from", "--disk-image"] {
            XCTAssertTrue(message.contains(flag), message)
        }
    }

    func testInstallRejectsBadDiskSourcesAndARunningMachine() async throws {
        var request = try sources()
        let bogus = root.appendingPathComponent("src/bogus.img")
        try Data(count: 4096).write(to: bogus)
        request.diskFrom = bogus
        let notExt4 = await installError(request)
        XCTAssertTrue(notExt4?.contains("not an ext4 image") ?? false, notExt4 ?? "installed")
        request.diskImage = "alpine:3.20"
        let both = await installError(request)
        XCTAssertTrue(both?.contains("not both") ?? false, both ?? "installed")
        request.diskFrom = nil
        request.diskBytes = 1 << 20
        let tiny = await installError(request)
        XCTAssertTrue(tiny?.contains("at least 1 GiB") ?? false, tiny ?? "installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.disk.path), "nothing was pulled or written")

        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        let running = await installError(try sources())
        XCTAssertTrue(running?.contains("is running") ?? false, running ?? "installed")
    }

    func testInstallCopiesThroughSymlinkedSources() async throws {
        var request = try sources()
        let fm = FileManager.default
        let links = root.appendingPathComponent("links")
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        // Relative links, as Homebrew installs binaries.
        for (name, target) in [
            ("vmm", "../src/vmm-entitled"), ("Image", "../src/Image"), ("init", "../src/init.cpio"),
            ("tools", "../src/tools"),
        ] {
            try fm.createSymbolicLink(atPath: links.appendingPathComponent(name).path, withDestinationPath: target)
        }
        request.vmm = links.appendingPathComponent("vmm")
        request.kernel = links.appendingPathComponent("Image")
        request.initrd = links.appendingPathComponent("init")
        request.tools = links.appendingPathComponent("tools")
        try await HVFMachineInstaller.install(request, layout: layout) { _ in }
        for url in [layout.vmm, layout.kernel, layout.initrd] {
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            XCTAssertEqual(type, .typeRegular, "\(url.lastPathComponent) is a copy, not a link")
        }
        XCTAssertEqual(try fm.attributesOfItem(atPath: layout.tools.path)[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertEqual(try String(contentsOf: layout.kernel, encoding: .utf8), "Image")
        XCTAssertNoThrow(try HVFMachineInstaller.verifyHypervisorEntitlement(layout.vmm))
        XCTAssertEqual(layout.missingAssets(), [])
    }

    func testAFailedDiskPullChangesNothingInstalled() async throws {
        let request = try sources()
        try await HVFMachineInstaller.install(request, layout: layout) { _ in }
        let before = try [layout.kernel, layout.config, layout.disk].map { try Data(contentsOf: $0) }
        let newKernel = root.appendingPathComponent("src/Image2")
        XCTAssertTrue(FileManager.default.createFile(atPath: newKernel.path, contents: Data("new kernel".utf8)))
        // A root that cannot take new entries fails the disk step locally (and
        // at once): the pull store for --disk-image, the clone for --disk-from.
        // run/ stays writable, so the locks are still taken.
        XCTAssertEqual(chmod(root.path, 0o555), 0)
        defer { chmod(root.path, 0o755) }
        let pull = await installError(
            HVFInstallRequest(kernel: newKernel, diskImage: "alpine:3.20", replaceDisk: true, cpus: 3))
        XCTAssertNotNil(pull, "the pull store cannot be created")
        var clone = try sources()
        clone.kernel = newKernel
        clone.replaceDisk = true
        let cloned = await installError(clone)
        XCTAssertTrue(cloned?.contains("cannot clone") ?? false, cloned ?? "installed")
        chmod(root.path, 0o755)
        XCTAssertEqual(
            try [layout.kernel, layout.config, layout.disk].map { try Data(contentsOf: $0) }, before,
            "the kernel and config are swapped only once the disk is ready")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".install-") || $0.hasPrefix(".retired-") || $0 == "images" }
        XCTAssertEqual(leftovers, [], "the staged disk and pull store are removed")
    }

    func testInstallIsExclusiveAndWaitsOutAStartInFlight() async throws {
        let request = try sources()
        let installing = try XCTUnwrap(try HVFFileLock.acquire(layout.installLock, wait: .zero))
        let concurrent = await installError(request)
        XCTAssertTrue(concurrent?.contains("another `micropod machine install`") ?? false, concurrent ?? "installed")
        installing.release()

        // A starter holds start.lock until its supervisor holds the
        // supervisor lock: the install waits for that, then refuses.
        let starting = try XCTUnwrap(try HVFFileLock.acquire(layout.startLock, wait: .zero))
        let install = Task { [layout] in
            do {
                try await HVFMachineInstaller.install(request, layout: layout) { _ in }
                return "installed"
            } catch {
                return error.localizedDescription
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        let supervisor = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { supervisor.release() }
        starting.release()
        let message = await install.value
        XCTAssertTrue(message.contains("is running"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.vmm.path), "nothing was installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.disk.path))
    }

    func testInstallClearsLeftoversAndANewDiskForgetsTheOldContainers() async throws {
        var request = try sources()
        try await HVFMachineInstaller.install(request, layout: layout) { _ in }
        let fm = FileManager.default
        let index = HVFContainerIndexStore(layout: layout)
        index.update { $0.record(id: "abcdef123456", name: "keep") }
        let leftovers = [".install-1-disk.ext4", ".retired-2-tools", "images"].map { root.appendingPathComponent($0) }
        XCTAssertTrue(fm.createFile(atPath: leftovers[0].path, contents: Data("partial".utf8)))
        try fm.createDirectory(at: leftovers[1].appendingPathComponent("runner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: leftovers[2].appendingPathComponent("blobs"), withIntermediateDirectories: true)

        let reconfigured = await installError(HVFInstallRequest(cpus: 3))
        XCTAssertNil(reconfigured)
        for leftover in leftovers {
            XCTAssertFalse(fm.fileExists(atPath: leftover.path), "\(leftover.lastPathComponent) removed")
        }
        XCTAssertNotNil(index.load().entry(for: "keep"), "the same disk keeps its containers")

        request.replaceDisk = true
        let replaced = await installError(request)
        XCTAssertNil(replaced)
        XCTAssertNil(index.load().entry(for: "keep"), "a new disk holds none of the old containers")
    }
}

// MARK: - Fakes

extension HVFSupervisorPolicy {
    static let fast = HVFSupervisorPolicy(
        readinessTimeout: .seconds(5), readinessInterval: .milliseconds(2), stopTimeout: .milliseconds(100),
        backoffBase: .milliseconds(5), backoffMax: .milliseconds(20), rapidFailureWindow: .seconds(30),
        maxRapidFailures: 3, lockWait: .milliseconds(20))
}

final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func append(_ line: String) { lock.withLock { recorded.append(line) } }
    var lines: [String] { lock.withLock { recorded } }
}

/// One scripted micropod-vmm.
final class FakeVMM: HVFVMMProcess, @unchecked Sendable {
    enum Script: Sendable {
        /// Ready at once; exits 0 on SIGTERM.
        case healthy
        /// Ready, then dies on `signal` shortly after.
        case crashAfterReady(signal: Int32)
        /// Exits with `code` immediately, never ready.
        case crashImmediately(code: Int32)
        /// Never ready; exits on SIGTERM.
        case neverReady
        /// Ready; only SIGKILL ends it.
        case ignoresSIGTERM
        /// Never ready, and only SIGKILL ends it (a slow poweroff).
        case neverReadyIgnoresSIGTERM
        /// The launcher throws.
        case unlaunchable
    }

    let pid: Int32
    let script: Script
    private let lock = NSLock()
    private var exit: HVFVMMExit?
    private var waiters: [CheckedContinuation<HVFVMMExit, Never>] = []
    private var received: [Int32] = []

    init(pid: Int32, script: Script) {
        self.pid = pid
        self.script = script
        switch script {
        case .crashImmediately(let code):
            finish(HVFVMMExit(code: code))
        case .crashAfterReady(let signal):
            Thread.detachNewThread { [self] in
                usleep(30_000)
                finish(HVFVMMExit(signal: signal))
            }
        default:
            break
        }
    }

    var ready: Bool {
        switch script {
        case .healthy, .crashAfterReady, .ignoresSIGTERM: return lock.withLock { exit == nil }
        default: return false
        }
    }

    var signals: [Int32] { lock.withLock { received } }

    func waitForExit() async -> HVFVMMExit {
        await withCheckedContinuation { continuation in
            let done: HVFVMMExit? = lock.withLock {
                if let exit { return exit }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    func signal(_ signal: Int32) {
        let alive = lock.withLock { () -> Bool in
            guard exit == nil else { return false }
            received.append(signal)
            return true
        }
        guard alive else { return }
        switch (script, signal) {
        case (.ignoresSIGTERM, SIGTERM), (.neverReadyIgnoresSIGTERM, SIGTERM): break
        case (_, SIGKILL): finish(HVFVMMExit(signal: SIGKILL))
        default: finish(HVFVMMExit(code: 0, summary: "poweroff"))
        }
    }

    func finish(_ result: HVFVMMExit) {
        let waiting = lock.withLock { () -> [CheckedContinuation<HVFVMMExit, Never>] in
            guard exit == nil else { return [] }
            exit = result
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in waiting { waiter.resume(returning: result) }
    }
}

final class FakeLauncher: HVFVMMLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let scripts: [FakeVMM.Script]
    private var launched: [FakeVMM] = []
    private var argv: [[String]] = []
    private var hook: (@Sendable () -> Void)?

    init(_ scripts: [FakeVMM.Script]) { self.scripts = scripts }

    var onLaunch: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func launch(executable: URL, arguments: [String]) throws -> any HVFVMMProcess {
        onLaunch?()
        let process = try lock.withLock { () throws -> FakeVMM in
            let index = argv.count
            argv.append(arguments)
            let script = index < scripts.count ? scripts[index] : .healthy
            if case .unlaunchable = script {
                launched.append(FakeVMM(pid: Int32(9000 + index), script: .crashImmediately(code: 127)))
                throw MicropodError.message("internal: no such file")
            }
            let process = FakeVMM(pid: Int32(9000 + index), script: script)
            launched.append(process)
            return process
        }
        return process
    }

    var launchCount: Int { lock.withLock { argv.count } }
    var arguments: [[String]] { lock.withLock { argv } }
    var processes: [FakeVMM] { lock.withLock { launched } }
    var currentIsReady: Bool { lock.withLock { launched.last }?.ready ?? false }
}

final class FakeInspector: HVFProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: HVFProcessFacts] = [:]
    private var sent: [Int32: [Int32]] = [:]

    func add(_ facts: HVFProcessFacts) { lock.withLock { table[facts.pid] = facts } }
    var signalled: [Int32: [Int32]] { lock.withLock { sent } }

    func facts(_ pid: Int32) -> HVFProcessFacts? { lock.withLock { table[pid] } }

    func processes(executable path: String) -> [Int32] {
        lock.withLock {
            table.values.filter { $0.executablePath.map(HVFMachineLayout.canonicalPath) == path }.map(\.pid)
        }
    }

    func isAlive(_ pid: Int32) -> Bool { lock.withLock { table[pid] != nil } }

    func signal(_ pid: Int32, _ signal: Int32) -> String? {
        lock.withLock {
            guard table[pid] != nil else { return "no such process" }
            sent[pid, default: []].append(signal)
            table[pid] = nil  // dies on the first signal
            return nil
        }
    }
}
