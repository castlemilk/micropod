import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// D11/D12: a fresh install (runtimes.json pinned `fresh-install`) makes hvf
/// the default and the Apple runtime opt-in; an existing install, or a file
/// with no origin, keeps everything as before. Temp configuration only: an
/// uninstalled hvf root and no Apple apiserver are ever reached.
final class FreshInstallDefaultsTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL { directory.appendingPathComponent("runtimes.json") }
    private var root: URL { directory.appendingPathComponent("hvf") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mpfi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ origin: InstallOrigin) throws {
        try InstallOrigin.pinData(origin).write(to: configURL)
    }

    private func environment(_ extra: [String: String] = [:]) -> [String: String] {
        [
            "MICROPOD_RUNTIMES_CONFIG": configURL.path, "DOCKER_HOST": "unix:///nonexistent.sock",
            "MICROPOD_HVF_ROOT": root.path, "MICROPOD_CI_HOME": "/nonexistent/micropod-ci",
            "MICROPOD_DOCKER_SOCK": directory.appendingPathComponent("canonical.sock").path,
        ].merging(extra) { _, new in new }
    }

    private func registry(_ extra: [String: String] = [:]) -> EngineRegistry {
        EngineRegistry(
            environment: environment(extra),
            sandbox: SandboxEngine(root: directory.appendingPathComponent("sbx")))
    }

    private func apple(_ containers: any ContainerServing = RecordingContainers(ids: [])) -> AppleEngine {
        AppleEngine(
            services: RuntimeServices(
                kind: .cli, containers: containers, logs: NoLogs(), stats: NoStats(),
                volumes: VolumeService(
                    client: ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
                api: nil, health: nil, exitCodes: nil),
            cliInstalled: { true })
    }

    // MARK: Registry

    func testAFreshInstallDefaultsToHvfWithAppleOptIn() throws {
        try write(.fresh)
        let reg = registry()
        XCTAssertEqual(reg.origin, .fresh)
        XCTAssertEqual(reg.defaultName, "hvf")
        XCTAssertFalse(reg.isEnabled("apple"), "Apple is opt-in on a fresh install")
        XCTAssertTrue(reg.isEnabled("hvf"), "the default is always enabled")
        XCTAssertTrue(reg.isEnabled("sandbox"))
        XCTAssertFalse(reg.isEnabled("docker"))
        XCTAssertTrue(reg.skipsApple(installed: true), "a merged listing never asks Apple")
        XCTAssertFalse(EngineRegistry.appleEnabled(environment: environment()))
    }

    func testAnExistingInstallKeepsAppleAsBefore() throws {
        try write(.existing)
        let reg = registry()
        XCTAssertEqual(reg.origin, .existing)
        XCTAssertEqual(reg.defaultName, "apple")
        XCTAssertTrue(reg.isEnabled("apple"))
        XCTAssertTrue(EngineRegistry.appleEnabled(environment: environment()))
        // A file from before the pin, and no file at all, are the same.
        try Data(#"{"engines": {}}"#.utf8).write(to: configURL)
        XCTAssertEqual(registry().defaultName, "apple")
        XCTAssertTrue(registry().isEnabled("apple"))
        try FileManager.default.removeItem(at: configURL)
        XCTAssertEqual(registry().defaultName, "apple")
        XCTAssertTrue(registry().isEnabled("apple"))
    }

    func testAppleIsEnabledByTheCommandsAndTheLegacyVariable() async throws {
        try write(.fresh)
        let reg = registry()
        try reg.update("apple", enabled: true, endpoint: nil)
        XCTAssertTrue(reg.isEnabled("apple"))
        let saved = try JSONDecoder().decode(EngineConfig.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(saved.defaultOrigin, "fresh-install", "a later save keeps the pin")
        XCTAssertEqual(saved.default, "hvf")
        XCTAssertTrue(registry().isEnabled("apple"), "persisted")
        try reg.update("apple", enabled: false, endpoint: nil)
        XCTAssertFalse(registry().isEnabled("apple"))

        // `runtime use apple`: the default is always enabled.
        try await reg.setDefault("apple", apple: apple())
        XCTAssertEqual(registry().defaultName, "apple")
        XCTAssertTrue(registry().isEnabled("apple"))

        try write(.fresh)
        XCTAssertTrue(registry(["MICROPOD_LEGACY_APPLE": "1"]).isEnabled("apple"))
        XCTAssertTrue(EngineRegistry.appleEnabled(environment: environment(["MICROPOD_LEGACY_APPLE": "1"])))
        XCTAssertEqual(registry(["MICROPOD_LEGACY_APPLE": "1"]).defaultName, "hvf", "enabled, not the default")
    }

    func testTheEnvironmentDefaultStillWins() throws {
        try write(.fresh)
        let reg = registry(["MICROPOD_DEFAULT_RUNTIME": "apple"])
        XCTAssertEqual(reg.defaultName, "apple")
        XCTAssertTrue(reg.isEnabled("apple"))
        XCTAssertEqual(registry(["MICROPOD_DEFAULT_RUNTIME": "sandbox"]).defaultName, "sandbox")
    }

    func testAPartialFileDecodesInsteadOfFallingBackToEmpty() throws {
        try Data(#"{"default": "sandbox"}"#.utf8).write(to: configURL)
        XCTAssertEqual(registry().defaultName, "sandbox", "a file without `engines` is still read")
    }

    // MARK: Routing

    func testAFreshInstallRefusesAppleCallsAndNamesTheOptIn() async throws {
        try write(.fresh)
        let containers = RecordingContainers(ids: [])
        let router = RuntimeRouter(apple: apple(containers), registry: registry())
        do {
            _ = try await router.run(ContainerRunRequest(image: "alpine", runtime: "apple"))
            XCTFail("Apple is opt-in")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
            XCTAssertTrue(error.localizedDescription.contains("micropod runtime enable apple"), "\(error)")
        }
        let ran = await containers.ran
        XCTAssertEqual(ran, [], "nothing reached the Apple runtime")
    }

    func testRunWithNoMachineSaysToRunSetup() async throws {
        try write(.fresh)
        let router = RuntimeRouter(apple: apple(), registry: registry())
        do {
            _ = try await router.run(ContainerRunRequest(image: "alpine"))
            XCTFail("no machine")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "failed_precondition")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("the micropod machine is not set up"), message)
            XCTAssertTrue(message.contains("run `micropod setup`"), message)
        }
        // An existing install that asks for hvf by name hears the same.
        try write(.existing)
        do {
            _ = try await RuntimeRouter(apple: apple(), registry: registry())
                .run(ContainerRunRequest(image: "alpine", runtime: "hvf"))
            XCTFail("no machine")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("micropod setup"), "\(error)")
        }
    }

    func testFreshListingsAndBulkCallsSkipApple() async throws {
        try write(.fresh)
        let containers = CallLog()
        let router = RuntimeRouter(apple: apple(containers), registry: registry())
        let listed = try await router.list()
        XCTAssertFalse(listed.contains { $0.runtime == "apple" })
        try await router.stopAll()
        try await router.deleteAll(force: true)
        _ = try await router.prune()
        let calls = await containers.calls
        XCTAssertEqual(calls, [], "Apple was never asked")
    }

    func testAnIdNoEngineOwnsIsNotFoundInsteadOfAskingApple() async throws {
        try write(.fresh)
        let containers = CallLog()
        let router = RuntimeRouter(apple: apple(containers), registry: registry())
        do {
            try await router.delete("ghost", force: true)
            XCTFail("no engine owns it")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found", "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("no such container 'ghost'"), "\(error)")
        }
        let calls = await containers.calls
        XCTAssertEqual(calls, [], "the Apple runtime was not asked")
        // An existing install falls back to Apple as before.
        try write(.existing)
        let existing = RuntimeRouter(apple: apple(containers), registry: registry())
        let owner = await existing.owner("ghost")
        XCTAssertEqual(owner.name, "apple")
    }

    // MARK: Docker endpoint

    func testADockerEndpointOnTheMachinesOwnSocketIsRefused() throws {
        let reg = registry()
        let machine = root.appendingPathComponent("run/docker.sock").path
        for spelled in [machine, machine.replacingOccurrences(of: "/tmp/", with: "/private/tmp/")] {
            XCTAssertThrowsError(try reg.update("docker", enabled: nil, endpoint: "unix://" + spelled)) { error in
                XCTAssertTrue(error.localizedDescription.contains("micropod machine's own socket"), "\(error)")
            }
        }
        // The canonical link, pointing at a machine.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("run"), withIntermediateDirectories: true)
        let canonical = directory.appendingPathComponent("canonical.sock")
        try FileManager.default.createSymbolicLink(atPath: canonical.path, withDestinationPath: machine)
        XCTAssertThrowsError(try reg.update("docker", enabled: nil, endpoint: "unix://" + canonical.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("micropod machine's own socket"), "\(error)")
        }
        // The shim's own socket in the canonical place keeps the shim's words.
        try FileManager.default.removeItem(at: canonical)
        try Data().write(to: canonical)
        XCTAssertThrowsError(try reg.update("docker", enabled: nil, endpoint: "unix://" + canonical.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Docker shim"), "\(error)")
        }
        // Another engine's socket is fine.
        try reg.update(
            "docker", enabled: nil, endpoint: "unix://" + directory.appendingPathComponent("other.sock").path)
        XCTAssertEqual(
            registry().config.engines["docker"]?.endpoint,
            "unix://" + directory.appendingPathComponent("other.sock").path)
    }

    // MARK: Backend resolution

    func testResolvingNeverPingsAppleWhileItIsOptIn() async throws {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let pings = Counter()
        // A service no one registers: a ping fails at once, never reaching
        // Apple's apiserver.
        let makeAPI: @Sendable () -> APIServerClient = {
            pings.increment()
            return APIServerClient(service: "dev.micropod.tests.no-such-service")
        }
        try write(.fresh)
        XCTAssertFalse(RuntimeBackendResolver.pingsApple(environment: environment()))
        let fresh = await RuntimeBackendResolver.resolve(
            client: client, environment: environment(), pingTimeout: .milliseconds(500), makeAPI: makeAPI)
        XCTAssertEqual(pings.value, 0, "a fresh install never pings Apple")
        XCTAssertEqual(fresh.kind, .cli)
        XCTAssertNotNil(fresh.router, "the other engines are still routed")

        XCTAssertTrue(RuntimeBackendResolver.pingsApple(environment: environment(["MICROPOD_RUNTIME": "native"])))
        try write(.existing)
        XCTAssertTrue(RuntimeBackendResolver.pingsApple(environment: environment()))
        _ = await RuntimeBackendResolver.resolve(
            client: client, environment: environment(), pingTimeout: .milliseconds(500), makeAPI: makeAPI)
        XCTAssertEqual(pings.value, 1, "an existing install pings as before")
    }
}

/// Every call Apple's container service receives, by name.
private actor CallLog: ContainerServing {
    var calls: [String] = []
    func list() async throws -> [Micropod_V1_Container] {
        calls.append("list")
        return [Micropod_V1_Container.with { $0.id = "apple-one" }]
    }
    func inspect(_ id: String) async throws -> Data { Data() }
    func create(_ request: ContainerRunRequest) async throws -> String { request.image }
    func run(_ request: ContainerRunRequest) async throws -> String { request.image }
    func exec(_ request: ContainerExecRequest) async throws -> String { "" }
    func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        ContainerExecResult(output: "", error: "", exitCode: 0)
    }
    func start(_ id: String) async throws {}
    func stop(_ id: String, timeout: Int) async throws {}
    func restart(_ id: String) async throws {}
    func stopAll() async throws { calls.append("stopAll") }
    func kill(_ id: String, signal: String) async throws {}
    func delete(_ id: String, force: Bool) async throws {}
    func deleteAll(force: Bool) async throws { calls.append("deleteAll") }
    func prune() async throws -> String {
        calls.append("prune")
        return ""
    }
    func export(_ id: String, to outputPath: String) async throws {}
    func copy(from: String, to: String) async throws {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
