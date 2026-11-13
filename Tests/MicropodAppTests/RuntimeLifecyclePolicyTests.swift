import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

@MainActor
final class RuntimeLifecyclePolicyTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let store: AppStore

        func marker(_ name: String) throws {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        var calls: [String] {
            ((try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func cleanUp() {
            store.stopPollers()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("container")
        let script = """
            #!/bin/sh
            cd '\(directory.path)' || exit 2
            printf '%s\n' "$*" >> calls
            case "$1 $2" in
              'system version')
                if [ -f version-unsupported ]; then
                  echo '[{"appName":"container","version":"1.6.0"}]'
                else
                  echo '[{"appName":"container","version":"1.5.0"}]'
                fi ;;
              'system status')
                if [ -f bad-status ]; then exit 1; fi
                result=0
                state='{"status":"running"}'
                if [ -f stopped ]; then state='{"status":"unregistered"}'; result=1; fi
                if [ -f hold-status ]; then
                  /usr/bin/touch status-observed
                  while [ -f hold-status ]; do /bin/sleep 0.02; done
                fi
                echo "$state"
                exit "$result" ;;
              'system start')
                if [ -f start-fails ]; then exit 2; fi
                while [ -f hold-start ]; do /bin/sleep 0.02; done
                /bin/rm -f stopped ;;
              'system stop')
                if [ -f stop-fails ]; then exit 2; fi
                /usr/bin/touch stopped ;;
              *)
                if [ -f probe-fails ]; then exit 2; fi
                echo '[]' ;;
            esac
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let suite = "micropod-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = AppStore(
            dependencies: AppDependencies(client: ContainerCLIClient(executableURL: executable)),
            runtimeDefaults: defaults)
        return Fixture(directory: directory, defaults: defaults, suite: suite, store: store)
    }

    func testAutomaticStartupRequiresExplicitOptIn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.marker("stopped")
        await fixture.store.runRuntimeSupervisorTick()
        XCTAssertFalse(fixture.store.runtimeAutoStartEnabled)
        XCTAssertEqual(fixture.store.runtimeDependencyStatus.state, .stopped)
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("system start") })
        fixture.store.runtimeAutoStartEnabled = true
        await fixture.store.runRuntimeSupervisorTick()
        XCTAssertTrue(fixture.store.isRuntimeRunning)
        XCTAssertEqual(fixture.calls.filter { $0.hasPrefix("system start") }.count, 1)
        XCTAssertTrue(fixture.calls.contains("system start --disable-kernel-install"))
    }

    func testManualStopSurvivesRelaunchUntilExplicitStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.runtimeAutoStartEnabled = true
        await fixture.store.refreshSystemStatus(force: true)
        await fixture.store.stopRuntime()
        XCTAssertTrue(fixture.store.runtimeAutomationPaused)
        await fixture.store.runRuntimeSupervisorTick()
        let relaunched = AppStore(dependencies: fixture.store.dependencies, runtimeDefaults: fixture.defaults)
        defer { relaunched.stopPollers() }
        XCTAssertTrue(relaunched.runtimeAutoStartEnabled)
        XCTAssertTrue(relaunched.runtimeAutomationPaused)
        await relaunched.runRuntimeSupervisorTick()
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("system start") })
        await relaunched.startRuntime()
        XCTAssertFalse(relaunched.runtimeAutomationPaused)
        XCTAssertFalse(fixture.defaults.bool(forKey: UserDefaultsKeys.runtimeAutomationPaused))
        XCTAssertTrue(relaunched.isRuntimeRunning)
    }

    func testMalformedStatusNeverAuthorizesAutomaticStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.runtimeAutoStartEnabled = true
        try fixture.marker("bad-status")
        await fixture.store.runRuntimeSupervisorTick()
        XCTAssertEqual(fixture.store.runtimeDependencyStatus.state, .degraded)
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("system start") })
    }

    func testUnqualifiedVersionNeverAuthorizesAutomaticStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.runtimeAutoStartEnabled = true
        try fixture.marker("version-unsupported")
        try fixture.marker("stopped")
        await fixture.store.runRuntimeSupervisorTick()
        XCTAssertFalse(fixture.store.runtimeDependencyStatus.cliVersionSupported)
        XCTAssertFalse(fixture.store.canAutomaticallyStartRuntime)
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("system start") })
    }

    func testAutomaticStartFailurePausesRetriesWithoutStoppingService() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.runtimeAutoStartEnabled = true
        try fixture.marker("stopped")
        try fixture.marker("start-fails")
        for _ in 0..<5 { await fixture.store.runRuntimeSupervisorTick() }
        XCTAssertEqual(fixture.calls.filter { $0.hasPrefix("system start") }.count, 1)
        XCTAssertTrue(fixture.defaults.bool(forKey: UserDefaultsKeys.runtimeAutomationPaused))
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("system stop") })
    }

    func testUnresponsiveRuntimeIsReportedWithoutKillingConsumers() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.runtimeAutoStartEnabled = true
        // Even a legacy preference cannot enable the removed disruptive path.
        fixture.defaults.set(true, forKey: UserDefaultsKeys.runtimeAutoHeal)
        try fixture.marker("probe-fails")
        for _ in 0..<3 { await fixture.store.runRuntimeSupervisorTick() }
        XCTAssertEqual(fixture.store.runtimeHealth, .wedged)
        XCTAssertEqual(fixture.store.runtimeDependencyStatus.state, .degraded)
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("system stop") || $0.hasPrefix("system start") })
    }

    func testConcurrentStartsLaunchOnlyOneCommand() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.marker("stopped")
        try fixture.marker("hold-start")
        let first = Task { await fixture.store.startRuntime() }
        try await waitUntil { fixture.calls.contains { $0.hasPrefix("system start") } }
        await fixture.store.startRuntime()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("hold-start"))
        await first.value
        XCTAssertEqual(fixture.calls.filter { $0.hasPrefix("system start") }.count, 1)
        XCTAssertFalse(fixture.store.runtimeOperationInProgress)
    }

    func testCancelledStartLeavesAutomaticRetriesPausedAcrossRelaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.runtimeAutoStartEnabled = true
        try fixture.marker("stopped")
        try fixture.marker("hold-start")
        let first = Task { await fixture.store.startRuntime() }
        try await waitUntil { fixture.calls.contains { $0.hasPrefix("system start") } }
        XCTAssertTrue(
            fixture.defaults.bool(forKey: UserDefaultsKeys.runtimeAutomationPaused),
            "Intent is persisted before the command runs")
        first.cancel()
        await first.value
        let relaunched = AppStore(dependencies: fixture.store.dependencies, runtimeDefaults: fixture.defaults)
        defer { relaunched.stopPollers() }
        await relaunched.runRuntimeSupervisorTick()
        XCTAssertTrue(relaunched.runtimeAutomationPaused)
        XCTAssertEqual(fixture.calls.filter { $0.hasPrefix("system start") }.count, 1)
        XCTAssertFalse(fixture.store.runtimeOperationInProgress)
    }

    func testStopIntentDuringStartCannotBeClearedByLateStartCompletion() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.marker("stopped")
        try fixture.marker("hold-start")
        let start = Task { await fixture.store.startRuntime() }
        try await waitUntil { fixture.calls.contains { $0.hasPrefix("system start") } }
        await fixture.store.stopRuntime()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("hold-start"))
        await start.value
        XCTAssertTrue(fixture.store.runtimeAutomationPaused)
        XCTAssertTrue(fixture.defaults.bool(forKey: UserDefaultsKeys.runtimeAutomationPaused))
        XCTAssertFalse(
            fixture.calls.contains { $0.hasPrefix("system stop") }, "Conflicting lifecycle commands cannot overlap")
    }

    func testRestartDoesNotStartAfterAnUncertainStopFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        await fixture.store.refreshSystemStatus(force: true)
        try fixture.marker("stop-fails")
        await fixture.store.restartRuntime()
        XCTAssertTrue(fixture.store.runtimeAutomationPaused)
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("system start") })
    }

    func testForcedReadAfterStartDoesNotReusePreStartStatus() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.marker("stopped")
        try fixture.marker("hold-status")
        let beforeStart = Task { await fixture.store.refreshSystemStatus() }
        try await waitUntil {
            FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("status-observed").path)
        }
        let start = Task { await fixture.store.startRuntime() }
        try await waitUntil {
            !FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("stopped").path)
        }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("hold-status"))
        await beforeStart.value
        await start.value
        XCTAssertTrue(fixture.store.isRuntimeRunning, "Post-start readiness must use a post-start status read")
        XCTAssertFalse(fixture.store.runtimeAutomationPaused)
        XCTAssertEqual(fixture.calls.filter { $0.hasPrefix("system status") }.count, 2)
    }

    func testInstallationWhileOpenIsDiscovered() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let executable = fixture.directory.appendingPathComponent("container")
        let saved = fixture.directory.appendingPathComponent("installer-payload")
        try FileManager.default.moveItem(at: executable, to: saved)
        await fixture.store.refreshSystemStatus(force: true)
        XCTAssertEqual(fixture.store.runtimeDependencyStatus.state, .missingCLI)
        try FileManager.default.moveItem(at: saved, to: executable)
        await fixture.store.refreshSystemStatus(force: true)
        XCTAssertTrue(fixture.store.clientAvailable)
        XCTAssertEqual(fixture.store.systemStatus?.cliVersion, "1.5.0")
    }
}
