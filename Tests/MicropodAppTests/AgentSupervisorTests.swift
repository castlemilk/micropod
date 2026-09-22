import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

final class AgentSupervisorTests: XCTestCase {
    private var runDirectory: URL!

    override func setUp() async throws {
        runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-supervisor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: runDirectory)
    }

    // MARK: - Unix socket probe

    func testUnixSocketProbeDetectsBoundAndUnboundPaths() throws {
        // sun_path is ~104 bytes — keep the test path short.
        let socketPath = "/tmp/mpsup-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        XCTAssertFalse(AgentSupervisor.unixSocketAccepts(socketPath))

        let fd = try bindUnixListener(at: socketPath)
        defer { close(fd) }
        XCTAssertTrue(AgentSupervisor.unixSocketAccepts(socketPath))
    }

    // MARK: - Spawn / adopt / terminate

    func testHealthyEndpointIsAdoptedWithoutSpawn() async throws {
        let spec = AgentSpec(
            id: "fake", displayName: "Fake", binaryName: "definitely-not-a-real-binary",
            probe: .custom { true },
            enabledDefaultsKey: "test.fake.enabled", endpoint: "nowhere")
        let statuses = StatusSink()
        let supervisor = AgentSupervisor(
            specs: [spec], runDirectory: runDirectory,
            isEnabled: { _ in true },
            onStatus: { statuses.record($0) })

        await supervisor.tick()

        let status = await supervisor.statuses().first
        XCTAssertEqual(status?.state, .adopted)
        XCTAssertNil(status?.pid)
    }

    func testUnhealthySpecSpawnsAndTerminatesOwnedChild() async throws {
        // A real process we control: /bin/sleep with a probe that only goes
        // healthy once we flip the flag — proves spawn → running → terminate.
        let healthy = FlagBox()
        let spec = AgentSpec(
            id: "sleeper", displayName: "Sleeper", binaryName: "sleep",
            arguments: ["300"],
            probe: .custom { healthy.value },
            enabledDefaultsKey: "test.sleeper.enabled", endpoint: "n/a",
            binaryPathOverride: "/bin/sleep", reapsForeignCopies: false)
        let supervisor = AgentSupervisor(
            specs: [spec], runDirectory: runDirectory,
            isEnabled: { _ in true },
            onStatus: { _ in })

        // One failed probe is only a suspicion — spawn happens on the
        // second consecutive miss.
        await supervisor.tick()
        var status = await supervisor.statuses().first
        XCTAssertNil(status?.pid)

        await supervisor.tick()
        status = await supervisor.statuses().first
        XCTAssertEqual(status?.state, .starting)
        let pid = status?.pid
        XCTAssertNotNil(pid)

        // Probe goes healthy → owned child marked running.
        healthy.set(true)
        await supervisor.tick()
        status = await supervisor.statuses().first
        XCTAssertEqual(status?.state, .running)
        XCTAssertEqual(status?.pid, pid)

        // PID file exists while the child is ours.
        let pidFile = runDirectory.appendingPathComponent("sleeper.pid")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))

        // Quit-time teardown kills the owned child and removes the pid file.
        supervisor.terminateOwnedSync()
        XCTAssertFalse(processAlive(pid!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testDisabledAgentIsNotSpawned() async throws {
        let spec = AgentSpec(
            id: "off", displayName: "Off", binaryName: "sleep",
            arguments: ["300"],
            probe: .custom { false },
            enabledDefaultsKey: "test.off.enabled", endpoint: "n/a",
            binaryPathOverride: "/bin/sleep")
        let supervisor = AgentSupervisor(
            specs: [spec], runDirectory: runDirectory,
            isEnabled: { _ in false },
            onStatus: { _ in })

        await supervisor.tick()

        let status = await supervisor.statuses().first
        XCTAssertEqual(status?.state, .stopped)
        XCTAssertNil(status?.pid)
    }

    // MARK: - Orphan reaping safety

    func testStalePidFileDoesNotKillUnrelatedProcess() async throws {
        // A live process whose path does NOT match the spec binary — the
        // pid could have been recycled; the supervisor must leave it alone.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer {
            if sleeper.isRunning { sleeper.terminate() }
        }
        XCTAssertTrue(processAlive(sleeper.processIdentifier))

        let record: [String: Any] = [
            "pid": Int(sleeper.processIdentifier),
            "binary": "nonexistent-test-shim",
        ]
        let pidFile = runDirectory.appendingPathComponent("docker-shim.pid")
        try JSONSerialization.data(withJSONObject: record).write(to: pidFile)

        // The override keeps the supervisor from resolving the real shim in
        // .build/ and spawning it mid-test — the agent lands in `.missing`.
        let spec = AgentSpec(
            id: "docker-shim", displayName: "Shim", binaryName: "nonexistent-test-shim",
            probe: .custom { false },
            enabledDefaultsKey: "test.shim.enabled", endpoint: "sock",
            binaryPathOverride: "/nonexistent/nonexistent-test-shim",
            reapsForeignCopies: false)
        let supervisor = AgentSupervisor(
            specs: [spec], runDirectory: runDirectory,
            isEnabled: { _ in true },
            onStatus: { _ in })

        // Reaping needs two confirmed misses.
        await supervisor.tick()
        await supervisor.tick()

        XCTAssertTrue(
            processAlive(sleeper.processIdentifier),
            "orphan reaper must never kill a pid that isn't our binary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    /// "Restart All" must not respawn a disabled agent — restart() runs a
    /// tick, and a tick on a disabled spec stops it rather than spawning.
    func testRestartAllSkipsDisabledAgents() async throws {
        let enabled = AgentSpec(
            id: "on", displayName: "On", binaryName: "definitely-not-a-real-binary",
            probe: .custom { true },
            enabledDefaultsKey: "test.on.enabled", endpoint: "nowhere")
        let disabled = AgentSpec(
            id: "off", displayName: "Off", binaryName: "sleep",
            arguments: ["300"],
            probe: .custom { false },
            enabledDefaultsKey: "test.off.enabled", endpoint: "n/a",
            binaryPathOverride: "/bin/sleep", reapsForeignCopies: false)
        let supervisor = AgentSupervisor(
            specs: [enabled, disabled], runDirectory: runDirectory,
            isEnabled: { $0.id == "on" },
            onStatus: { _ in })

        await supervisor.tick()
        await supervisor.restartAll()

        let statuses = await supervisor.statuses()
        XCTAssertEqual(statuses.first { $0.id == "on" }?.state, .adopted)
        let off = statuses.first { $0.id == "off" }
        XCTAssertEqual(off?.state, .stopped)
        XCTAssertNil(off?.pid)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runDirectory.appendingPathComponent("off.pid").path))
    }

    // MARK: - Helpers

    private func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func bindUnixListener(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "path-too-long", code: 0)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBufferPointer { src in
                memcpy(dest.baseAddress, src.baseAddress!, pathBytes.count)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
        guard listen(fd, 1) == 0 else { throw NSError(domain: "listen", code: Int(errno)) }
        return fd
    }
}

/// Mutable flag readable from the @Sendable probe closure.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func set(_ newValue: Bool) {
        lock.lock()
        flag = newValue
        lock.unlock()
    }
}

/// Collects the latest published status list.
private final class StatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [AgentStatus] = []
    func record(_ statuses: [AgentStatus]) {
        lock.lock()
        latest = statuses
        lock.unlock()
    }
}
