import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Engine routing, configuration and the Docker wire helpers — no VM, no
/// Docker daemon. Live coverage: `RealEngineTests` (MICROPOD_REAL_E2E=1).
final class RuntimeEngineTests: XCTestCase {
    private var configURL: URL!

    override func setUp() {
        configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtimes-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
    }

    private func registry(_ extra: [String: String] = [:]) -> EngineRegistry {
        EngineRegistry(
            environment: ["MICROPOD_RUNTIMES_CONFIG": configURL.path, "DOCKER_HOST": "unix:///nonexistent.sock"]
                .merging(extra) { _, new in new },
            sandbox: SandboxEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID())"))
        )
    }

    private func apple(_ containers: RecordingContainers = RecordingContainers(ids: ["web"])) -> AppleEngine {
        AppleEngine(
            services: RuntimeServices(
                kind: .cli, containers: containers, logs: NoLogs(), stats: NoStats(),
                volumes: VolumeService(
                    client: ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
                api: nil, health: nil, exitCodes: nil))
    }

    // MARK: Config

    func testDefaultsAppleWithDockerOptIn() {
        let reg = registry()
        XCTAssertEqual(reg.defaultName, "apple")
        XCTAssertTrue(reg.isEnabled("apple"))
        XCTAssertTrue(reg.isEnabled("sandbox"))
        XCTAssertFalse(reg.isEnabled("docker"), "docker must be opt-in")
    }

    func testEnvironmentDefaultWins() {
        XCTAssertEqual(registry(["MICROPOD_DEFAULT_RUNTIME": "sandbox"]).defaultName, "sandbox")
    }

    func testUpdatePersistsAndReloads() throws {
        try registry().update("docker", enabled: true, endpoint: "tcp://10.0.0.5:2375")
        let reloaded = registry()
        XCTAssertTrue(reloaded.isEnabled("docker"))
        XCTAssertEqual(reloaded.config.engines["docker"]?.endpoint, "tcp://10.0.0.5:2375")
        XCTAssertEqual(
            (reloaded.engine("docker") as? DockerEngine)?.client?.endpoint, .tcp(host: "10.0.0.5", port: 2375))

        try reloaded.update("docker", enabled: nil, endpoint: "")
        XCTAssertNil(registry().config.engines["docker"]?.endpoint, "empty endpoint restores the default")
    }

    func testUpdateValidation() {
        let reg = registry()
        XCTAssertThrowsError(try reg.update("apple", enabled: false, endpoint: nil)) {
            XCTAssertEqual(ConnectCodeMapping.code(for: $0), "failed_precondition", "default can't be disabled")
        }
        XCTAssertThrowsError(try reg.update("nope", enabled: true, endpoint: nil))
        XCTAssertThrowsError(try reg.update("sandbox", enabled: nil, endpoint: "unix:///x.sock")) {
            XCTAssertEqual(ConnectCodeMapping.code(for: $0), "invalid_argument")
        }
        XCTAssertThrowsError(try reg.update("docker", enabled: nil, endpoint: "http://x"))
        XCTAssertThrowsError(
            try reg.update(
                "docker", enabled: nil, endpoint: "unix://" + NSString("~/.micropod/docker.sock").expandingTildeInPath),
            "micropod's own shim would loop")
    }

    func testSetDefaultRefusesUnavailable() async {
        let reg = registry()
        do {
            try await reg.setDefault("docker", apple: apple())
            XCTFail("docker socket is missing — must refuse")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
        }
        XCTAssertEqual(reg.defaultName, "apple")
    }

    func testDescribeReportsEveryEngine() async {
        let response = await registry().describe(apple: apple())
        XCTAssertEqual(response.runtimes.map(\.name), ["apple", "docker", "sandbox"])
        XCTAssertEqual(response.default, "apple")
        let docker = response.runtimes[1]
        XCTAssertFalse(docker.available)
        XCTAssertEqual(docker.reason, "Docker socket not found")
        XCTAssertTrue(response.runtimes[0].capabilities.contains("volumes"))
        XCTAssertFalse(response.runtimes[2].capabilities.contains("ports"))
    }

    // MARK: Routing

    func testRunTargetsRequestedOrDefaultEngine() async throws {
        let containers = RecordingContainers(ids: [])
        let router = RuntimeRouter(apple: apple(containers), registry: registry())
        _ = try await router.run(ContainerRunRequest(image: "alpine"))
        let ran = await containers.ran
        XCTAssertEqual(ran, ["alpine"], "unset runtime → default (apple)")

        do {
            _ = try await router.run(ContainerRunRequest(image: "alpine", runtime: "docker"))
            XCTFail("docker disabled")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
            XCTAssertTrue(error.localizedDescription.contains("disabled"))
        }
        do {
            _ = try await router.run(ContainerRunRequest(image: "alpine", runtime: "firecracker"))
            XCTFail("unknown engine")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
        }
    }

    func testIdCallsFallBackToApple() async throws {
        let containers = RecordingContainers(ids: ["web"])
        let router = RuntimeRouter(apple: apple(containers), registry: registry())
        try await router.stop("web", timeout: 1)
        let result = try await router.execDetailed(ContainerExecRequest(containerID: "web", arguments: ["x"]))
        let stopped = await containers.stopped
        XCTAssertEqual(stopped, ["web"])
        XCTAssertEqual(result.output, "detailed", "execDetailed must reach the engine's own implementation")
    }

    func testListStampsRuntime() async throws {
        let router = RuntimeRouter(apple: apple(), registry: registry())
        let list = try await router.list()
        XCTAssertEqual(list.map(\.id), ["web"])
        XCTAssertEqual(list.map(\.runtime), ["apple"])
    }

    func testRoutedIsIdempotent() {
        let services = apple().services.routed(through: registry())
        XCTAssertNotNil(services.router)
        XCTAssertTrue(services.routed(through: registry()).router?.apple.services.router == nil)
    }

    // MARK: Sandbox request mapping

    func testSandboxOptionsMapping() throws {
        var request = ContainerRunRequest(
            image: "golang:1", cpus: 1.5, memory: "1g", env: ["A=1"], volumes: ["/tmp:/src:ro"],
            labels: [LabelSpec(key: SandboxEngine.networkLabel, value: "none")], workdir: "/src",
            entrypoint: "/bin/sh", arguments: ["-c", "go test"])
        let options = try SandboxEngine.options(from: request)
        XCTAssertEqual(options.cpus, 2)
        XCTAssertEqual(options.memoryMiB, 1024)
        XCTAssertEqual(options.mounts, ["/tmp:/src:ro"])
        XCTAssertEqual(options.entrypoint, ["/bin/sh"])
        XCTAssertFalse(options.network)

        request.labels = []
        XCTAssertTrue(try SandboxEngine.options(from: request).network, "API containers are online by default")

        request.publishedPorts = [PortSpec(hostPort: 80, containerPort: 80)]
        XCTAssertThrowsError(try SandboxEngine.options(from: request)) {
            XCTAssertEqual(ConnectCodeMapping.code(for: $0), "unimplemented")
        }
        request.publishedPorts = []
        request.volumes = ["data:/data"]
        XCTAssertThrowsError(try SandboxEngine.options(from: request), "named volumes are unsupported")
    }

    // MARK: Docker wire helpers

    func testEndpointParsing() throws {
        XCTAssertEqual(try DockerClient.Endpoint.parse("unix:///var/run/docker.sock"), .unix("/var/run/docker.sock"))
        XCTAssertEqual(try DockerClient.Endpoint.parse("/tmp/d.sock"), .unix("/tmp/d.sock"))
        XCTAssertEqual(try DockerClient.Endpoint.parse("tcp://127.0.0.1:2375"), .tcp(host: "127.0.0.1", port: 2375))
        XCTAssertThrowsError(try DockerClient.Endpoint.parse("tcp://nohost"))
        XCTAssertThrowsError(try DockerClient.Endpoint.parse("ssh://box"))
    }

    func testDemuxSplitsStreams() {
        var framed = Data([1, 0, 0, 0, 0, 0, 0, 3]) + Data("out".utf8)
        framed += Data([2, 0, 0, 0, 0, 0, 0, 3]) + Data("err".utf8)
        let (out, err) = DockerClient.demux(framed)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: err, as: UTF8.self), "err")
        XCTAssertEqual(DockerClient.demux(Data("plain tty\n".utf8)).stdout, Data("plain tty\n".utf8))
    }

    func testLogSplitterHandlesStraddledFrames() {
        let payload = Data("line one\nline two\npartial".utf8)
        let frame = Data([1, 0, 0, 0, 0, 0, 0, UInt8(payload.count)]) + payload
        var splitter = LogFrameSplitter()
        var lines: [String] = []
        for byte in frame { lines += splitter.feed(Data([byte])) }
        lines += splitter.flush()
        XCTAssertEqual(lines, ["line one", "line two", "partial"])
    }

    func testCreateBodyMapping() throws {
        let body = try DockerEngine.createBody(
            ContainerRunRequest(
                image: "nginx", cpus: 0.5, memory: "512m", env: ["A=1"],
                publishedPorts: [PortSpec(hostPort: 8080, containerPort: 80)], volumes: ["/h:/c"],
                labels: [LabelSpec(key: "k", value: "v")], useInit: true, capAdd: ["CAP_NET_ADMIN"],
                entrypoint: "/bin/sh", arguments: ["-c", "true"], privileged: true))
        let host = try XCTUnwrap(body["HostConfig"] as? [String: Any])
        XCTAssertEqual(body["Entrypoint"] as? [String], ["/bin/sh"])
        XCTAssertEqual(body["Cmd"] as? [String], ["-c", "true"])
        XCTAssertEqual(host["NanoCpus"] as? Int, 500_000_000)
        XCTAssertEqual(host["Memory"] as? Int, 512 << 20)
        XCTAssertEqual(host["Binds"] as? [String], ["/h:/c"])
        XCTAssertEqual(host["Privileged"] as? Bool, true)
        let bindings = try XCTUnwrap(host["PortBindings"] as? [String: [[String: String]]])
        XCTAssertEqual(bindings["80/tcp"]?.first?["HostPort"], "8080")
        XCTAssertThrowsError(try DockerEngine.parseBytes("lots"))
        XCTAssertEqual(try DockerEngine.parseBytes("2g"), 2 << 30)
    }

    func testDockerStatusMapsToConnectCodes() {
        XCTAssertEqual(ConnectCodeMapping.code(for: DockerClient.error(status: 404, "x")), "not_found")
        XCTAssertEqual(ConnectCodeMapping.code(for: DockerClient.error(status: 409, "x")), "already_exists")
        XCTAssertEqual(ConnectCodeMapping.code(for: DockerClient.error(status: 400, "x")), "invalid_argument")
        XCTAssertEqual(ConnectCodeMapping.code(for: DockerClient.error(status: 500, "x")), "internal")
    }
}

// MARK: - Fakes

actor RecordingContainers: ContainerServing {
    let ids: [String]
    var ran: [String] = []
    var stopped: [String] = []

    init(ids: [String]) { self.ids = ids }

    func list() async throws -> [Micropod_V1_Container] {
        ids.map { id in Micropod_V1_Container.with { $0.id = id } }
    }
    func inspect(_ id: String) async throws -> Data { Data() }
    func create(_ request: ContainerRunRequest) async throws -> String { request.image }
    func run(_ request: ContainerRunRequest) async throws -> String {
        ran.append(request.image)
        return request.image
    }
    func exec(_ request: ContainerExecRequest) async throws -> String { "plain" }
    func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        ContainerExecResult(output: "detailed", error: "", exitCode: 3)
    }
    func start(_ id: String) async throws {}
    func stop(_ id: String, timeout: Int) async throws { stopped.append(id) }
    func restart(_ id: String) async throws {}
    func stopAll() async throws {}
    func kill(_ id: String, signal: String) async throws {}
    func delete(_ id: String, force: Bool) async throws {}
    func deleteAll(force: Bool) async throws {}
    func prune() async throws -> String { "" }
    func export(_ id: String, to outputPath: String) async throws {}
    func copy(from: String, to: String) async throws {}
}

struct NoLogs: LogStreaming {
    func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine] { [] }
}

struct NoStats: StatsSampling {
    func snapshot() async throws -> Micropod_V1_StatsSnapshot { .init() }
    func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot { .init() }
}
