import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

final class ForcedMachineRefreshTests: XCTestCase {
    @MainActor
    func testStopRefreshesAfterAnOlderReadWhileOrdinaryCallersCoalesce() async throws {
        let fixture = try GatedMachineCLI()
        defer { fixture.cleanUp() }
        let store = makeRunningStore(client: fixture.client)
        defer { store.stopPollers() }

        let oldRead = Task { await store.refreshMachines() }
        try await waitUntil { fixture.firstReadStarted }
        var observerStarted = false
        let observer = Task {
            observerStarted = true
            await store.refreshMachines()
        }
        try await waitUntil { observerStarted }
        XCTAssertEqual(fixture.listCalls, 1)

        let mutation = Task { await store.stopMachine("linux-dev") }
        try await waitUntil {
            fixture.machineStopped && store.activity.contains { $0.message == "Stopped machine linux-dev" }
        }
        try fixture.releaseFirstRead()
        await oldRead.value
        await observer.value
        await mutation.value

        XCTAssertEqual(store.machines.map(\.state), ["stopped"], "A pre-mutation read must not satisfy Stop's refresh")
        XCTAssertNil(store.machineError)
        XCTAssertEqual(fixture.listCalls, 2, "Stop needs exactly one fresh read after the shared older read")
        await store.refreshMachines()
        XCTAssertEqual(fixture.listCalls, 2, "Ordinary refreshes still respect the five-second throttle")
    }

    @MainActor
    func testStoppingPollersCancelsQueuedForcedRefreshAndAllowsALaterRead() async throws {
        let fixture = try GatedMachineCLI()
        defer { fixture.cleanUp() }
        let store = makeRunningStore(client: fixture.client)
        defer { store.stopPollers() }

        let oldRead = Task { await store.refreshMachines() }
        try await waitUntil { fixture.firstReadStarted }
        var forceStarted = false
        let forcedRead = Task {
            forceStarted = true
            await store.refreshMachines(force: true)
        }
        try await waitUntil { forceStarted }
        store.stopPollers()
        try fixture.releaseFirstRead()
        await oldRead.value
        await forcedRead.value

        XCTAssertTrue(store.machines.isEmpty, "A cancelled CLI result must not update the inventory")
        XCTAssertNil(store.machineError, "Cancellation must not surface as a machine failure")
        XCTAssertEqual(fixture.listCalls, 1, "A queued forced observer must not restart a stopped refresh")

        await store.refreshMachines(force: true)
        XCTAssertEqual(store.machines.map(\.state), ["running"])
        XCTAssertEqual(fixture.listCalls, 2)
    }
}

/// Captures the first list before permitting Stop, then releases that older
/// JSON result only when the test has observed the mutation on disk.
private struct GatedMachineCLI {
    let directory: URL
    let client: ContainerCLIClient
    private let trace: URL
    private let captured: URL
    private let released: URL
    private let stopped: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-refresh-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        trace = directory.appendingPathComponent("lists.log")
        captured = directory.appendingPathComponent("captured")
        released = directory.appendingPathComponent("released")
        stopped = directory.appendingPathComponent("stopped")
        let state = directory.appendingPathComponent("machines.json")
        try Data(#"[{"name":"linux-dev","state":"running"}]"#.utf8).write(to: state)
        let script = directory.appendingPathComponent("container")
        let contents = """
            #!/bin/bash
            case "${1:-}:${2:-}" in
              machine:list)
                snapshot="$(cat "\(state.path)")"
                printf 'list\\n' >> "\(trace.path)"
                if [ ! -f "\(captured.path)" ]; then
                  touch "\(captured.path)"
                  while [ ! -f "\(released.path)" ]; do sleep 0.01; done
                fi
                printf '%s\\n' "$snapshot"
                ;;
              machine:stop)
                printf '%s\\n' '[{"name":"linux-dev","state":"stopped"}]' > "\(state.path)"
                touch "\(stopped.path)"
                ;;
              *) exit 1 ;;
            esac
            """
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        client = ContainerCLIClient(executableURL: script)
    }

    var firstReadStarted: Bool { FileManager.default.fileExists(atPath: captured.path) }
    var machineStopped: Bool { FileManager.default.fileExists(atPath: stopped.path) }
    var listCalls: Int {
        (try? String(contentsOf: trace, encoding: .utf8))?.split(separator: "\n").count ?? 0
    }

    func releaseFirstRead() throws { try Data().write(to: released) }

    func cleanUp() {
        try? releaseFirstRead()
        try? FileManager.default.removeItem(at: directory)
    }
}
