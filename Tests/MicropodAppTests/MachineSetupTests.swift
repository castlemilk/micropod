import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

/// The app's first run on a fresh install: the machine is set up over the
/// API (`SetupMachine`), onboarding leads with it, and the Apple runtime's
/// Docker shim agent is not started by default.
final class SetupMachineControl: MachineControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Micropod_V1_SetupMachineRequest] = []
    var result = Micropod_V1_SetupMachineResult()
    var installed = false

    var setups: [Micropod_V1_SetupMachineRequest] { lock.withLock { requests } }

    func status() async throws -> Micropod_V1_HVFMachineStatus {
        let installed = lock.withLock { self.installed }
        return .with {
            $0.installed = installed
            $0.readiness = installed ? "running" : "not-installed"
            if !installed { $0.missing = ["disk.ext4"] }
        }
    }
    func control(_ action: String, force: Bool) async throws -> Micropod_V1_HVFMachineStatus { try await status() }
    func setAutostart(_ enabled: Bool, force: Bool) async throws -> Micropod_V1_HVFMachineStatus {
        try await status()
    }
    func defaultRuntime() async throws -> String { "hvf" }
    func setup(_ request: Micropod_V1_SetupMachineRequest) async throws -> Micropod_V1_SetupMachineResult {
        lock.withLock { requests.append(request) }
        return lock.withLock { result }
    }
}

@MainActor
final class MachineSetupTests: XCTestCase {
    private func step(_ id: String, _ state: String, _ detail: String = "") -> Micropod_V1_SetupMachineStep {
        .with {
            $0.id = id
            $0.state = state
            $0.detail = detail
        }
    }

    func testAFreshMachineNeedsSetupAndSetsUpOverTheAPI() async throws {
        let client = SetupMachineControl()
        let model = MachineModel(client: client)
        await model.refresh()
        XCTAssertEqual(model.phase, .notInstalled)
        XCTAssertTrue(model.needsSetup)

        client.result = .with {
            $0.ok = true
            $0.steps = [step("runtime-files", "done"), step("disk", "done"), step("start", "done")]
            $0.machine = .with {
                $0.installed = true
                $0.readiness = "running"
            }
        }
        await model.setUp()
        XCTAssertEqual(client.setups.count, 1)
        XCTAssertTrue(client.setups[0].start, "the app's setup also starts the machine")
        XCTAssertTrue(client.setups[0].diskFrom.isEmpty, "the bundled base disk unless one is chosen")
        XCTAssertEqual(model.setupSteps.map(\.state), ["done", "done", "done"])
        XCTAssertEqual(model.phase, .running, "the reply's machine status is shown at once")
        XCTAssertFalse(model.needsSetup)
        XCTAssertFalse(model.settingUp)
    }

    func testANoBaseDiskFailureOffersADiskImageAndTheCommand() async throws {
        let client = SetupMachineControl()
        client.result = .with {
            $0.ok = false
            $0.steps = [
                step("runtime-files", "pending", "nothing was changed"),
                step("disk", "failed", "no base disk: this package ships none."),
            ]
        }
        let model = MachineModel(client: client)
        await model.setUp()
        XCTAssertEqual(model.setupFailure?.id, "disk")
        XCTAssertTrue(model.setupCommand.contains("micropod setup --disk-from <ext4>"), model.setupCommand)
        await model.setUp(diskFrom: URL(fileURLWithPath: "/Volumes/Disks/base.ext4"))
        XCTAssertEqual(client.setups.last?.diskFrom, "/Volumes/Disks/base.ext4")
    }

    func testAClientWithoutSetupSaysSo() async {
        let model = MachineModel(client: FakeMachineControl())
        await model.setUp()
        XCTAssertEqual(model.setupError, "machine setup is not available")
        XCTAssertEqual(model.setupCommand, "micropod setup")
    }

    func testOnboardingLeadsWithTheMachineOnAFreshInstall() {
        XCTAssertTrue(OnboardingTourView.showsMachineSetup(appleRuntimeEnabled: false, needsSetup: false))
        XCTAssertTrue(OnboardingTourView.showsMachineSetup(appleRuntimeEnabled: true, needsSetup: true))
        XCTAssertFalse(
            OnboardingTourView.showsMachineSetup(appleRuntimeEnabled: true, needsSetup: false),
            "an existing install keeps the Apple runtime's tour")
    }

    func testTheDockerShimAgentDefaultsOffWhileAppleIsOptIn() {
        XCTAssertFalse(AppStore.agentEnabledByDefault("docker-shim", appleRuntimeEnabled: false))
        XCTAssertTrue(AppStore.agentEnabledByDefault("docker-shim", appleRuntimeEnabled: true))
        XCTAssertTrue(AppStore.agentEnabledByDefault("api-server", appleRuntimeEnabled: false))
        XCTAssertTrue(AppStore.agentEnabledByDefault("shared-fs", appleRuntimeEnabled: false))
        XCTAssertTrue(AppStore.appleRuntimeEnabledAtLaunch(), "unit tests keep the Apple runtime unless told")
    }

    /// With Apple not enabled, a status refresh never asks Apple's runtime
    /// (no `container system status`) and leaves it unknown.
    func testAStoreWithAppleOptInNeverPollsAppleStatus() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = AppStore(
            dependencies: AppDependencies(client: fixture.client), machineClient: SetupMachineControl(),
            appleRuntimeEnabled: false)
        await store.refreshSystemStatus(force: true)
        XCTAssertNil(store.systemStatus)
        XCTAssertFalse(store.isRuntimeRunning)
        await store.refreshMachines(force: true)
        let trace = (try? String(contentsOf: fixture.traceURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(trace, "", "the container CLI was never run")

        // The same store with Apple enabled asks it, as before.
        let enabled = AppStore(
            dependencies: AppDependencies(client: fixture.client), machineClient: SetupMachineControl(),
            appleRuntimeEnabled: true)
        await enabled.refreshSystemStatus(force: true)
        let asked = (try? String(contentsOf: fixture.traceURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(asked.contains("system status"), asked)
    }
}
