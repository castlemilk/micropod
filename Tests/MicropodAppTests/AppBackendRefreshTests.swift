import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp
@testable import MicropodRuntime

/// The app keeps its runtime backend current after launch. An apiserver that
/// is unregistered and re-registered (stop/start, a watchdog restart, an
/// update) invalidates the app's XPC connection for good; the app used to
/// hold it, every list/stats/logs call failing, until relaunched. Resolvers
/// are scripted, so no runtime is needed; each backend is tagged through
/// `health.apiServerVersion` to tell which one is current.
@MainActor
final class AppBackendRefreshTests: XCTestCase {

    func testInvalidatedNativeConnectionIsReplaced() async throws {
        let dead = APIServerClient(service: "com.micropod.tests.unregistered-\(UUID().uuidString)")
        _ = try? await dead.ping(timeout: .seconds(2))
        XCTAssertTrue(dead.isInvalidated, "a send to an unregistered service latches invalidation")

        let dependencies = AppDependencies(client: Self.client)
        let backends = ScriptedBackends([
            Self.services(.native, tag: "native-1", api: dead),
            Self.services(.native, tag: "native-2"),
        ])
        await dependencies.useBackend(resolve: backends.resolve)
        XCTAssertEqual(dependencies.runtime?.health?.apiServerVersion, "native-1")

        let swapped = await dependencies.refreshBackendIfNeeded(force: true)
        XCTAssertTrue(swapped)
        XCTAssertEqual(dependencies.runtime?.health?.apiServerVersion, "native-2")
        XCTAssertTrue(
            (dependencies.statsSampler as AnyObject) === (dependencies.runtime?.stats as AnyObject),
            "the pollers' services move to the new backend")
    }

    func testCLIAtLaunchUpgradesToNative() async {
        let dependencies = AppDependencies(client: Self.client)
        let backends = ScriptedBackends([
            Self.services(.cli, tag: "cli-1"),
            Self.services(.native, tag: "native-2"),
        ])
        await dependencies.useBackend(resolve: backends.resolve)
        XCTAssertEqual(dependencies.runtime?.kind, .cli)

        let swapped = await dependencies.refreshBackendIfNeeded(force: true)
        XCTAssertTrue(swapped)
        XCTAssertEqual(dependencies.runtime?.kind, .native)
        XCTAssertEqual(dependencies.runtime?.health?.apiServerVersion, "native-2")
    }

    func testHealthyNativeBackendIsKept() async {
        let dependencies = AppDependencies(client: Self.client)
        let backends = ScriptedBackends([
            Self.services(.native, tag: "native-1"),
            Self.services(.native, tag: "native-2"),
        ])
        await dependencies.useBackend(resolve: backends.resolve)

        let swapped = await dependencies.refreshBackendIfNeeded(force: true)
        XCTAssertFalse(swapped)
        XCTAssertEqual(dependencies.runtime?.health?.apiServerVersion, "native-1")
    }

    func testRefreshBeforeLaunchResolutionIsANoOp() async {
        let dependencies = AppDependencies(client: Self.client)
        let swapped = await dependencies.refreshBackendIfNeeded(force: true)
        XCTAssertFalse(swapped)
        XCTAssertNil(dependencies.runtime)
    }

    // MARK: - Fixtures

    private static let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))

    private static func services(
        _ kind: RuntimeBackendKind, tag: String, api: APIServerClient? = nil
    ) -> RuntimeServices {
        RuntimeServices(
            kind: kind,
            containers: ContainerService(client: client),
            logs: LogStreamer(client: client),
            stats: StatsSampler(client: client),
            volumes: VolumeService(client: client),
            api: api,
            health: APIServerHealth(
                apiServerVersion: tag, apiServerCommit: "", apiServerBuild: "", apiServerAppName: "",
                appRoot: nil, installRoot: nil, logRoot: nil),
            exitCodes: kind == .native ? ExitCodeRegistry() : nil)
    }
}

/// Answers each resolution with the next scripted backend (the last repeats).
private actor ScriptedBackends {
    private var script: [RuntimeServices]

    init(_ script: [RuntimeServices]) {
        self.script = script
    }

    nonisolated var resolve: @Sendable (Duration) async -> RuntimeServices {
        { _ in await self.next() }
    }

    private func next() -> RuntimeServices {
        script.count > 1 ? script.removeFirst() : script[0]
    }
}
