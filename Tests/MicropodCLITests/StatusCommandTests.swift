import Darwin
import Foundation
import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodCLI

/// `micropod status`: routed before `Services` (no Apple ping when Apple is
/// not enabled), the machine read from the API when one answers for this
/// root and in-process otherwise, and one line per fact.
final class StatusCommandTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = URL(fileURLWithPath: "/tmp/mpsc-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var environment: [String: String] {
        try? Data(#"{"default":"hvf","engines":{"apple":{"enabled":false}}}"#.utf8)
            .write(to: root.appendingPathComponent("runtimes.json"))
        return [
            "MICROPOD_HVF_ROOT": root.appendingPathComponent("hvf").path,
            "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
            "MICROPOD_API_SOCK": root.appendingPathComponent("api.sock").path,
            // Nothing listens here: a refused socket must not fall through
            // to the live API on 45454.
            "MICROPOD_API_PORT": "20491",
        ]
    }

    func testStatusRoutesPastTheGlobalFlagsAndNothingElse() {
        XCTAssertEqual(StatusCommand.route(["status"])?.args, [])
        XCTAssertEqual(StatusCommand.route(["--json", "status"])?.json, true)
        XCTAssertEqual(StatusCommand.route(["status", "--no-color"])?.json, false)
        XCTAssertEqual(StatusCommand.route(["--cli", "/x/container", "status"])?.cliPath, "/x/container")
        XCTAssertNil(StatusCommand.route(["machine", "status"]))
        XCTAssertNil(StatusCommand.route(["docker", "status"]))
        XCTAssertNil(StatusCommand.route(["ps"]))
        XCTAssertTrue(MicropodCLI.helpText.contains("status [--json]"))
    }

    private func machine(_ configure: (inout Micropod_V1_HVFMachineStatus) -> Void) -> Micropod_V1_HVFMachineStatus {
        var m = Micropod_V1_HVFMachineStatus()
        m.root = "/r"
        m.socket = "/r/run/docker.sock"
        m.dockerEndpoint = "unix:///r/run/docker.sock"
        m.installed = true
        configure(&m)
        return m
    }

    private func lines(
        _ m: Micropod_V1_HVFMachineStatus, source: StatusCommand.Source = .disk, docker: Bool = false,
        context: HVFDockerWiring.StoredContext? = nil
    ) -> [String: String] {
        let record =
            docker
            ? HVFDockerWiring.Record(
                previousContext: "desktop-linux", selectedByMicropod: true, builderInstalled: false,
                endpoint: m.dockerEndpoint, installedAt: Date()) : nil
        let report = StatusCommand.Report(
            defaultRuntime: "hvf", enabledRuntimes: ["sandbox", "hvf"], machine: m, source: source, docker: record,
            context: context
                ?? (docker
                    ? .init(host: m.dockerEndpoint, pointsHere: true, current: "micropod")
                    : .init(host: nil, pointsHere: false, current: "default")),
            appleShown: false)
        return Dictionary(StatusCommand.lines(report), uniquingKeysWith: { $1 })
    }

    func testARunningMachine() {
        let m = machine {
            $0.readiness = "running"
            $0.engineVersion = "micropod"
            $0.engineApiVersion = "1.47"
            $0.engineMinApiVersion = "1.44"
            $0.containersTotal = 5
            $0.containersRunning = 3
            $0.cacheDisk = .with {
                $0.mounted = true
                $0.sizeBytes = 32 << 30
                $0.freeBytes = 22_977_568_768
            }
            $0.diskFlush = "barrier (both disks)"
            $0.updatePending = true
            $0.stagedVersion = "0.9.3"
            $0.autostart = .with {
                $0.enabled = true
                $0.loaded = true
            }
        }
        let l = lines(m, source: .api("/Users/me/.micropod/api.sock"), docker: true)
        XCTAssertEqual(l["runtime:"], "hvf (default); also enabled: sandbox")
        XCTAssertEqual(l["machine:"], "running")
        XCTAssertEqual(l["engine:"], "micropod (Docker API 1.44–1.47)")
        XCTAssertEqual(l["containers:"], "3 running, 5 total")
        XCTAssertEqual(l["docker:"], "unix:///r/run/docker.sock (context micropod, selected)")
        XCTAssertEqual(l["cache disk:"], "mounted, 21.4 GiB free of 32.0 GiB")
        XCTAssertEqual(l["disk flush:"], "barrier (both disks)")
        XCTAssertEqual(l["update:"], "pending: 0.9.3 staged (`micropod update hvf apply`)")
        XCTAssertEqual(l["autostart:"], "on (loaded)")
        XCTAssertEqual(l["api:"], "running (/Users/me/.micropod/api.sock)")
        XCTAssertEqual(l["apple:"], "not enabled")
    }

    /// The record says what `docker install --use` did; the docker line
    /// says what the docker CLI's files say now.
    func testTheDockerLineFollowsTheStoreNotTheRecord() {
        let m = machine { $0.readiness = "running" }
        func docker(_ context: HVFDockerWiring.StoredContext, recorded: Bool = true) -> String? {
            lines(m, docker: recorded, context: context)["docker:"]
        }
        XCTAssertEqual(
            docker(.init(host: m.dockerEndpoint, pointsHere: true, current: "desktop-linux")),
            "unix:///r/run/docker.sock (context micropod; current context: desktop-linux)",
            "the user switched away after `install --use`: the record still says selected")
        XCTAssertEqual(
            docker(.init(host: nil, pointsHere: false, current: "default")),
            "unix:///r/run/docker.sock (docker context micropod was removed: `micropod docker install` creates it again)"
        )
        XCTAssertEqual(
            docker(.init(host: "unix:///elsewhere.sock", pointsHere: false, current: "micropod")),
            "unix:///r/run/docker.sock (docker context micropod points at unix:///elsewhere.sock, not this machine: "
                + "`micropod docker install --force`)")
        XCTAssertEqual(
            docker(.init(host: m.dockerEndpoint, pointsHere: true, current: "micropod"), recorded: false),
            "unix:///r/run/docker.sock (context micropod, selected)",
            "selected by hand with `docker context use micropod`: no record")
    }

    func testMachineStatesAndWhy() {
        XCTAssertEqual(lines(machine { $0.readiness = "starting" })["machine:"], "starting")
        XCTAssertEqual(
            lines(
                machine {
                    $0.readiness = "failed"
                    $0.failureReason = "micropod-vmm exited 3 times within 60 s"
                })["machine:"], "failed: micropod-vmm exited 3 times within 60 s")
        XCTAssertEqual(
            lines(
                machine {
                    $0.readiness = "stopped"
                    $0.stoppedOnRequest = true
                })["machine:"], "stopped (on request)")
        let missing = lines(
            machine {
                $0.installed = false
                $0.readiness = "not-installed"
                $0.failureReason = "missing disk.ext4"
            })
        XCTAssertEqual(missing["machine:"], "not installed: missing disk.ext4 (micropod setup)")
        XCTAssertNil(missing["cache disk:"], "nothing to say of a disk that is not there")
        XCTAssertNil(missing["engine:"])
        XCTAssertNil(missing["containers:"])
        XCTAssertEqual(lines(machine { $0.readiness = "stopped" })["update:"], "none")
        XCTAssertEqual(
            lines(machine { $0.readiness = "stopped" })["docker:"],
            "unix:///r/run/docker.sock (no docker context: `micropod docker install`)")
        XCTAssertEqual(lines(machine { $0.readiness = "stopped" })["api:"], "not running (read from disk)")
        XCTAssertTrue(
            lines(machine { $0.readiness = "stopped" })["autostart:"]?.hasPrefix("off") == true)
        XCTAssertEqual(
            lines(machine { $0.autostart = .with { $0.enabled = true } })["autostart:"],
            "on (launchd loads it at the next login)")
        XCTAssertEqual(
            lines(machine { $0.readiness = "stopped" }, source: .otherRoot(api: "/a.sock", root: "/elsewhere"))["api:"],
            "running (/a.sock) for another machine (/elsewhere); read from disk")
    }

    func testWithNoAPITheMachineIsReadFromDisk() async throws {
        let report = await StatusCommand.gather(environment: environment)
        XCTAssertEqual(report.source, .disk)
        XCTAssertEqual(report.machine.root, root.appendingPathComponent("hvf").path)
        XCTAssertEqual(report.machine.readiness, "not-installed")
        XCTAssertFalse(report.appleShown, "Apple is disabled and not the default: never asked")
        XCTAssertEqual(report.defaultRuntime, "hvf")
    }

    func testAnAPIForThisRootIsBelievedAndOneForAnotherIsNot() async throws {
        let environment = environment
        let hvf = root.appendingPathComponent("hvf").path
        func answering(_ root: String) throws -> UnixHTTPServer {
            let reply = try Micropod_V1_HVFMachineStatus.with {
                $0.root = root
                $0.readiness = "running"
                $0.summary = "running (vmm pid 7, restarts 0)"
                $0.containersRunning = 4
                $0.containersTotal = 4
            }.serializedData()
            return try UnixHTTPServer(
                path: environment["MICROPOD_API_SOCK"]!, contentType: "application/proto", body: reply)
        }
        let ours = try answering(hvf)
        let believed = await StatusCommand.gather(environment: environment)
        ours.stop()
        XCTAssertEqual(believed.source, .api(environment["MICROPOD_API_SOCK"]!))
        XCTAssertEqual(believed.machine.containersRunning, 4)
        XCTAssertEqual(ours.requests, 1)
        try await Task.sleep(for: .milliseconds(50))

        let theirs = try answering("/Users/someone/.micropod/hvf")
        let doubted = await StatusCommand.gather(environment: environment)
        theirs.stop()
        XCTAssertEqual(
            doubted.source, .otherRoot(api: environment["MICROPOD_API_SOCK"]!, root: "/Users/someone/.micropod/hvf"))
        XCTAssertEqual(doubted.machine.root, hvf, "this root's machine, read from disk")
        XCTAssertEqual(doubted.machine.readiness, "not-installed")
    }
}
