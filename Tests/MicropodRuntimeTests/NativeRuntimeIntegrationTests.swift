import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Live tests against a real `container-apiserver`. Gated behind
/// `MICROPOD_REAL_E2E=1` — same convention as RealRuntimeTests.
///
/// Run: MICROPOD_REAL_E2E=1 swift test --filter NativeRuntimeIntegrationTests
final class NativeRuntimeIntegrationTests: XCTestCase {
    private var api: APIServerClient!
    private var cli: ContainerCLIClient!
    private var service: NativeContainerService!
    private var createdIDs: [String] = []

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MICROPOD_REAL_E2E"] == "1",
            "set MICROPOD_REAL_E2E=1 to run live apiserver tests")
        guard FileManager.default.fileExists(atPath: "/usr/local/bin/container") else {
            throw XCTSkip("container CLI not installed")
        }
        api = APIServerClient()
        cli = ContainerCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/container"))
        service = NativeContainerService(api: api, cli: ContainerService(client: cli))
        // Runtime must be up or everything below times out.
        _ = try await api.ping(timeout: .seconds(15))
    }

    override func tearDown() async throws {
        for id in createdIDs {
            try? await service.delete(id, force: true)
        }
        createdIDs = []
    }

    // MARK: handshake

    func testPingReportsVersion() async throws {
        let health = try await api.ping()
        XCTAssertFalse(health.apiServerVersion.isEmpty)
        XCTAssertFalse(health.apiServerCommit.isEmpty)
        XCTAssertEqual(health.apiServerAppName, "container-apiserver")
    }

    // MARK: list parity

    func testListMatchesCLI() async throws {
        let nativeData = try await api.list()
        let native = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: nativeData, context: "native list")

        let cliOut = try await cli.run(
            ContainerCommandFactory.listContainers(all: true), timeout: .seconds(30))
        let cliList = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: Data(cliOut.utf8), context: "cli list")

        XCTAssertEqual(
            Set(native.map(\.id)), Set(cliList.map(\.id)),
            "native and CLI list must agree on container ids")
        for entry in native {
            let cliEntry = try XCTUnwrap(cliList.first { $0.id == entry.id })
            XCTAssertEqual(
                entry.status.state, cliEntry.status.state,
                "state mismatch for \(entry.id)")
        }
    }

    // MARK: exec lifecycle (the money path)

    func testExecExitCodeAndOutput() async throws {
        let id = try await createStarted()
        createdIDs.append(id)

        let ok = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/echo", "hi-there"]))
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertTrue(ok.output.contains("hi-there"))

        let fail = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/sh", "-c", "exit 42"]))
        XCTAssertEqual(fail.exitCode, 42, "native exec must return the real guest exit code")

        // exec() still throws on non-zero, matching CLI semantics.
        do {
            _ = try await service.exec(
                ContainerExecRequest(containerID: id, arguments: ["/bin/sh", "-c", "exit 7"]))
            XCTFail("exec should throw on non-zero exit")
        } catch MicropodError.cliFailure(_, let code, _) {
            XCTAssertEqual(code, 7)
        }
    }

    func testExecEnvAppend() async throws {
        let id = try await createStarted()
        createdIDs.append(id)
        let res = try await service.execDetailed(
            ContainerExecRequest(
                containerID: id, arguments: ["/usr/bin/env"], env: ["MICROPOD_T=1"]))
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.output.contains("MICROPOD_T=1"))
        // Image env must still be present (append, not replace).
        XCTAssertTrue(res.output.contains("PATH="))
    }

    // MARK: lifecycle + stats + logs

    func testStatsRoundTrip() async throws {
        let id = try await createStarted()
        createdIDs.append(id)
        let stats = try await api.stats(id: id)
        XCTAssertEqual(stats.id, id)
        XCTAssertNotNil(stats.memoryUsageBytes)
        XCTAssertGreaterThan(stats.numProcesses ?? 0, 0)
    }

    func testSamplerSnapshot() async throws {
        let id = try await createStarted()
        createdIDs.append(id)
        let sampler = NativeStatsSampler(api: api)
        let snap = try await sampler.snapshot()
        XCTAssertTrue(snap.containers.contains { $0.id == id })
    }

    func testNativeLogTail() async throws {
        let id = try await createStarted(command: ["/bin/sh", "-c", "echo marker-$RANDOM; sleep 60"])
        createdIDs.append(id)
        // Give vminitd a beat to write the log file.
        try await Task.sleep(for: .milliseconds(800))
        let streamer = NativeLogStreamer(api: api)
        let lines = try await streamer.tail(id: id, lines: 50)
        XCTAssertTrue(
            lines.contains { $0.text.contains("marker-") },
            "expected log output, got \(lines.map(\.text))")
    }

    func testStopStartKillDelete() async throws {
        let id = try await createStarted()
        createdIDs.append(id)
        try await service.stop(id, timeout: 5)
        try await service.start(id)
        try await service.kill(id, signal: "KILL")
        try await service.delete(id, force: true)
    }

    // MARK: vsock / vminitd

    func testVsockDialToVminitd() async throws {
        let id = try await createStarted()
        createdIDs.append(id)
        let handle = try await api.dial(id: id, port: GuestAgent.vminitdPort)
        handle.closeFile()
    }

    func testVminitdGetenv() async throws {
        let id = try await createStarted()
        createdIDs.append(id)
        let agent = GuestAgent(api: api, group: GuestAgent.sharedGroup)
        let conn = try await agent.vminitd(id: id)
        defer { Task { try? await conn.close() } }
        let value = try await conn.agent.getenv(key: "PATH")
        XCTAssertFalse(value.isEmpty, "vminitd getenv PATH should be set")
    }

    func testVminitdStatistics() async throws {
        let id = try await createStarted()
        createdIDs.append(id)
        let agent = GuestAgent(api: api, group: GuestAgent.sharedGroup)
        let stats = try await agent.statistics(id: id)
        let entry = try XCTUnwrap(stats.first)
        XCTAssertNotNil(entry.memory)
        XCTAssertNotNil(entry.cpu)
    }

    // MARK: helpers

    /// Native create + start (the path under test), sleeps forever.
    private func createStarted(
        command: [String] = ["/bin/sh", "-c", "sleep 60"]
    ) async throws -> String {
        // Pull lazily — alpine should already be cached from other suites.
        let image = "docker.io/library/alpine:latest"
        let request = ContainerRunRequest(
            image: image,
            name: "native-it-\(UUID().uuidString.prefix(8))",
            detach: true,
            arguments: command)
        let id = try await service.create(request)
        createdIDs.append(id)
        // start = bootstrap (VM boot + vminitd ready) + startProcess(init),
        // which is also what flips the apiserver status to `running`.
        try await service.start(id)
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
