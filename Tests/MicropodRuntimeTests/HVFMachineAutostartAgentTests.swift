import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Records every launchd call; `kickstart` runs `onKickstart` (a test plays
/// launchd starting the supervisor there).
final class RecordingLaunchControl: RigLaunchControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var loadedLabels: Set<String>
    private var recorded: [String] = []
    var kickstartError: Error?
    var onKickstart: (@Sendable () -> Void)?

    init(loaded: Set<String> = []) { loadedLabels = loaded }

    var calls: [String] { lock.withLock { recorded } }
    private func note(_ call: String) { lock.withLock { recorded.append(call) } }

    func isLoaded(_ label: String) async -> Bool {
        note("print \(label)")
        return lock.withLock { loadedLabels.contains(label) }
    }

    func loadedProgram(_ label: String) async -> String? {
        note("print \(label)")
        return lock.withLock { loadedLabels.contains(label) } ? "/x" : nil
    }

    func bootout(_ label: String) async throws {
        note("bootout \(label)")
        _ = lock.withLock { loadedLabels.remove(label) }
    }

    func bootstrap(_ plist: URL, label: String) async throws {
        note("bootstrap \(plist.lastPathComponent)")
        _ = lock.withLock { loadedLabels.insert(label) }
    }

    func kickstart(_ label: String) async throws {
        note("kickstart \(label)")
        if let kickstartError { throw kickstartError }
        onKickstart?()
    }
}

final class FakeAutostartMachine: HVFAutostartMachine, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Bool
    private var recorded: [String] = []
    let busyReason: String?

    init(alive: Bool = false, busy: String? = nil) {
        self.alive = alive
        busyReason = busy
    }

    var calls: [String] { lock.withLock { recorded } }

    func supervisorAlive() -> Bool { lock.withLock { alive } }
    func busy() async -> String? {
        lock.withLock { recorded.append("busy?") }
        return busyReason
    }
    func stop() async throws {
        lock.withLock {
            recorded.append("stop")
            alive = false
        }
    }
    func start() async throws {
        lock.withLock {
            recorded.append("start")
            alive = true
        }
    }
}

/// `micropod machine autostart`: the LaunchAgent's definition (rendered to
/// a temp directory and checked with plutil), the order of launchd calls
/// against a recording stand-in, deferral while containers run, and the
/// start path that asks launchd to kickstart the job. Nothing here reaches
/// the real launchd or ~/Library/LaunchAgents.
final class HVFMachineAutostartAgentTests: XCTestCase {
    private var root: URL!
    private var agents: URL!

    override func setUp() {
        root = URL(fileURLWithPath: "/tmp/mpas-\(UUID().uuidString.prefix(8))")
        agents = root.appendingPathComponent("LaunchAgents")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }

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

    /// An executable that stands in for the micropod CLI.
    private func program(exiting status: Int32 = 0) throws -> URL {
        let url = root.appendingPathComponent("bin/micropod")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit \(status)\n".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o755), 0)
        return url
    }

    private func agent(
        _ launch: RecordingLaunchControl, machine: FakeAutostartMachine = FakeAutostartMachine(),
        environment: [String: String] = ["PATH": "/usr/bin:/bin"]
    ) -> HVFMachineAutostartAgent {
        HVFMachineAutostartAgent(
            layout: layout, environment: environment, launch: launch, launchAgentsDirectory: agents, machine: machine)
    }

    private func plutilLint(_ url: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-lint", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    // MARK: Definition

    func testRenderedPlistLintsAndHasTheJobKeys() throws {
        try installPlaceholders()
        try HVFMachineConfig(shutdownTimeoutSeconds: 40).save(to: layout.config)
        let cli = try program()
        let environment = [
            "PATH": "/opt/x/bin:/usr/bin", "MICROPOD_LINK_DOCKER_SOCK": "0", "SECRET_TOKEN": "nope",
            "MICROPOD_DOCKER_SOCK": "/tmp/elsewhere.sock",
        ]
        let agent = HVFMachineAutostartAgent(
            layout: layout, environment: environment, launch: RecordingLaunchControl(), launchAgentsDirectory: agents,
            machine: FakeAutostartMachine())
        let elsewhere = root.appendingPathComponent("render")
        let url = try agent.render(program: cli, to: elsewhere)
        XCTAssertEqual(url.deletingLastPathComponent().path, elsewhere.path)
        let lint = try plutilLint(url)
        XCTAssertEqual(lint.status, 0, lint.output)

        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, agent.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [cli.path, "machine", "serve", "--link-socket"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(
            plist["KeepAlive"] as? [String: Bool], ["Crashed": true],
            "relaunched only after a crash: a stop or a supervisor that gave up stays down")
        XCTAssertEqual(plist["ExitTimeOut"] as? Int, 40 + 5 + 10, "the supervisor's stop grace plus the margin")
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["Umask"] as? Int, 0o022)
        XCTAssertEqual(plist["StandardOutPath"] as? String, layout.supervisorLog.path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, layout.supervisorLog.path)
        XCTAssertEqual(
            plist["EnvironmentVariables"] as? [String: String],
            [
                "MICROPOD_HVF_ROOT": root.path, "PATH": "/opt/x/bin:/usr/bin", "MICROPOD_LINK_DOCKER_SOCK": "0",
                "MICROPOD_DOCKER_SOCK": "/tmp/elsewhere.sock",
            ], "only the machine's own variables reach the job")
        XCTAssertNil(plist["SoftResourceLimits"], "micropod-vmm raises its own open-file limit")

        // The default config's grace gives the 25 s the status line names.
        XCTAssertEqual(HVFMachineAutostartAgent.exitTimeOut(HVFMachineConfig()), 25)
    }

    func testLabelsKeepAThrowawayRootOffTheRealJob() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        let standard = HVFMachineLayout(root: HVFMachineLayout.standardRoot(home: home))
        XCTAssertEqual(HVFMachineAutostartAgent.label(for: standard, home: home), "com.skunkworq.micropod.machine")
        let throwaway = HVFMachineAutostartAgent.label(for: layout, home: home)
        XCTAssertNotEqual(throwaway, HVFMachineAutostartAgent.standardLabel)
        XCTAssertTrue(throwaway.hasPrefix(HVFMachineAutostartAgent.standardLabel + "."), throwaway)
        XCTAssertEqual(throwaway.count, HVFMachineAutostartAgent.standardLabel.count + 9, throwaway)
        XCTAssertNotEqual(
            throwaway,
            HVFMachineAutostartAgent.label(for: HVFMachineLayout(root: root.appendingPathComponent("b")), home: home))
        // /tmp and /private/tmp are one root, so one job.
        let privateSpelling = HVFMachineLayout(root: URL(fileURLWithPath: "/private" + root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(HVFMachineAutostartAgent.label(for: privateSpelling, home: home), throwaway)
    }

    func testProgramResolution() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let dev = URL(fileURLWithPath: "/src/.build/debug/micropod")
        let bundled = URL(fileURLWithPath: "/Applications/Micropod.app/Contents/MacOS/micropod-cli")
        func resolve(_ explicit: String?, _ env: [String: String], _ current: URL) -> String {
            HVFMachineAutostartAgent.resolveProgram(explicit: explicit, environment: env, current: current, home: home)
                .path
        }
        XCTAssertEqual(resolve("/opt/micropod", ["MICROPOD_CLI": "/x"], bundled), "/opt/micropod")
        XCTAssertEqual(resolve(nil, ["MICROPOD_CLI": "/x/micropod"], bundled), "/x/micropod")
        XCTAssertEqual(
            resolve(nil, [:], bundled), "/Users/someone/.local/bin/micropod",
            "a bundle's own path changes with every app update; the link does not")
        XCTAssertEqual(resolve(nil, [:], dev), dev.path)
    }

    // MARK: On and off

    func testOnLoadsTheJobAndRecordsIt() async throws {
        try installPlaceholders()
        let cli = try program()
        let launch = RecordingLaunchControl()
        let machine = FakeAutostartMachine()
        let agent = agent(launch, machine: machine)
        let lines = try await agent.enable(load: true, program: cli, force: false)
        XCTAssertEqual(launch.calls, ["print \(agent.label)", "bootstrap \(agent.label).plist"])
        XCTAssertEqual(machine.calls, [], "a stopped machine is started by launchd, not by us")
        XCTAssertTrue(lines.last?.contains("loaded") == true, "\(lines)")
        XCTAssertEqual(try plutilLint(agent.plistURL).status, 0)
        let record = try XCTUnwrap(HVFMachineAutostartAgent.loadRecord(layout: layout))
        XCTAssertTrue(record.enabled)
        XCTAssertEqual(record.label, agent.label)
        XCTAssertEqual(record.program, cli.path)
        XCTAssertEqual(record.exitTimeOut, 25)
        var info = stat()
        XCTAssertEqual(stat(agent.recordURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let status = await agent.status()
        XCTAssertTrue(status.enabled && status.loaded && status.plistPresent)
        XCTAssertEqual(
            status.summary, "on (launchd \(agent.label), loaded, program \(cli.path), exit timeout 25 s)")

        // The same definition again: nothing is reloaded.
        let again = try await agent.enable(load: true, program: cli, force: false)
        XCTAssertTrue(again.last?.contains("already loaded") == true, "\(again)")
        XCTAssertEqual(launch.calls.filter { !$0.hasPrefix("print") }, ["bootstrap \(agent.label).plist"])
    }

    func testOnWithoutLoadOnlyWritesThePlist() async throws {
        try installPlaceholders()
        let launch = RecordingLaunchControl()
        let agent = agent(launch, machine: FakeAutostartMachine(alive: true, busy: "3 running container(s)"))
        let lines = try await agent.enable(load: false, program: try program(), force: false)
        XCTAssertEqual(launch.calls, [], "--no-load asks launchd nothing")
        XCTAssertEqual(lines, ["autostart: on at next login (\(agent.label), \(agent.plistURL.path))"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent.plistURL.path))
        let status = await agent.status()
        XCTAssertTrue(status.summary.contains("not loaded; launchd loads it at the next login"), status.summary)
    }

    func testOnIsDeferredWhileADetachedMachineRunsContainers() async throws {
        try installPlaceholders()
        let launch = RecordingLaunchControl()
        let busy = FakeAutostartMachine(alive: true, busy: "3 running container(s) on the machine")
        do {
            _ = try await agent(launch, machine: busy).enable(load: true, program: try program(), force: false)
            XCTFail("deferred")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("deferred: 3 running container(s) on the machine"), message)
            XCTAssertTrue(message.contains("nothing was changed"), message)
            XCTAssertTrue(message.contains("--force") && message.contains("--no-load"), message)
        }
        XCTAssertEqual(launch.calls, ["print \(agent(launch).label)"])
        XCTAssertEqual(busy.calls, ["busy?"], "never stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent(launch).plistURL.path), "nothing was written")
        XCTAssertNil(HVFMachineAutostartAgent.loadRecord(layout: layout))

        // Forced: the detached machine stops, then launchd loads (and starts) it.
        let forced = try await agent(launch, machine: busy).enable(load: true, program: try program(), force: true)
        XCTAssertEqual(busy.calls, ["busy?", "stop"])
        XCTAssertEqual(launch.calls.last, "bootstrap \(agent(launch).label).plist")
        XCTAssertTrue(forced.contains("stopped the machine running outside launchd"), "\(forced)")
    }

    func testAChangedDefinitionIsReloaded() async throws {
        try installPlaceholders()
        let launch = RecordingLaunchControl()
        let first = try program()
        _ = try await agent(launch).enable(load: true, program: first, force: false)
        let other = root.appendingPathComponent("bin/micropod2")
        try FileManager.default.copyItem(at: first, to: other)
        let lines = try await agent(launch, machine: FakeAutostartMachine(alive: true)).enable(
            load: true, program: other, force: false)
        let label = agent(launch).label
        XCTAssertEqual(
            launch.calls.filter { !$0.hasPrefix("print") },
            ["bootstrap \(label).plist", "bootout \(label)", "bootstrap \(label).plist"], "bootout before bootstrap")
        XCTAssertTrue(lines.contains("unloaded the previous definition of \(label)"), "\(lines)")
        XCTAssertEqual(HVFMachineAutostartAgent.loadRecord(layout: layout)?.program, other.path)
    }

    func testOnRefusesAMachineThatIsNotInstalledOrAProgramThatIsNot() async throws {
        let launch = RecordingLaunchControl()
        do {
            _ = try await agent(launch).enable(load: true, program: URL(fileURLWithPath: "/bin/sh"), force: false)
            XCTFail("not installed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("micropod machine install"), error.localizedDescription)
        }
        try installPlaceholders()
        do {
            _ = try await agent(launch).enable(
                load: true, program: root.appendingPathComponent("nope"), force: false)
            XCTFail("no program")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("--program"), error.localizedDescription)
        }
        XCTAssertEqual(launch.calls, [])
    }

    func testAThrowawayRootNeverLoadsIntoTheRealLaunchdByDefault() async throws {
        try installPlaceholders()
        // No launch control injected and no MICROPOD_LAUNCHCTL: the real one,
        // which a root outside ~/.micropod/hvf must not load into.
        let agent = HVFMachineAutostartAgent(
            layout: layout, environment: [:], launchAgentsDirectory: agents, machine: FakeAutostartMachine())
        do {
            _ = try await agent.enable(load: true, program: try program(), force: false)
            XCTFail("refused")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("MICROPOD_AUTOSTART_ANY_ROOT"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.plistURL.path))
    }

    func testOffUnloadsRemovesAndStartsTheMachineAgainOutsideLaunchd() async throws {
        try installPlaceholders()
        let launch = RecordingLaunchControl()
        _ = try await agent(launch).enable(load: true, program: try program(), force: false)
        let label = agent(launch).label
        // Running under launchd with containers: deferred, nothing changed.
        let busy = FakeAutostartMachine(alive: true, busy: "2 running container(s) on the machine")
        do {
            _ = try await agent(launch, machine: busy).disable(force: false)
            XCTFail("deferred")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("deferred: 2 running"), error.localizedDescription)
        }
        XCTAssertEqual(launch.calls.filter { $0.hasPrefix("bootout") }, [])
        XCTAssertNotNil(HVFMachineAutostartAgent.loadRecord(layout: layout))

        let lines = try await agent(launch, machine: busy).disable(force: true)
        XCTAssertEqual(launch.calls.last, "bootout \(label)")
        XCTAssertEqual(busy.calls, ["busy?", "start"], "the machine that ran is started again, detached")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent(launch).plistURL.path))
        XCTAssertNil(HVFMachineAutostartAgent.loadRecord(layout: layout))
        XCTAssertTrue(lines.contains("machine: running again outside launchd"), "\(lines)")
        let status = await agent(launch).status()
        XCTAssertFalse(status.enabled)
        XCTAssertTrue(status.summary.hasPrefix("off (the machine starts on demand"), status.summary)
    }

    func testOffOfAMachineThatIsNotLoadedOnlyRemovesFiles() async throws {
        try installPlaceholders()
        let launch = RecordingLaunchControl()
        _ = try await agent(launch).enable(load: false, program: try program(), force: false)
        let machine = FakeAutostartMachine(alive: true, busy: "5 running container(s)")
        _ = try await agent(launch, machine: machine).disable(force: false)
        XCTAssertEqual(launch.calls, ["print \(agent(launch).label)"])
        XCTAssertEqual(machine.calls, [], "a detached machine is not launchd's to stop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent(launch).plistURL.path))
    }

    func testStatusNamesAMissingProgram() async throws {
        try installPlaceholders()
        let launch = RecordingLaunchControl()
        let cli = try program()
        _ = try await agent(launch).enable(load: false, program: cli, force: false)
        try FileManager.default.removeItem(at: cli)
        let status = await agent(launch).status()
        XCTAssertTrue(status.enabled)
        XCTAssertTrue(status.problem?.contains("\(cli.path) is missing") == true, status.problem ?? "nil")
        XCTAssertTrue(status.summary.contains("is missing"), status.summary)
    }

    // MARK: Starting through launchd

    private func writeRecord(label: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = HVFMachineAutostartAgent.Record(
            enabled: true, label: label, plist: agents.appendingPathComponent(label + ".plist").path,
            program: "/x/micropod", exitTimeOut: 25, updatedAt: Date())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: root.appendingPathComponent("autostart.json"))
    }

    func testAStartKickstartsTheLoadedJob() async throws {
        try installPlaceholders()
        let label = HVFMachineAutostartAgent.label(for: layout)
        try writeRecord(label: label)
        let launch = RecordingLaunchControl(loaded: [label])
        let layout = self.layout
        final class Holder: @unchecked Sendable {
            var lock: HVFFileLock?
            var server: FakeDockerServer?
        }
        let holder = Holder()
        // launchd starting `machine serve`: it takes the lock, records its
        // pid, publishes running and serves the Docker API.
        launch.onKickstart = {
            holder.lock = try? HVFFileLock.acquire(layout.supervisorLock, wait: .zero)
            try? holder.lock?.record(pid: getpid())
            try? HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
            holder.server = try? FakeDockerServer(path: layout.dockerSocket.path) { request in
                request.path == "/_ping" ? (200, Data("OK".utf8)) : (404, Data())
            }
        }
        defer {
            holder.server?.stop()
            holder.lock?.release()
        }
        // Were launchd not asked, the start would spawn this and fail.
        let detached = try program(exiting: 3)
        let client = HVFMachineClient(layout: layout, environment: ["MICROPOD_CLI": detached.path], launch: launch)
        try await client.ensureRunning(timeout: .seconds(10))
        XCTAssertEqual(launch.calls, ["print \(label)", "kickstart \(label)"])
        XCTAssertNotNil(holder.server, "launchd, not a detached spawn, started the supervisor")
    }

    /// The spawn a start falls back to: a stand-in CLI that exits at once,
    /// so the start fails naming it.
    private func detachedStart(_ launch: RecordingLaunchControl) async throws -> String {
        let cli = try program(exiting: 3)
        var client = HVFMachineClient(layout: layout, environment: ["MICROPOD_CLI": cli.path], launch: launch)
        client.kickstartHandoverWait = .milliseconds(200)
        do {
            try await client.ensureRunning(timeout: .seconds(10))
            XCTFail("the stand-in exits")
            return ""
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("\(cli.path) machine serve"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("exited with status 3"), error.localizedDescription)
            return error.localizedDescription
        }
    }

    func testAStartWithoutAutostartNeverAsksLaunchd() async throws {
        try installPlaceholders()
        let launch = RecordingLaunchControl(loaded: [HVFMachineAutostartAgent.label(for: layout)])
        _ = try await detachedStart(launch)
        XCTAssertEqual(launch.calls, [], "no autostart.json: launchctl is never run")
    }

    func testAStartFallsBackToADetachedSupervisorWhenLaunchdCannot() async throws {
        try installPlaceholders()
        let label = HVFMachineAutostartAgent.label(for: layout)
        try writeRecord(label: label)

        let failing = RecordingLaunchControl(loaded: [label])
        failing.kickstartError = MicropodError.message("launchctl kickstart failed (5)")
        _ = try await detachedStart(failing)
        XCTAssertEqual(failing.calls, ["print \(label)", "kickstart \(label)"])

        let silent = RecordingLaunchControl(loaded: [label])
        _ = try await detachedStart(silent)
        XCTAssertEqual(
            silent.calls, ["print \(label)", "kickstart \(label)"], "a kickstart that starts nothing in time")

        let unloaded = RecordingLaunchControl()
        _ = try await detachedStart(unloaded)
        XCTAssertEqual(unloaded.calls, ["print \(label)"], "a job launchd does not have is not kickstarted")
    }
}
