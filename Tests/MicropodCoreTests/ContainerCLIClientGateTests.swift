import Foundation
import XCTest

@testable import MicropodCore

/// A gated `container` client asks its `ContainerRuntimeGate` before each
/// command that needs the apiserver and, when the runtime is known to be
/// down, refuses without spawning: the API whose default runtime is hvf used
/// to start a `container` child (and a `launchctl` grandchild) on every
/// listing, inspect, wait and status read only to learn Apple's runtime was
/// down (B25 L-CENSUS, T-CENSUS, M-CENSUS-API).
final class ContainerCLIClientGateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-cli-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The checked-in mock CLI in its stopped mode (apiserver unregistered),
    /// behind a wrapper named `container` so the gate applies; every
    /// invocation is appended to `calls.log`.
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

    /// Each spawned command line, as the mock logged it.
    private var spawned: [String] {
        let log = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private func client(_ cli: URL, gate: StubGate) -> ContainerCLIClient {
        ContainerCLIClient(
            executableURL: cli, admission: RuntimeAdmission(root: directory.appendingPathComponent("adm"))
        )
        .gated(by: gate)
    }

    func testAGatedRefusalSpawnsNothingAndIsUnavailable() async throws {
        let cli = try stoppedCLI()
        let gate = StubGate(down: true)
        let gated = client(cli, gate: gate)
        do {
            _ = try await gated.run(ContainerCommandFactory.listContainers())
            XCTFail("a known-down runtime must refuse")
        } catch {
            XCTAssertEqual(error as? MicropodError, .runtimeNotRunning)
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable", "RuntimeRouter tolerates exactly this")
        }
        var streamed = 0
        do {
            for try await _ in gated.stream(ContainerCommandFactory.logs("web", follow: true)) { streamed += 1 }
            XCTFail("a known-down runtime must refuse a stream too")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable")
        }
        XCTAssertEqual(streamed, 0)
        XCTAssertEqual(spawned, [], "nothing ran")
    }

    func testAnUngatedOrUpClientSpawnsAsBefore() async throws {
        let cli = try stoppedCLI()
        let ungated = ContainerCLIClient(executableURL: cli)
        do {
            _ = try await ungated.run(ContainerCommandFactory.listContainers())
            XCTFail("the stopped mock fails the listing")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable")
        }
        _ = try? await client(cli, gate: StubGate(down: false)).run(ContainerCommandFactory.listContainers())
        XCTAssertEqual(spawned.count, 2, "\(spawned)")
    }

    func testSystemStartIsNeverGatedAndMakesTheGateForget() async throws {
        let cli = try stoppedCLI()
        let gate = StubGate(down: true)
        _ = try await client(cli, gate: gate).run(ContainerCommandFactory.systemStart())
        XCTAssertEqual(spawned.count, 1, "system start runs while the runtime is down: \(spawned)")
        XCTAssertTrue(spawned[0].hasPrefix("system start"), spawned[0])
        XCTAssertEqual(gate.forgotten, 1, "after a start the gate must observe again")
        XCTAssertEqual(gate.asked, 0, "system start never asks")
    }

    func testOnlyApiserverCommandsAreGated() {
        for command in [
            ContainerCommandFactory.listContainers(), ContainerCommandFactory.systemStatus(),
            ContainerCommandFactory.systemDF(), ContainerCommandFactory.listProperties(),
            ContainerCommandFactory.listImages(), ContainerCommandFactory.listVolumes(),
            ContainerCommandFactory.listNetworks(), ContainerCommandFactory.listMachines(),
            ContainerCommandFactory.statsSnapshot(), ContainerCommandFactory.inspectContainers(["web"]),
        ] {
            XCTAssertTrue(command.needsAPIServer, command.displayName)
        }
        for command in [
            ContainerCommandFactory.systemStart(), ContainerCommandFactory.systemStop(),
            ContainerCommandFactory.systemVersion(), ContainerCommandFactory.systemKernelSetRecommended(),
            ContainerCommandFactory.registryList(), ContainerCommand(arguments: ["--version"]),
        ] {
            XCTAssertFalse(command.needsAPIServer, command.displayName)
        }
        XCTAssertTrue(ContainerCommandFactory.systemStart().changesRuntimeLifecycle)
        XCTAssertTrue(ContainerCommandFactory.systemStop().changesRuntimeLifecycle)
        XCTAssertFalse(ContainerCommandFactory.systemStatus().changesRuntimeLifecycle)
    }

    func testOtherExecutablesAndAnExplicitCLIPathAreNeverGated() async throws {
        let gate = StubGate(down: true)
        let shell = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/echo")).gated(by: gate)
        let echoed = try await shell.run(ContainerCommand(arguments: ["list"]))
        XCTAssertEqual(echoed, "list\n", "only `container` is gated")

        XCTAssertTrue(ContainerCLIClient.gateBypassed(["MICROPOD_CONTAINER_CLI_PATH": "/opt/mock/container"]))
        XCTAssertFalse(ContainerCLIClient.gateBypassed([:]))
        let cli = try stoppedCLI()
        setenv("MICROPOD_CONTAINER_CLI_PATH", cli.path, 1)
        defer { unsetenv("MICROPOD_CONTAINER_CLI_PATH") }
        _ = try? await client(cli, gate: gate).run(ContainerCommandFactory.listContainers())
        XCTAssertEqual(spawned.count, 1, "an explicit CLI keeps spawning: \(spawned)")
        XCTAssertEqual(gate.asked, 0)
    }

    /// `usesIsolatedTransport` read the root-owned identity (and decoded the
    /// selection) on every check; Ping asked it four times per call, the
    /// largest cost left once the host components were kept. A CLI outside
    /// the isolated runtime's root is now decided without reading anything.
    func testOnlyAnExecutableUnderTheIsolatedRootReadsTheIdentity() {
        let reads = LockedCount()
        let identity = IsolatedRuntimeIdentity(
            instance: UUID(), ownerUID: getuid(), serviceUID: 401, serviceGID: 401, accountGUID: UUID(),
            groupGUID: UUID())
        func decide(_ path: String, isolated: String? = nil) -> Bool {
            ContainerCLIClient.usesIsolatedTransport(
                executable: URL(fileURLWithPath: path),
                identity: {
                    reads.add()
                    return identity
                }, isolatedExecutable: { isolated.map { URL(fileURLWithPath: $0) } })
        }
        let root = IsolatedRuntimePolicy.root.path
        for outside in ["/usr/local/bin/container", "/opt/homebrew/bin/container", root + "-other/bin/container"] {
            XCTAssertFalse(decide(outside), outside)
        }
        XCTAssertEqual(reads.value, 0, "no identity read for a CLI outside \(root)")

        XCTAssertTrue(decide(root + "/apple/versions/1.5.0-abc/bin/container"))
        XCTAssertTrue(decide(root + "/staged/bin/container", isolated: root + "/staged/bin/container"))
        XCTAssertFalse(decide(root + "/invalid-selection/bin/container"))
        XCTAssertEqual(reads.value, 3)
        XCTAssertFalse(
            ContainerCLIClient.usesIsolatedTransport(
                executable: URL(fileURLWithPath: root + "/apple/versions/x/bin/container"), identity: { nil },
                isolatedExecutable: { nil }), "no identity: never isolated")
    }

    func testStatusOfAKnownDownRuntimeIsStoppedWithoutAStatusChild() async throws {
        let cli = try stoppedCLI()
        let status = try await SystemService(client: client(cli, gate: StubGate(down: true))).status()
        XCTAssertEqual(status.status, "stopped", "the gate's refusal is the CLI's `unregistered`")
        XCTAssertFalse(status.cliVersion.isEmpty, "the CLI's own version still answers")
        XCTAssertEqual(
            spawned.filter { !$0.hasPrefix("system version") }, [], "only the (cached) version read may spawn")
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A gate with a fixed answer that counts what it was asked.
private final class StubGate: ContainerRuntimeGate, @unchecked Sendable {
    private let lock = NSLock()
    private let down: Bool
    private var askedCount = 0
    private var forgottenCount = 0

    init(down: Bool) { self.down = down }

    var asked: Int { lock.withLock { askedCount } }
    var forgotten: Int { lock.withLock { forgottenCount } }

    func runtimeIsDown() async -> Bool { runtimeIsKnownDown() }

    func runtimeIsKnownDown() -> Bool {
        lock.withLock {
            askedCount += 1
            return down
        }
    }

    func runtimeMayHaveChanged() { lock.withLock { forgottenCount += 1 } }
}
