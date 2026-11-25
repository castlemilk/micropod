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
            environment: [
                "MICROPOD_RUNTIMES_CONFIG": configURL.path, "DOCKER_HOST": "unix:///nonexistent.sock",
                // Never the developer's real machine or CI worker: an empty,
                // uninstalled hvf root and a CI home with no session.
                "MICROPOD_HVF_ROOT": "/nonexistent/micropod-hvf",
                "MICROPOD_CI_HOME": "/nonexistent/micropod-ci",
            ]
            .merging(extra) { _, new in new },
            sandbox: SandboxEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID())"))
        )
    }

    private func apple(
        _ containers: any ContainerServing = RecordingContainers(ids: ["web"]), stats: any StatsSampling = NoStats()
    ) -> AppleEngine {
        AppleEngine(
            services: RuntimeServices(
                kind: .cli, containers: containers, logs: NoLogs(), stats: stats,
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

    func testDedicatedRuntimeCannotEnableRoutingThroughAnEnginePreference() async {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = await RuntimeBackendResolver.resolve(
            client: client,
            environment: [
                "MICROPOD_RUNTIME": "cli", "MICROPOD_ISOLATED_RUNTIME": "1",
                "MICROPOD_ENGINES": "all", "MICROPOD_DEFAULT_RUNTIME": "docker",
            ])
        XCTAssertNil(services.router, "The fixed private Apple store must not consult another engine's endpoint")
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

    func testChangingDockerEndpointPreservesTheConfiguredAPIPin() throws {
        let reg = registry(["DOCKER_HOST": "unix:///private/tmp/original.sock", "DOCKER_API_VERSION": "1.44"])
        try reg.update("docker", enabled: true, endpoint: "unix:///private/tmp/alternate.sock")
        let changed = try XCTUnwrap((reg.engine("docker") as? DockerEngine)?.client)
        XCTAssertEqual(changed.apiVersion, "v1.44")
        try reg.update("docker", enabled: nil, endpoint: "")
        let original = try XCTUnwrap((reg.engine("docker") as? DockerEngine)?.client)
        XCTAssertEqual(original.endpoint, .unix("/private/tmp/original.sock"))
        XCTAssertEqual(original.apiVersion, "v1.44")
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
        XCTAssertEqual(response.runtimes.map(\.name), ["apple", "docker", "sandbox", "ci", "hvf"])
        XCTAssertEqual(response.default, "apple")
        let docker = response.runtimes[1]
        XCTAssertFalse(docker.available)
        XCTAssertEqual(docker.reason, "Docker socket not found")
        XCTAssertTrue(response.runtimes[0].capabilities.contains("volumes"))
        XCTAssertFalse(response.runtimes[2].capabilities.contains("ports"))
        let hvf = response.runtimes[4]
        XCTAssertEqual(hvf.name, "hvf")
        XCTAssertEqual(hvf.kind, "microvm")
        XCTAssertEqual(hvf.capabilities, HVFEngine.supportedCapabilities)
        XCTAssertFalse(hvf.capabilities.contains("copy"), "the guest engine has no archive API")
        XCTAssertFalse(hvf.capabilities.contains("export"))
        XCTAssertFalse(hvf.available, "nothing installed under the test root")
        XCTAssertTrue(hvf.reason.contains("not installed"), hvf.reason)
        XCTAssertEqual(hvf.endpoint, "unix:///nonexistent/micropod-hvf/run/docker.sock")
        XCTAssertFalse(hvf.enabled, "hvf is opt-in like docker")
    }

    func testStoppedAppleRuntimeIsBestEffortOnlyWhenAnotherEngineIsDefault() async throws {
        let failing = apple(FailingContainers())
        do {
            _ = try await RuntimeRouter(apple: failing, registry: registry()).list()
            XCTFail("apple is the default: its failure is the listing's failure")
        } catch {}
        let router = RuntimeRouter(apple: failing, registry: registry(["MICROPOD_DEFAULT_RUNTIME": "sandbox"]))
        let listed = try await router.list()
        XCTAssertEqual(listed, [], "the default engine's (empty) listing survives a stopped Apple runtime")
    }

    /// Only "the Apple runtime is down" is tolerated when Apple is not the
    /// default; every other Apple failure is still the caller's answer.
    private static let runtimeDown: [(String, any Error)] = [
        ("runtimeNotRunning", MicropodError.runtimeNotRunning),
        ("transport", MicropodError.transport("com.apple.container.apiserver: connection invalidated")),
        ("cliUnavailable", MicropodError.cliUnavailable("/usr/local/bin/container")),
        (
            "cli runtime-down output",
            MicropodError.cliFailure(
                command: "container list", exitCode: 1,
                stderr: "Error: apiserver is not running and not registered with launchd")
        ),
    ]
    private static let realFailures: [(String, any Error)] = [
        ("internal", MicropodError.message("internal: decode failed")),
        ("timeout", MicropodError.cliTimeout(command: "container list")),
        ("cli failure", MicropodError.cliFailure(command: "container list", exitCode: 1, stderr: "Error: boom")),
        ("decode", MicropodError.decode("bad json")),
        ("cancellation", CancellationError()),
    ]

    func testANonDefaultAppleRuntimeToleratesOnlyBeingDown() async throws {
        let others = registry(["MICROPOD_DEFAULT_RUNTIME": "sandbox"])
        for (name, error) in Self.runtimeDown {
            let router = RuntimeRouter(
                apple: apple(FailingContainers(error: error), stats: FailingStats(error)), registry: others)
            let listed = try await router.list()
            XCTAssertEqual(listed, [], name)
            let stats = try await router.snapshot(ids: [])
            XCTAssertEqual(stats.containers, [], name)
            XCTAssertFalse(stats.sampledAt.isEmpty, name)
        }
        for (name, error) in Self.realFailures {
            let router = RuntimeRouter(
                apple: apple(FailingContainers(error: error), stats: FailingStats(error)), registry: others)
            do {
                _ = try await router.list()
                XCTFail("list swallowed \(name)")
            } catch {}
            do {
                _ = try await router.snapshot(ids: [])
                XCTFail("snapshot swallowed \(name)")
            } catch {}
        }
    }

    func testAnAppleDefaultSurfacesEveryAppleFailureAsBefore() async throws {
        for (name, error) in Self.runtimeDown + Self.realFailures {
            let router = RuntimeRouter(
                apple: apple(FailingContainers(error: error), stats: FailingStats(error)), registry: registry())
            do {
                _ = try await router.list()
                XCTFail("list swallowed \(name)")
            } catch {}
            do {
                _ = try await router.snapshot(ids: [])
                XCTFail("snapshot swallowed \(name)")
            } catch {}
        }
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

    func testInitImageNeedsTheAppleEngine() async throws {
        let containers = RecordingContainers(ids: [])
        let router = RuntimeRouter(apple: apple(containers), registry: registry())
        let steward = "registry.example.com/vminit:0.47.0-steward.3"
        _ = try await router.run(ContainerRunRequest(image: "alpine", initImage: steward))
        let ran = await containers.ran
        XCTAssertEqual(ran, ["alpine"], "unset runtime → apple, which decides the override itself")
        for runtime in ["sandbox", "docker"] {
            do {
                _ = try await router.create(ContainerRunRequest(image: "alpine", runtime: runtime, initImage: steward))
                XCTFail("init_image on \(runtime) must be refused")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "unimplemented", "\(runtime): \(error)")
                XCTAssertTrue(error.localizedDescription.contains("init_image"), "\(error)")
            }
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

        request.publishedPorts = [
            PortSpec(hostPort: 8080, containerPort: 80),
            PortSpec(hostPort: 8443, containerPort: 443, hostIP: "127.0.0.1"),
        ]
        XCTAssertEqual(
            try SandboxEngine.options(from: request).ports,
            [
                PortForward(hostIP: "0.0.0.0", hostPort: 8080, guestPort: 80),
                PortForward(hostPort: 8443, guestPort: 443),
            ],
            "no address is every interface, as with apple and docker")
        request.publishedPorts = [PortSpec(hostPort: 53, containerPort: 53, transportProtocol: "udp")]
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
        for (url, host) in [("tcp://[::1]:2375", "::1"), ("tcp://[fe80::1%25lo0]:2375", "fe80::1%lo0")] {
            let endpoint = try DockerClient.Endpoint.parse(url)
            XCTAssertEqual(endpoint, .tcp(host: host, port: 2375))
            XCTAssertEqual(endpoint.description, url)
        }
        XCTAssertThrowsError(try DockerClient.Endpoint.parse("tcp://::1:2375"))
        XCTAssertThrowsError(try DockerClient.Endpoint.parse("tcp://host:65536"))
        XCTAssertThrowsError(try DockerClient.Endpoint.parse("tcp://[name]:2375"))
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

/// An Apple runtime whose every call fails (by default: it is not running).
struct FailingContainers: ContainerServing {
    var error: any Error = MicropodError.runtimeNotRunning
    private var down: any Error { error }
    func list() async throws -> [Micropod_V1_Container] { throw down }
    func inspect(_ id: String) async throws -> Data { throw down }
    func create(_ request: ContainerRunRequest) async throws -> String { throw down }
    func run(_ request: ContainerRunRequest) async throws -> String { throw down }
    func exec(_ request: ContainerExecRequest) async throws -> String { throw down }
    func start(_ id: String) async throws { throw down }
    func stop(_ id: String, timeout: Int) async throws { throw down }
    func restart(_ id: String) async throws { throw down }
    func stopAll() async throws { throw down }
    func kill(_ id: String, signal: String) async throws { throw down }
    func delete(_ id: String, force: Bool) async throws { throw down }
    func deleteAll(force: Bool) async throws { throw down }
    func prune() async throws -> String { throw down }
    func export(_ id: String, to outputPath: String) async throws { throw down }
    func copy(from: String, to: String) async throws { throw down }
}

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

struct FailingStats: StatsSampling {
    let error: any Error
    init(_ error: any Error) { self.error = error }
    func snapshot() async throws -> Micropod_V1_StatsSnapshot { throw error }
    func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot { throw error }
}
