import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodCLI
@testable import MicropodRuntime

/// `micropod machine autostart on|off|status` through the environment a
/// throwaway machine uses: `MICROPOD_LAUNCHCTL` names a recording stand-in
/// for launchctl and `MICROPOD_LAUNCH_AGENTS_DIR` a temp directory, so the
/// real launchd and ~/Library/LaunchAgents are never touched.
final class MachineAutostartCommandsTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = URL(fileURLWithPath: "/tmp/mpac-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }
    private var log: URL { root.appendingPathComponent("launchctl.log") }

    private func executable(_ name: String, _ script: String) throws -> URL {
        let url = root.appendingPathComponent("bin/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o755), 0)
        return url
    }

    /// launchctl as far as autostart uses it: `print` answers 113 (not
    /// loaded) until a `bootstrap`, and every call is logged.
    private func recordingLaunchctl() throws -> URL {
        let loaded = root.appendingPathComponent("loaded")
        return try executable(
            "launchctl",
            """
            #!/bin/sh
            echo "$*" >> '\(log.path)'
            case "$1" in
              print) [ -f '\(loaded.path)' ] || exit 113; echo "program = /x" ;;
              bootstrap) touch '\(loaded.path)' ;;
              bootout) rm -f '\(loaded.path)' ;;
            esac
            exit 0
            """)
    }

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

    private func run(_ args: [String], _ environment: [String: String]) async throws -> Int32 {
        try await MachineCommands.autostart(
            args, agent: HVFMachineAutostartAgent(layout: layout, environment: environment),
            client: HVFMachineClient(layout: layout, environment: environment), environment: environment,
            json: true, handover: .milliseconds(100))
    }

    func testAutostartRoutesAsAnHVFMachineCommand() {
        XCTAssertEqual(
            MachineCommands.route(["machine", "autostart", "on", "--no-load"])?.args, ["autostart", "on", "--no-load"])
        XCTAssertEqual(MachineCommands.route(["--json", "machine", "autostart", "status"])?.json, true)
        XCTAssertTrue(MachineCommands.helpText.contains("machine autostart on [--no-load]"))
        XCTAssertTrue(MachineCommands.helpText.contains("serve [--link-socket]"))
    }

    func testOnStatusOffDriveTheLaunchctlTheEnvironmentNames() async throws {
        try installPlaceholders()
        let launchctl = try recordingLaunchctl()
        let agents = root.appendingPathComponent("LaunchAgents")
        let program = try executable("micropod", "#!/bin/sh\nexit 0\n")
        let environment = [
            "MICROPOD_HVF_ROOT": root.path, "MICROPOD_LAUNCHCTL": launchctl.path,
            "MICROPOD_LAUNCH_AGENTS_DIR": agents.path, "MICROPOD_LINK_DOCKER_SOCK": "0", "PATH": "/usr/bin:/bin",
        ]
        let label = HVFMachineAutostartAgent.label(for: layout)
        let plist = agents.appendingPathComponent(label + ".plist")
        let domain = "gui/\(getuid())"

        let on = try await run(["on", "--program", program.path], environment)
        XCTAssertEqual(on, ExitCode.ok)
        let afterOn = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(
            afterOn.filter { !$0.hasPrefix("print ") }, ["bootstrap \(domain) \(plist.path)"],
            "one load, into the domain launchctl is told")
        XCTAssertEqual(Set(afterOn.filter { $0.hasPrefix("print ") }), ["print \(domain)/\(label)"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plist.path), "the plist went to MICROPOD_LAUNCH_AGENTS_DIR")
        let defined = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(defined["ProgramArguments"] as? [String], [program.path, "machine", "serve", "--link-socket"])
        XCTAssertEqual(
            (defined["EnvironmentVariables"] as? [String: String])?["MICROPOD_LINK_DOCKER_SOCK"], "0",
            "a throwaway machine's job leaves the canonical socket alone too")
        XCTAssertNil((defined["EnvironmentVariables"] as? [String: String])?["MICROPOD_LAUNCHCTL"])

        let status = await HVFMachineAutostartAgent(layout: layout, environment: environment).status()
        XCTAssertTrue(status.enabled && status.loaded, status.summary)

        let off = try await run(["off"], environment)
        XCTAssertEqual(off, ExitCode.ok)
        let afterOff = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(afterOff.filter { !$0.hasPrefix("print ") }.last, "bootout \(domain)/\(label)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertNil(HVFMachineAutostartAgent.loadRecord(layout: layout))
    }

    func testOnWithoutLoadOnlyAsksLaunchctl() async throws {
        try installPlaceholders()
        let launchctl = try recordingLaunchctl()
        let program = try executable("micropod", "#!/bin/sh\nexit 0\n")
        let environment = [
            "MICROPOD_LAUNCHCTL": launchctl.path, "MICROPOD_LAUNCH_AGENTS_DIR": root.appendingPathComponent("LA").path,
        ]
        let on = try await run(["on", "--no-load", "--program", program.path], environment)
        XCTAssertEqual(on, ExitCode.ok)
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(calls.filter { !$0.hasPrefix("print ") }, [], "nothing was loaded: only the status line asked")
        XCTAssertEqual(HVFMachineAutostartAgent.loadRecord(layout: layout)?.program, program.path)
    }

    /// `machine serve --link-socket` (what the LaunchAgent runs) links the
    /// canonical Docker socket once the machine it supervises serves, and
    /// not before.
    func testServeLinksTheCanonicalSocketOnceReady() async throws {
        try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("canonical/docker.sock")
        let client = HVFMachineClient(
            layout: layout, environment: ["MICROPOD_HVF_ROOT": root.path, "MICROPOD_DOCKER_SOCK": link.path])
        let linker = Task { await MachineCommands.linkWhenReady(client, poll: .milliseconds(20)) }
        defer { linker.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path), "nothing serves yet")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))

        let held = try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { held.release() }
        try HVFMachineState(phase: .running, supervisorPID: getpid(), vmmPID: getpid()).save(to: layout.state)
        let server = try UnixHTTPServer(path: layout.dockerSocket.path)
        defer { server.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), layout.dockerSocket.path)
        _ = await linker.value
    }

    /// A refusal is the command's failure, printed without its code prefix;
    /// a usage error stays one.
    func testARefusalIsAFailureNotAThrow() async throws {
        let launchctl = try recordingLaunchctl()
        let environment = [
            "MICROPOD_LAUNCHCTL": launchctl.path, "MICROPOD_LAUNCH_AGENTS_DIR": root.appendingPathComponent("LA").path,
        ]
        let code = try await MachineCommands.autostartReportingPlainly(
            ["on", "--program", "/bin/sh"], agent: HVFMachineAutostartAgent(layout: layout, environment: environment),
            client: HVFMachineClient(layout: layout, environment: environment), environment: environment, json: false)
        XCTAssertEqual(code, ExitCode.failure, "not installed")
        XCTAssertEqual(MachineCommands.withoutCode("failedPrecondition: deferred: 1 running"), "deferred: 1 running")
        do {
            _ = try await MachineCommands.autostartReportingPlainly(
                ["sideways"], agent: HVFMachineAutostartAgent(layout: layout, environment: environment),
                client: HVFMachineClient(layout: layout, environment: environment), environment: environment,
                json: false)
            XCTFail("usage")
        } catch is UsageError {}
    }

    func testUsage() async throws {
        do {
            _ = try await run(["sideways"], [:])
            XCTFail("usage")
        } catch let error as UsageError {
            XCTAssertTrue(error.message.contains("autostart on"), error.message)
        }
    }
}
