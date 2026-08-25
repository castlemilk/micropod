import Foundation
import MicropodCore
import XCTest

/// Harness for driving the Micropod services against the stateful mock
/// `container` CLI (`Support/mock-container`).
///
/// Each test gets its own isolated state directory injected through a wrapper
/// script (the client copies `ProcessInfo.environment`, so we cannot rely on
/// `setenv` from the test process).
enum MockContainerCLI {
    /// The checked-in mock script.
    static var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Support/mock-container")
    }

    /// Creates a fresh state directory + a client whose executable is a
    /// wrapper that points the mock at that directory.
    static func makeClient(file: StaticString = #filePath, line: UInt = #line) throws -> (
        client: ContainerCLIClient, stateDir: URL
    ) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-mock-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let script = scriptURL
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw XCTSkip(
                "mock container CLI missing or not executable at \(script.path)",
                file: file, line: line)
        }

        let wrapper = dir.appendingPathComponent("mock-container")
        let contents =
            "#!/bin/bash\n"
            + "export MICROPOD_MOCK_STATE_DIR=\"\(dir.path)\"\n"
            + "exec \"\(script.path)\" \"$@\"\n"
        try Data(contents.utf8).write(to: wrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        return (ContainerCLIClient(executableURL: wrapper), dir)
    }

    /// Convenience: client + a service bundle bound to the same mock state.
    static func makeServices(file: StaticString = #filePath, line: UInt = #line) throws -> (
        client: ContainerCLIClient,
        stateDir: URL,
        system: SystemService,
        containers: ContainerService,
        images: ImageService,
        volumes: VolumeService,
        networks: NetworkService,
        registries: RegistryService,
        stats: StatsSampler,
        logs: LogStreamer,
        compose: ComposeService
    ) {
        let (client, stateDir) = try makeClient(file: file, line: line)
        return (
            client, stateDir,
            SystemService(client: client),
            ContainerService(client: client),
            ImageService(client: client),
            VolumeService(client: client),
            NetworkService(client: client),
            RegistryService(client: client),
            StatsSampler(client: client),
            LogStreamer(client: client),
            ComposeService(client: client)
        )
    }

    /// Removes a state directory at teardown.
    static func cleanUp(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) {
        try? FileManager.default.removeItem(at: dir)
    }
}

extension XCTestCase {
    /// Runs a block against a fresh mock CLI harness and cleans up afterwards.
    func withMockServices(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (MockServices) async throws -> Void
    ) async throws {
        let (client, stateDir, system, containers, images, volumes, networks, registries, stats, logs, compose) =
            try MockContainerCLI.makeServices(file: file, line: line)
        defer { MockContainerCLI.cleanUp(stateDir, file: file, line: line) }
        try await body(
            MockServices(
                client: client, stateDir: stateDir, system: system, containers: containers,
                images: images, volumes: volumes, networks: networks, registries: registries,
                stats: stats, logs: logs, compose: compose))
    }
}

/// Bundled services bound to one mock runtime instance.
struct MockServices {
    let client: ContainerCLIClient
    let stateDir: URL
    let system: SystemService
    let containers: ContainerService
    let images: ImageService
    let volumes: VolumeService
    let networks: NetworkService
    let registries: RegistryService
    let stats: StatsSampler
    let logs: LogStreamer
    let compose: ComposeService

    /// Runs a container through the service layer and returns its id.
    func runContainer(
        image: String = "nginx:1.27",
        name: String? = nil,
        env: [String] = [],
        ports: [PortSpec] = [],
        volumes: [String] = [],
        labels: [LabelSpec] = [],
        cpus: Double? = nil,
        memory: String? = nil
    ) async throws -> String {
        let request = ContainerRunRequest(
            image: image,
            name: name,
            detach: true,
            cpus: cpus,
            memory: memory,
            env: env,
            publishedPorts: ports,
            volumes: volumes,
            labels: labels)
        return try await containers.run(request)
    }
}
