import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

enum AppTestCLI {
    struct Fixture {
        let client: ContainerCLIClient
        let directory: URL
        let traceURL: URL
    }

    static func makeMock(listDelaySeconds: Double? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MicropodIntegrationTests/Support/mock-container")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw XCTSkip("mock container CLI missing or not executable at \(script.path)")
        }

        let wrapper = directory.appendingPathComponent("mock-container")
        let traceURL = directory.appendingPathComponent("commands.log")
        let listDelay =
            listDelaySeconds.map {
                "if [ \"${1:-}\" = \"list\" ]; then sleep \($0); fi\n"
            } ?? ""
        let contents = """
            #!/bin/bash
            export MICROPOD_MOCK_STATE_DIR="\(directory.path)"
            printf '%s\n' "$*" >> "\(traceURL.path)"
            \(listDelay)"\(script.path)" "$@"
            result=$?
            printf 'completed %s\n' "$*" >> "\(traceURL.path)"
            exit "$result"
            """
        try Data(contents.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return Fixture(
            client: ContainerCLIClient(executableURL: wrapper),
            directory: directory,
            traceURL: traceURL)
    }

    static func makeFailing() -> ContainerCLIClient {
        ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
    }

    static func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.directory)
    }
}

@MainActor
func makeRunningStore(client: ContainerCLIClient) -> AppStore {
    let store = AppStore(dependencies: AppDependencies(client: client))
    var status = Micropod_V1_SystemStatus()
    status.status = "running"
    store.clientAvailable = true
    store.systemStatus = status
    return store
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await clock.sleep(for: pollInterval)
    }
    throw AppTestTimeout(timeout: timeout)
}

private struct AppTestTimeout: LocalizedError {
    let timeout: Duration
    var errorDescription: String? { "Condition was not satisfied before \(timeout)" }
}
