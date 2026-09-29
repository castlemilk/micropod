import XCTest

@testable import MicropodCore

/// Command construction for persistent-machine keep-alive
/// (`micropod machines run/stop`).
final class MachineCommandTests: XCTestCase {
    func testRunMachinePassesArgvThrough() {
        let command = ContainerCommandFactory.runMachine(
            "ci-keepalive",
            extraArgs: ["--env", "FOO=bar", "--workdir", "/tmp"],
            command: ["go", "test", "./..."])
        XCTAssertEqual(
            command.arguments,
            [
                "machine", "run", "-n", "ci-keepalive", "--env", "FOO=bar",
                "--workdir", "/tmp", "go", "test", "./...",
            ])
    }

    func testStopMachine() {
        let command = ContainerCommandFactory.stopMachine("ci-keepalive")
        XCTAssertEqual(command.arguments, ["machine", "stop", "ci-keepalive"])
    }
}

/// `container machine list` decoding + mapping machines onto the per-boot
/// containers whose stats back their metrics.
final class MachineObservabilityTests: XCTestCase {
    func testDecodesContainer1xMachineList() throws {
        let json = """
            [{"cpus":9,"createdDate":"2026-09-29T11:22:03Z","diskSize":1169211392,"memory":8589934592,\
            "ipAddress":"192.168.65.100","id":"mp-probe","default":false,"status":"running"}]
            """
        let machines = try MicropodJSON.decodeArray(MachineEntry.self, from: Data(json.utf8), context: "t")
        XCTAssertEqual(machines.count, 1)
        let m = machines[0]
        XCTAssertEqual(m.name, "mp-probe")
        XCTAssertEqual(m.state, "running")
        XCTAssertTrue(m.isRunning)
        XCTAssertEqual(m.ip, "192.168.65.100")
        XCTAssertEqual(m.cpus, 9)
        XCTAssertEqual(m.memoryBytes, 8_589_934_592)
        XCTAssertEqual(m.diskBytes, 1_169_211_392)
        XCTAssertEqual(m.created, "2026-09-29T11:22:03Z")
        XCTAssertEqual(m.defaultMachine, false)
        XCTAssertNotNil(m.memory)
    }

    func testDecodesLegacyMachineList() throws {
        let json = """
            [{"name":"dev","state":"stopped","cpus":2,"memory":"2G","defaultMachine":true}]
            """
        let m = try MicropodJSON.decodeArray(MachineEntry.self, from: Data(json.utf8), context: "t")[0]
        XCTAssertEqual(m.name, "dev")
        XCTAssertEqual(m.memory, "2G")
        XCTAssertEqual(m.defaultMachine, true)
        XCTAssertFalse(m.isRunning)
    }

    func testMachineLogsCommand() {
        XCTAssertEqual(
            ContainerCommandFactory.machineLogs("ci", tail: 50, follow: true, boot: true).arguments,
            ["machine", "logs", "--boot", "--follow", "-n", "50", "ci"])
    }

    func testMatchesPerBootBackingContainer() {
        let entries: [(id: String, value: Int)] = [
            ("ci-a1b2c3-f00ba4", 1),  // backing container of machine "ci-a1b2c3"
            ("ci-2553d3", 2),  // backing container of machine "ci"
            ("ci-builder", 3),  // an ordinary container — not 6 hex
            ("web-ABCDEF", 4),  // uppercase isn't the runtime's suffix form
        ]
        let matched = MachineStatsSampler.backingEntries(entries, machines: ["ci", "ci-a1b2c3", "web", "gone"])
        XCTAssertEqual(matched["ci"], 2)
        XCTAssertEqual(matched["ci-a1b2c3"], 1)
        XCTAssertNil(matched["web"])
        XCTAssertNil(matched["gone"])
    }

    func testStatsFromBackingEntry() throws {
        let json = """
            {"id":"mp-probe-2553d3","cpuUsageUsec":6576389781,"memoryUsageBytes":440205312,\
            "memoryLimitBytes":68719476736,"networkRxBytes":45584,"networkTxBytes":602,\
            "blockReadBytes":5189632,"blockWriteBytes":419430400,"numProcesses":13}
            """
        let entry = try JSONDecoder().decode(ContainerStatsEntry.self, from: Data(json.utf8))
        let stats = MachineStatsSampler.stats(machine: MachineEntry(name: "mp-probe", cpus: 9), entry: entry)
        XCTAssertEqual(stats.id, "mp-probe")
        XCTAssertEqual(stats.containerID, "mp-probe-2553d3")
        XCTAssertEqual(stats.cpus, 9)
        XCTAssertEqual(stats.memoryUsedBytes, 440_205_312)
        XCTAssertEqual(stats.memoryLimitBytes, 68_719_476_736)
        XCTAssertEqual(stats.networkRxBytes, 45_584)
        XCTAssertEqual(stats.blockWriteBytes, 419_430_400)
        XCTAssertEqual(stats.pids, 13)
    }
}
