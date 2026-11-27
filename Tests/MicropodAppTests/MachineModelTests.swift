import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

/// RigService as the app sees it: scripted answers, recorded requests, and
/// a start that can be held open.
final class FakeMachineControl: MachineControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var statuses: [Micropod_V1_HVFMachineStatus]
    var statusError: Error?
    var controlError: (@Sendable (String, Bool) -> Error?)?
    var autostartError: (@Sendable (Bool, Bool) -> Error?)?
    var defaultName = "hvf"
    /// Holds a control call until `release()`.
    private var gate: CheckedContinuation<Void, Never>?
    var holdControl = false

    init(_ statuses: [Micropod_V1_HVFMachineStatus] = []) { self.statuses = statuses }

    var calls: [String] { lock.withLock { recorded } }
    private func note(_ call: String) { lock.withLock { recorded.append(call) } }

    func status() async throws -> Micropod_V1_HVFMachineStatus {
        note("status")
        if let statusError { throw statusError }
        return lock.withLock { statuses.count > 1 ? statuses.removeFirst() : statuses.first ?? .init() }
    }

    func control(_ action: String, force: Bool) async throws -> Micropod_V1_HVFMachineStatus {
        note("control \(action)\(force ? " force" : "")")
        if holdControl { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        if let error = controlError?(action, force) { throw error }
        return .with {
            $0.installed = true
            $0.readiness = action == "stop" ? "stopped" : "running"
        }
    }

    func setAutostart(_ enabled: Bool, force: Bool) async throws -> Micropod_V1_HVFMachineStatus {
        note("autostart \(enabled)\(force ? " force" : "")")
        if let error = autostartError?(enabled, force) { throw error }
        return .with {
            $0.installed = true
            $0.readiness = "running"
            $0.autostart = .with { $0.enabled = enabled }
        }
    }

    func defaultRuntime() async throws -> String { defaultName }

    func release() {
        lock.withLock {
            gate?.resume()
            gate = nil
        }
    }

    var holding: Bool { lock.withLock { gate != nil } }
}

@MainActor
final class MachineModelTests: XCTestCase {
    private func running() -> Micropod_V1_HVFMachineStatus {
        .with {
            $0.installed = true
            $0.phase = "running"
            $0.readiness = "running"
            $0.engineVersion = "micropod"
            $0.engineApiVersion = "1.47"
            $0.engineMinApiVersion = "1.44"
            $0.containersTotal = 5
            $0.containersRunning = 3
            $0.diskFlush = "barrier (both disks)"
            $0.cacheDisk = .with {
                $0.mounted = true
                $0.sizeBytes = 32_000_000_000
                $0.freeBytes = 21_400_000_000
            }
        }
    }

    private static let deferred: @Sendable (String, Bool) -> Error? = { action, force in
        force
            ? nil
            : LocalAPI.RemoteError(
                code: "failed_precondition",
                message: "deferred: 3 running container(s) on the machine; nothing was stopped (force: true to "
                    + "\(action) anyway)")
    }

    func testARefreshShowsTheMachine() async {
        let model = MachineModel(client: FakeMachineControl([running()]))
        await model.refresh()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.headline, "Machine running")
        XCTAssertEqual(model.engineLine, "micropod · Docker API 1.44–1.47")
        XCTAssertEqual(model.containersLine, "3 running · 5 containers")
        XCTAssertEqual(model.cacheDiskLine, "Cache disk 21.4 GB free of 32 GB")
        XCTAssertEqual(model.diskFlushLine, "Disk flush barrier (both disks)")
        XCTAssertNil(model.reason)
        XCTAssertTrue(model.isShown && model.drivesHeader)
        XCTAssertTrue(model.canStop && model.canRestart)
        XCTAssertFalse(model.canStart)
    }

    func testAFailedMachineSaysWhy() async {
        let model = MachineModel(
            client: FakeMachineControl([
                .with {
                    $0.installed = true
                    $0.phase = "failed"
                    $0.readiness = "failed"
                    $0.failureReason = "micropod-vmm exited 5 times within 60 s"
                }
            ]))
        await model.refresh()
        XCTAssertEqual(model.headline, "Machine failed")
        XCTAssertEqual(model.reason, "micropod-vmm exited 5 times within 60 s")
        XCTAssertTrue(model.canStart)
    }

    func testAnUnreachableAPIIsShownAsSuch() async {
        let fake = FakeMachineControl()
        fake.statusError = LocalAPI.Unreachable(detail: "connection refused")
        let model = MachineModel(client: fake)
        await model.refresh()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertEqual(model.headline, "Machine status unavailable")
        XCTAssertTrue(model.reason?.contains("not reachable") == true, model.reason ?? "nil")
    }

    func testADeferredStopAsksAndThenForces() async {
        let fake = FakeMachineControl([running()])
        fake.controlError = Self.deferred
        let model = MachineModel(client: fake)
        await model.refresh()
        await model.perform(.stop)
        XCTAssertEqual(model.deferral?.request, .control(.stop))
        XCTAssertEqual(model.deferral?.reason, "3 running container(s) on the machine")
        XCTAssertNil(model.reason, "a deferral is a question, not an error")
        await model.confirmDeferral()
        XCTAssertNil(model.deferral)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("control") }, ["control stop", "control stop force"])
        XCTAssertEqual(model.phase, .stopped)

        await model.perform(.restart)
        XCTAssertEqual(model.deferral?.request, .control(.restart))
        model.cancelDeferral()
        XCTAssertNil(model.deferral)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("control") }.last, "control restart", "cancel sends nothing")
    }

    func testAStartShowsStartingUntilItReturns() async throws {
        let fake = FakeMachineControl([
            .with {
                $0.installed = true
                $0.readiness = "stopped"
            }
        ])
        fake.holdControl = true
        let model = MachineModel(client: fake)
        await model.refresh()
        XCTAssertTrue(model.canStart)
        let start = Task { await model.perform(.start) }
        try await waitUntil { fake.holding }
        XCTAssertEqual(model.headline, "Starting…")
        XCTAssertTrue(model.transitioning)
        XCTAssertFalse(model.canStart || model.canStop, "no second request while one runs")
        fake.release()
        await start.value
        XCTAssertEqual(model.headline, "Machine running")
    }

    func testAutostartGoesThroughTheAPIAndADeferralAsks() async {
        let fake = FakeMachineControl([running()])
        fake.autostartError = { _, force in
            force
                ? nil
                : LocalAPI.RemoteError(
                    code: "failed_precondition",
                    message: "deferred: 3 running container(s) on the machine; the machine runs outside launchd")
        }
        let model = MachineModel(client: fake)
        await model.refresh()
        XCTAssertFalse(model.autostartEnabled)
        await model.setAutostart(true)
        XCTAssertEqual(model.deferral?.request, .autostart(true))
        await model.confirmDeferral()
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("autostart") }, ["autostart true", "autostart true force"])
        XCTAssertTrue(model.autostartEnabled)
    }

    func testAnotherErrorIsShownNotAsked() async {
        let fake = FakeMachineControl([running()])
        fake.controlError = { _, _ in LocalAPI.RemoteError(code: "unavailable", message: "hvf machine failed to start")
        }
        let model = MachineModel(client: fake)
        await model.refresh()
        await model.perform(.restart)
        XCTAssertNil(model.deferral)
        XCTAssertEqual(model.reason, "hvf machine failed to start")
    }

    func testPollingRefreshesAndStops() async throws {
        let fake = FakeMachineControl([running()])
        let model = MachineModel(client: fake, visibleInterval: .milliseconds(20), hiddenInterval: .milliseconds(20))
        model.startPolling()
        try await waitUntil { fake.calls.count(where: { $0 == "status" }) >= 3 }
        model.stopPolling()
        XCTAssertFalse(model.isPolling)
        let seen = fake.calls.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.calls.count, seen, "nothing polls once stopped")
        XCTAssertEqual(model.phase, .running)
    }

    func testTheHeaderFollowsTheMachineOnlyWhenHVFIsTheDefault() async {
        let fake = FakeMachineControl([running()])
        fake.defaultName = "apple"
        let model = MachineModel(client: fake)
        await model.refresh()
        XCTAssertFalse(model.drivesHeader)
        XCTAssertTrue(model.isShown, "an installed machine still gets its card")
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        XCTAssertFalse(store.hvfMachine.isPolling, "tests never poll the live API")
    }
}
