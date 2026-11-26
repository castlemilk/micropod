import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The API's `container` client asks `AppleRuntimeLiveness` (one XPC ping,
/// kept for 2 s) before spawning: with hvf the default and Apple's runtime
/// installed but stopped, a listing used to start `container list --all`
/// (plus its `launchctl` grandchild) on every call (B25 L-CENSUS: 9851
/// children in one latency run).
final class AppleRuntimeLivenessTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var held: [HVFFileLock] = []
    private var guest: FakeDockerServer?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-liveness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-l-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        guest?.stop()
        for lock in held { lock.release() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// The checked-in mock CLI in its stopped mode, named `container`; every
    /// invocation lands in `calls.log`.
    private func stoppedCLI() throws -> URL {
        let mock = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MicropodIntegrationTests/Support/mock-container")
        guard FileManager.default.isExecutableFile(atPath: mock.path) else {
            throw XCTSkip("mock container CLI missing at \(mock.path)")
        }
        let wrapper = directory.appendingPathComponent("bin/container")
        let script =
            "#!/bin/bash\n"
            + "export MICROPOD_MOCK_STATE_DIR=\"\(directory.path)\"\n"
            + "export MICROPOD_MOCK_RUNTIME_STOPPED=1\n"
            + "exec \"\(mock.path)\" \"$@\"\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper
    }

    /// Spawned command lines other than the CLI's own (cached) version read.
    private var spawned: [String] {
        let log = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("system version") }
    }

    /// An installed hvf machine whose guest lists `ids`.
    private func servingHVF(_ ids: [String]) throws {
        let layout = HVFMachineLayout(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
        held.append(try XCTUnwrap(try HVFFileLock.acquire(layout.supervisorLock, wait: .zero)))
        try HVFMachineState(phase: .running, supervisorPID: getpid()).save(to: layout.state)
        let rows = ids.map { #"{"id": "\#($0)", "name": "\#($0)", "image": "alpine", "state": "running"}"# }
        guest = try FakeDockerServer(path: layout.dockerSocket.path) { request in
            request.path == "/micropod/containers/summary"
                ? (200, Data(#"{"containers": [\#(rows.joined(separator: ","))]}"#.utf8))
                : (404, Data(#"{"message": "unexpected"}"#.utf8))
        }
    }

    private func registry(default name: String) -> EngineRegistry {
        EngineRegistry(
            environment: [
                "MICROPOD_RUNTIMES_CONFIG": directory.appendingPathComponent("runtimes.json").path,
                "MICROPOD_DEFAULT_RUNTIME": name, "MICROPOD_HVF_ROOT": root.path,
                "MICROPOD_HVF_AUTOSTART": "0", "DOCKER_HOST": "unix:///nonexistent.sock",
                "MICROPOD_CI_HOME": "/nonexistent/micropod-ci",
            ],
            sandbox: SandboxEngine(root: directory.appendingPathComponent("sandbox")))
    }

    // MARK: The gate in front of the CLI

    func testADownRuntimeSpawnsNothingAndTheDefaultEngineStillLists() async throws {
        let cli = try stoppedCLI()
        let probe = ScriptedProbe(.down)
        let liveness = AppleRuntimeLiveness(probe: probe.answer)
        let client = ContainerCLIClient(executableURL: cli).gated(by: liveness)

        func refused(_ name: String, _ call: () async throws -> Void) async {
            do {
                try await call()
                XCTFail("\(name) of a down runtime must fail")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable", name)
            }
        }
        await refused("list") { _ = try await ContainerService(client: client).list() }
        await refused("images") { _ = try await ImageService(client: client).list() }
        await refused("volumes") { _ = try await VolumeService(client: client).list() }
        await refused("networks") { _ = try await NetworkService(client: client).list() }
        let status = try await SystemService(client: client).status()
        XCTAssertEqual(status.status, "stopped")

        try servingHVF(["c0ffee000001", "c0ffee000002"])
        let services = await RuntimeBackendResolver.resolveApple(
            client: client, environment: ["MICROPOD_RUNTIME": "cli"]
        ).routed(through: registry(default: "hvf"))
        let listed = try await services.containers.list()
        XCTAssertEqual(listed.map(\.id), ["c0ffee000001", "c0ffee000002"])
        XCTAssertEqual(Set(listed.map(\.runtime)), ["hvf"])
        let stats = try await services.stats.snapshot(ids: [])
        XCTAssertEqual(stats.containers, [])

        XCTAssertEqual(spawned, [], "no child while Apple's runtime is known to be down")
        XCTAssertEqual(probe.calls, 1, "one probe answers every call within its 2 s")
    }

    func testTheStateFlipsAfterItsTTLAndASystemStartForgetsItAtOnce() async throws {
        let cli = try stoppedCLI()
        let probe = ScriptedProbe(.down)
        let liveness = AppleRuntimeLiveness(maxAge: .milliseconds(200), probe: probe.answer)
        let client = ContainerCLIClient(executableURL: cli).gated(by: liveness)

        let first = await liveness.state()
        XCTAssertEqual(first, .down)
        probe.set(.up)
        let cached = await liveness.state()
        XCTAssertEqual(cached, .down, "fresh for 200 ms")
        try await Task.sleep(for: .milliseconds(250))
        let expired = await liveness.state()
        XCTAssertEqual(expired, .up, "an expired state waits for the probe")
        _ = try? await client.run(ContainerCommandFactory.listContainers())
        XCTAssertEqual(spawned.count, 1, "an up runtime spawns as before: \(spawned)")

        // A long TTL: only a start (or stop) through the client refreshes it.
        let slow = AppleRuntimeLiveness(maxAge: .seconds(60), probe: probe.answer)
        let slowClient = ContainerCLIClient(executableURL: cli).gated(by: slow)
        probe.set(.down)
        let down = await slow.state()
        XCTAssertEqual(down, .down)
        probe.set(.up)
        _ = try await slowClient.run(ContainerCommandFactory.systemStart())
        let started = await slow.state()
        XCTAssertEqual(started, .up, "system start forgets the down state")
    }

    /// The runtime came up outside the API: the native backend's own ping
    /// answered, while the gate still held a `down` under 2 s old. The
    /// commands behind that backend (the init image read for a create)
    /// must not be refused by it.
    func testAPingThatReachedTheApiserverOverridesAFreshDown() async throws {
        let cli = try stoppedCLI()
        let probe = ScriptedProbe(.down)
        let liveness = AppleRuntimeLiveness(maxAge: .seconds(60), probe: probe.answer)
        let client = ContainerCLIClient(executableURL: cli).gated(by: liveness)
        let down = await liveness.state()
        XCTAssertEqual(down, .down)
        do {
            _ = try await client.run(ContainerCommandFactory.listProperties())
            XCTFail("a down runtime refuses the property read")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable")
        }
        XCTAssertEqual(spawned, [])

        client.runtimeAnswered()
        XCTAssertEqual(liveness.knownState(), .up)
        let up = await liveness.state()
        XCTAssertEqual(up, .up)
        _ = try? await client.run(ContainerCommandFactory.listProperties())
        XCTAssertEqual(spawned.count, 1, "the read is attempted: \(spawned)")
        XCTAssertEqual(probe.calls, 1, "no probe was needed")
    }

    func testAnUnknownOrExpiredStateNeverRefuses() async throws {
        let probe = ScriptedProbe(.unknown)
        let liveness = AppleRuntimeLiveness(maxAge: .seconds(60), probe: probe.answer)
        let unknown = await liveness.runtimeIsDown()
        XCTAssertFalse(unknown, "a timeout is not proof the runtime is down")
        probe.set(.down)
        let never = AppleRuntimeLiveness(maxAge: .seconds(60), probe: probe.answer)
        XCTAssertFalse(never.runtimeIsKnownDown(), "nothing observed yet: a stream spawns as before")
        let observed = await never.runtimeIsDown()
        XCTAssertTrue(observed)
        XCTAssertTrue(never.runtimeIsKnownDown())
    }

    func testAnExplicitCLIPathBypassesTheGate() async throws {
        let cli = try stoppedCLI()
        let client = ContainerCLIClient(executableURL: cli)
            .gated(by: AppleRuntimeLiveness(probe: ScriptedProbe(.down).answer))
        setenv("MICROPOD_CONTAINER_CLI_PATH", cli.path, 1)
        defer { unsetenv("MICROPOD_CONTAINER_CLI_PATH") }
        _ = try? await client.run(ContainerCommandFactory.listContainers())
        XCTAssertEqual(spawned.count, 1, "mock-CLI tests and explicit installs keep spawning: \(spawned)")
    }

    /// The real probe: the Apple apiserver's mach service, or one that is
    /// never registered, answers within the ping's bound.
    func testThePingProbeClassifiesAnUnregisteredServiceAsDown() async {
        let clock = ContinuousClock()
        let started = clock.now
        let (state, health) = await AppleRuntimeLiveness.ping(service: "com.micropod.tests.never-registered")
        XCTAssertEqual(state, .down)
        XCTAssertNil(health)
        XCTAssertLessThan(clock.now - started, .milliseconds(500), "an unregistered service fails fast")
    }
}

/// A probe with a settable answer that counts its calls.
private final class ScriptedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AppleRuntimeLiveness.State
    private var count = 0

    init(_ state: AppleRuntimeLiveness.State) { self.state = state }

    var calls: Int { lock.withLock { count } }

    func set(_ state: AppleRuntimeLiveness.State) { lock.withLock { self.state = state } }

    var answer: @Sendable () async -> (AppleRuntimeLiveness.State, APIServerHealth?) {
        { [self] in
            lock.withLock {
                count += 1
                return (state, nil)
            }
        }
    }
}
