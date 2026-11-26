import Foundation
import MicropodCore
import SwiftProtobuf
import XCTest

@testable import MicropodAPI
@testable import MicropodRuntime

/// DeleteContainer pruned the container's metrics series through the
/// process-wide store at ~/.micropod/metrics.sqlite, opening (and creating)
/// the rig's database from an API started for a throwaway root (B25 Z07).
/// The API now prunes only a database that already exists, at its own
/// location (`MetricsStore.url(environment:)`).
final class MetricsIsolationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-metrics-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func handlers(metrics: URL) -> APIHandlers {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = RuntimeServices(
            kind: .cli, containers: DeletableContainers(), logs: LogStreamer(client: client),
            stats: StatsSampler(client: client), volumes: VolumeService(client: client), api: nil, health: nil,
            exitCodes: nil)
        return APIHandlers(
            client: client, system: SystemService(client: client), images: ImageService(client: client),
            networks: NetworkService(client: client), compose: ComposeService(client: client),
            runtime: RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false }),
            engineRegistry: EngineRegistry(
                environment: [
                    "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
                    "MICROPOD_HVF_ROOT": root.appendingPathComponent("hvf").path,
                    "DOCKER_HOST": "unix:///nonexistent.sock",
                ],
                sandbox: SandboxEngine(root: root.appendingPathComponent("sandbox"))),
            metricsDatabase: metrics)
    }

    private func delete(_ api: APIHandlers, _ id: String) async throws {
        let request = Micropod_V1_DeleteContainerRequest.with { $0.id = id }
        let response = await api.connectRPC(
            method: "DeleteContainer", body: try request.serializedData(),
            headers: ["content-type": "application/proto"])
        guard case .data(200, _, _) = response else {
            return XCTFail("DeleteContainer answered \(String(describing: response))")
        }
    }

    func testDeletingAContainerCreatesNoMetricsDatabase() async throws {
        let metrics = root.appendingPathComponent("state/metrics.sqlite")
        try await delete(handlers(metrics: metrics), "web")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metrics.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metrics.deletingLastPathComponent().path))
    }

    func testDeletingAContainerPrunesItsSeriesFromThisAPIsDatabase() async throws {
        let metrics = root.appendingPathComponent("metrics.sqlite")
        let store = try MetricsStore(url: metrics)
        let now = Date()
        store.record([(.container, "web", .init(cpuPercent: 10)), (.container, "db", .init(cpuPercent: 20))], at: now)
        try await delete(handlers(metrics: metrics), "web")
        XCTAssertTrue(store.history(.container, "web", range: 3600, now: now).points.isEmpty, "its series is gone")
        XCTAssertFalse(store.history(.container, "db", range: 3600, now: now).points.isEmpty, "others stay")
    }
}

/// Containers whose delete succeeds.
private struct DeletableContainers: ContainerServing {
    private func refuse(_ what: String) -> MicropodError { .message("notFound: \(what)") }
    func list() async throws -> [Micropod_V1_Container] { [] }
    func inspect(_ id: String) async throws -> Data { throw refuse(id) }
    func create(_ request: ContainerRunRequest) async throws -> String { throw refuse("create") }
    func run(_ request: ContainerRunRequest) async throws -> String { throw refuse("run") }
    func exec(_ request: ContainerExecRequest) async throws -> String { throw refuse("exec") }
    func start(_ id: String) async throws { throw refuse(id) }
    func stop(_ id: String, timeout: Int) async throws { throw refuse(id) }
    func restart(_ id: String) async throws { throw refuse(id) }
    func stopAll() async throws {}
    func kill(_ id: String, signal: String) async throws { throw refuse(id) }
    func delete(_ id: String, force: Bool) async throws {}
    func deleteAll(force: Bool) async throws {}
    func prune() async throws -> String { "" }
    func export(_ id: String, to outputPath: String) async throws { throw refuse(id) }
    func copy(from: String, to: String) async throws { throw refuse(from) }
}
