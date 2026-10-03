import MicropodCore
import XCTest

@testable import MicropodApp

@MainActor
final class RuntimeConfirmationTests: XCTestCase {
    func testStopConfirmationCountsOnlyRunningAppleWorkloads() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.containers = [
            container("api", runtime: "apple", state: "running"),
            container("legacy", runtime: "", state: "running"),
            container("old", runtime: "apple", state: "stopped"),
            container("docker-db", runtime: "docker", state: "running"),
            container("job", runtime: "sandbox", state: "running"),
        ]
        store.machines = [MachineEntry(name: "linux-dev", state: "running")]
        XCTAssertEqual(store.runtimeStopAffectedCount, 3)
        store.requestRuntimeStop()
        XCTAssertTrue(store.runtimeStopConfirmationRequested)
        XCTAssertTrue(store.isRuntimeRunning, "Requesting confirmation must not stop the runtime.")
    }

    private func container(_ id: String, runtime: String, state: String) -> Micropod_V1_Container {
        var value = Micropod_V1_Container()
        value.id = id
        value.runtime = runtime
        value.state = state
        return value
    }
}
