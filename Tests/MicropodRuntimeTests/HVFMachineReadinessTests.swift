import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Readiness from live machine state, over a fake guest Docker API:
/// installed assets alone are never `running`.
final class HVFMachineReadinessTests: XCTestCase {
    private var root: URL!
    private var held: [HVFFileLock] = []
    private var server: FakeDockerServer?

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-y-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        server?.stop()
        for lock in held { lock.release() }
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }
    private var client: HVFMachineClient { HVFMachineClient(layout: layout, environment: [:]) }

    /// Placeholder assets; with `bundle`, a tool bundle that ships BuildKit
    /// and an engine that attaches caches.
    private func install(bundle: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
        guard bundle else { return }
        for name in HVFMachineLayout.buildkitBundleFiles {
            XCTAssertTrue(fm.createFile(atPath: layout.tools.appendingPathComponent(name).path, contents: Data()))
        }
        XCTAssertEqual(chmod(layout.tools.appendingPathComponent("runner/bin/buildkitd").path, 0o755), 0)
        let manifest = #"{"cacheApi": 1, "capabilities": ["caches", "buildkit", "grpc-build"]}"#
        try Data(manifest.utf8).write(to: layout.toolsManifest)
    }

    private func supervise(_ phase: HVFMachinePhase) throws {
        held.append(try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero)))
        try HVFMachineState(phase: phase, supervisorPID: getpid(), vmmPID: 4242).save(to: layout.state)
    }

    private func guest(_ route: @escaping FakeDockerServer.Route = { _ in (404, Data()) }) throws -> FakeDockerServer {
        let server = try FakeDockerServer(path: layout.dockerSocket.path, route: route)
        self.server = server
        return server
    }

    // MARK: Readiness

    func testInstalledAssetsWithoutASupervisorAreStoppedNotRunning() async throws {
        try install()
        let readiness = await client.readiness()
        XCTAssertEqual(readiness.status, .stopped)
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.features, ["hvf", "rootless", "proto-binary"], "nothing live is advertised")
        XCTAssertEqual(readiness.componentState, "stopped")

        // A stale `running` record with no supervisor behind it is stopped too.
        try HVFMachineState(phase: .running, supervisorPID: 1, vmmPID: 2).save(to: layout.state)
        let stale = await client.readiness()
        XCTAssertEqual(stale.status, .stopped)
        XCTAssertTrue(stale.detail.contains("exited without stopping"), stale.detail)
    }

    func testAMachineThatIsNotInstalledOrHasFailedSaysSo() async throws {
        let missing = await client.readiness()
        XCTAssertEqual(missing.status, .notInstalled)
        XCTAssertEqual(missing.componentState, "missing")
        XCTAssertTrue(missing.detail.contains("not installed"), missing.detail)

        try install()
        try HVFMachineState(phase: .failed, supervisorPID: 1, lastExitReason: "micropod-vmm exited 78")
            .save(to: layout.state)
        let failed = await client.readiness()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.detail.contains("exited 78"), failed.detail)
    }

    func testASupervisorThatIsStillBootingIsStarting() async throws {
        try install()
        try supervise(.starting)
        let starting = await client.readiness()
        XCTAssertEqual(starting.status, .starting)
        XCTAssertFalse(starting.features.contains("buildkit"))
        try HVFMachineState(phase: .stopping, supervisorPID: getpid()).save(to: layout.state)
        let stopping = await client.readiness()
        XCTAssertEqual(stopping.status, .stopping)
    }

    func testRunningIsNotReadyUntilTheGuestAnswers() async throws {
        try install()
        try supervise(.running)
        let noSocket = await client.readiness()
        XCTAssertEqual(noSocket.status, .notReady)
        XCTAssertTrue(noSocket.detail.contains("no Docker socket"), noSocket.detail)

        // Something is at the socket path, but no guest answers on it.
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.dockerSocket.path, contents: Data()))
        let silent = await client.readiness(pingTimeout: .milliseconds(200))
        XCTAssertEqual(silent.status, .notReady)
        XCTAssertTrue(silent.detail.contains("did not answer _ping"), silent.detail)
        XCTAssertEqual(silent.features, ["hvf", "rootless", "proto-binary"])
    }

    func testARunningMachineThatAnswersIsReadyAndPingsOncePerWindow() async throws {
        try install()
        try supervise(.running)
        let server = try guest()
        let ready = await client.readiness()
        XCTAssertEqual(ready.status, .running)
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.features, ["hvf", "rootless", "proto-binary", "caches-v2", "buildkit"])
        XCTAssertEqual(ready.componentState, "running")
        let again = await client.readiness()
        XCTAssertEqual(again.status, .running)
        XCTAssertEqual(server.requests.map(\.path), ["/_ping"], "a fresh answer stands for the window")

        // Features follow the installed bundle, not a fixed list.
        try FileManager.default.removeItem(at: layout.tools.appendingPathComponent("runner/bin/buildkitd"))
        try FileManager.default.removeItem(at: layout.toolsManifest)
        let plain = await client.readiness()
        XCTAssertEqual(plain.status, .running)
        XCTAssertEqual(plain.features, ["hvf", "rootless", "proto-binary"])
    }
}
