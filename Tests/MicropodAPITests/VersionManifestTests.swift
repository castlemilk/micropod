import Foundation
import MicropodCore
import MicropodRuntime
import SwiftProtobuf
import XCTest

@testable import MicropodAPI

final class VersionManifestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-manifest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions a test removed so the tree can be deleted.
        if let paths = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in paths {
                chmod(root.appendingPathComponent(path).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private static let revision = "33eea649a1b2c3d4e5f60718293a4b5c6d7e8f90"

    private func environment(
        role: APIServerRole = .connect,
        dedicated: Bool = false,
        report: (@Sendable (TimeInterval) async throws -> [String: Any])? = nil,
        reachable: Bool = true,
        upstream: (@Sendable (String, Data, Duration) async throws -> Data)? = nil
    ) throws -> VersionEnvironment {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("MicropodAPI")
        try Data("api build".utf8).write(to: executable)
        try Data("guest build".utf8).write(to: bin.appendingPathComponent("micropod-guest"))
        let admission = root.appendingPathComponent("admission")
        return VersionEnvironment(
            role: role,
            build: .init(version: "0.14.0", revision: Self.revision),
            executable: executable,
            home: root.appendingPathComponent("home"),
            setupApp: root.appendingPathComponent("Micropod Runtime Setup.app"),
            dockerShimSocket: root.appendingPathComponent("docker.sock").path,
            sharedFSSocket: root.appendingPathComponent("sharedfs.sock").path,
            runtimeAdmission: { RuntimeAdmission(root: admission) },
            usesDedicatedRuntime: { dedicated },
            desktopReport: report ?? { _ in
                [
                    "state": "readyToInstall", "currentVersion": "0.13.6", "readyToInstall": true,
                    "downloaded": true, "downloadedVersion": "0.13.7", "restartGuard": "idle",
                    "currentSourceRevision": "4b1d4906cda28c05a452619149b49fd6f31a72c1",
                ]
            },
            desktopReachable: { reachable },
            dedicatedRequest: upstream ?? { _, _, _ in throw MicropodError.message("no dedicated runtime") })
    }

    private func handlers(_ environment: VersionEnvironment, defaultRuntime: String? = nil) async -> APIHandlers {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = await RuntimeBackendResolver.resolveApple(
            client: client, environment: ["MICROPOD_RUNTIME": "cli"])
        // Apple's runtime is the default here whatever this Mac's
        // ~/.micropod/runtimes.json says: with hvf as the default, Ping and
        // GetSystem describe the hvf machine instead (HVFReadinessAPITests).
        var registryEnvironment = [
            "MICROPOD_RUNTIMES_CONFIG": root.appendingPathComponent("runtimes.json").path,
            "MICROPOD_HVF_ROOT": root.appendingPathComponent("hvf").path,
            "DOCKER_HOST": "unix:///nonexistent.sock", "MICROPOD_HVF_AUTOSTART": "0",
        ]
        registryEnvironment["MICROPOD_DEFAULT_RUNTIME"] = defaultRuntime
        let engines = EngineRegistry(
            environment: registryEnvironment, sandbox: SandboxEngine(root: root.appendingPathComponent("sandbox")))
        return APIHandlers(
            client: client, system: SystemService(client: client), images: ImageService(client: client),
            networks: NetworkService(client: client), compose: ComposeService(client: client),
            runtime: RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false }),
            versionEnvironment: environment, engineRegistry: engines)
    }

    private func call<M: Message>(_ api: APIHandlers, _ method: String, as type: M.Type) async throws -> M {
        let request = HTTPRequest(
            method: .post, path: "/api/micropod.v1.SystemService/" + method, query: [:], body: Data("{}".utf8),
            headers: ["content-type": "application/json"])
        guard case .data(let code, _, let body) = await api.handle(request) else {
            throw MicropodError.message("\(method) did not answer with a body")
        }
        guard code == 200 else {
            throw MicropodError.message("\(method) answered \(code): \(String(decoding: body, as: UTF8.self))")
        }
        return try M(jsonUTF8Data: body)
    }

    private func component(_ name: MicropodComponent, in list: [Micropod_V1_ComponentVersion]) throws
        -> Micropod_V1_ComponentVersion
    {
        try XCTUnwrap(list.first { $0.name == name.rawValue }, "missing \(name.rawValue)")
    }

    private func writeBundle(_ url: URL, _ info: [String: Any], executable: String? = nil) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if let executable {
            try Data(executable.utf8).write(to: contents.appendingPathComponent("MacOS/" + executable))
        }
    }

    // MARK: - Ping

    func testPingReportsWhatThisServerRunsAndItsUpdateState() async throws {
        let api = await handlers(try environment())
        let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)

        XCTAssertEqual(ping.micropodVersion, "0.14.0")
        XCTAssertEqual(ping.sourceRevision, Self.revision)
        XCTAssertEqual(ping.protocolVersion, MicropodProtocol.apiVersion)
        XCTAssertEqual(ping.peerProtocol.name, "micropod-runtime-coordination")
        XCTAssertEqual(ping.peerProtocol.minVersion, 1)
        XCTAssertEqual(ping.peerProtocol.maxVersion, 1)
        XCTAssertEqual(ping.appleApiServerVersion, ping.apiServerVersion)
        XCTAssertEqual(ping.components.map(\.name), MicropodComponent.allCases.map(\.rawValue))

        let app = try component(.app, in: ping.components)
        XCTAssertEqual(app.version, "0.13.6")
        XCTAssertEqual(app.revision, "4b1d4906cda28c05a452619149b49fd6f31a72c1")
        XCTAssertEqual(app.state, "running")
        let connect = try component(.connectAPI, in: ping.components)
        XCTAssertEqual(connect.version, "0.14.0")
        XCTAssertEqual(connect.revision, Self.revision)
        XCTAssertEqual(connect.sha256, "", "Ping never hashes")
        XCTAssertEqual(try component(.dedicatedAPI, in: ping.components).state, "not_configured")
        XCTAssertEqual(try component(.setupHelper, in: ping.components).state, "not_configured")
        XCTAssertEqual(try component(.dockerShim, in: ping.components).state, "missing")
        XCTAssertEqual(try component(.guest, in: ping.components).version, "0.14.0")
        // The CLI backend here answers nothing: no invented runtime versions.
        let apple = try component(.appleRuntime, in: ping.components)
        XCTAssertEqual(apple.version, "unknown")
        XCTAssertEqual(try component(.vminit, in: ping.components).version, "unknown")

        XCTAssertEqual(ping.updateState.kind, .staged)
        XCTAssertEqual(ping.updateState.scope, "desktop")
        XCTAssertEqual(ping.updateState.currentVersion, "0.13.6")
        XCTAssertEqual(ping.updateState.targetVersion, "0.13.7")
    }

    /// Ping read the host's files, sockets and whole process table on every
    /// call (~7 ms; the B25 Ping p95 was 9.7 ms against a 1 ms target): the
    /// host components are now kept for their 2 s bound.
    func testPingObservesTheHostAtMostOncePerItsBound() async throws {
        var environment = try environment()
        let helperScans = Tally()
        environment.helperPrograms = {
            helperScans.add()
            return []
        }
        let api = await handlers(environment, defaultRuntime: "hvf")
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<50 {
            let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
            XCTAssertEqual(ping.components.map(\.name), MicropodComponent.allCases.map(\.rawValue) + ["hvf-machine"])
        }
        let elapsed = clock.now - started
        // One observation, plus at most one background refresh per second.
        XCTAssertLessThanOrEqual(helperScans.value, 1 + Int(elapsed / .seconds(1)), "\(elapsed)")
        XCTAssertLessThan(helperScans.value, 5)
    }

    /// The `vminit.image` read (`container system property list`) is not
    /// started while Apple's runtime is known to be down, and is again once
    /// it is not.
    func testPingDoesNotAskADownRuntimeForItsInitImage() async throws {
        var environment = try environment()
        let reads = Tally()
        let down = Flag(true)
        environment.vminitImage = {
            reads.add()
            return "ghcr.io/apple/containerization/vminit:0.42.0"
        }
        environment.appleRuntimeKnownDown = { down.value }
        let api = await handlers(environment, defaultRuntime: "hvf")
        for _ in 0..<10 {
            let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
            XCTAssertEqual(try component(.vminit, in: ping.components).state, "unknown")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.value, 0, "a down runtime is not asked")

        down.value = false
        _ = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
        let deadline = ContinuousClock.now + .seconds(5)
        while reads.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reads.value, 1)
        var kept = ""
        while kept.isEmpty, ContinuousClock.now < deadline {
            kept = try component(.vminit, in: try await call(api, "Ping", as: Micropod_V1_PingResponse.self).components)
                .version
            if kept == "unknown" { kept = "" }
        }
        XCTAssertEqual(kept, "0.42.0")
    }

    func testPingWithoutTheDesktopAppSaysUnknownInsteadOfCurrent() async throws {
        let api = await handlers(try environment(reachable: false))
        let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
        XCTAssertEqual(ping.updateState.kind, .unknown)
        XCTAssertFalse(ping.updateState.reason.isEmpty)
        let app = try component(.app, in: ping.components)
        XCTAssertEqual(app.state, "stopped")
        XCTAssertEqual(app.version, "unknown")
    }

    func testRuntimeMaintenanceOutranksTheDesktopState() async throws {
        let environment = try environment()
        let fence = try environment.runtimeAdmission().begin(operation: UUID())
        defer { withExtendedLifetime(fence) {} }
        let api = await handlers(environment)
        let state = try await call(api, "GetUpdateState", as: Micropod_V1_UpdateState.self)
        XCTAssertEqual(state.kind, .upgrading)
        XCTAssertEqual(state.scope, "runtime")
        XCTAssertEqual(state.phase, "runtime-maintenance")
        XCTAssertEqual(state.operationID, fence.fence.operation.uuidString)
    }

    // MARK: - Dedicated runtime API

    func testDedicatedAPIServesUpdateStateForRuntimeMaintenanceOnly() async throws {
        XCTAssertTrue(IsolatedRuntimeRequestPolicy.allows("/api/micropod.v1.SystemService/GetUpdateState"))
        XCTAssertFalse(IsolatedRuntimeRequestPolicy.allows("/api/micropod.v1.SystemService/GetUpdateStatus"))
        let api = await handlers(
            try environment(
                role: .dedicated,
                report: { _ in
                    XCTFail("The dedicated runtime account cannot ask the desktop app")
                    return [:]
                }))
        let state = try await call(api, "GetUpdateState", as: Micropod_V1_UpdateState.self)
        XCTAssertEqual(state.kind, .current)
        XCTAssertEqual(state.scope, "runtime")
        XCTAssertEqual(state.currentVersion, "0.14.0")

        let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
        let own = try component(.dedicatedAPI, in: ping.components)
        XCTAssertEqual(own.version, "0.14.0")
        XCTAssertEqual(own.state, "running")
        for name in [MicropodComponent.app, .connectAPI, .dockerShim, .sharedFS] {
            let other = try component(name, in: ping.components)
            XCTAssertEqual(other.state, "unknown", name.rawValue)
            XCTAssertEqual(other.version, "unknown", name.rawValue)
        }
    }

    func testDesktopPingInFrontOfDedicatedRuntimeTakesTheRuntimesOwnComponents() async throws {
        let upstream = Micropod_V1_PingResponse.with {
            $0.status = "running"
            $0.runtimeBackend = "native"
            $0.apiServerVersion = "1.5.0"
            $0.features = ["cap_add", RuntimeCoordinationEnrollment.dataCapability]
            $0.micropodVersion = "0.13.0"
            $0.protocolVersion = 1
            $0.components = [
                ComponentProbe.component(.dedicatedAPI, version: "0.13.0", state: .running),
                ComponentProbe.component(.kernel, version: "6.18.35-197", state: .installed),
                ComponentProbe.component(.app, version: "9.9.9", state: .running),
            ]
        }
        let body = try upstream.jsonUTF8Data()
        let api = await handlers(
            try environment(
                dedicated: true,
                upstream: { path, _, _ in
                    XCTAssertEqual(path, "/api/micropod.v1.SystemService/Ping")
                    return body
                }))
        let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
        XCTAssertEqual(ping.status, "running")
        XCTAssertEqual(ping.runtimeBackend, "native")
        XCTAssertEqual(ping.features, upstream.features)
        XCTAssertEqual(ping.micropodVersion, "0.14.0", "the Connect API answered")
        XCTAssertEqual(try component(.dedicatedAPI, in: ping.components).version, "0.13.0")
        XCTAssertEqual(try component(.kernel, in: ping.components).version, "6.18.35-197")
        XCTAssertEqual(try component(.app, in: ping.components).version, "0.13.6", "the desktop observes its own app")
        XCTAssertEqual(try component(.appleRuntime, in: ping.components).version, "1.5.0")
        XCTAssertEqual(try component(.vminit, in: ping.components).state, "unknown")
        XCTAssertEqual(ping.updateState.kind, .staged)
    }

    func testOlderDedicatedRuntimeAPILeavesItsComponentsUnknown() async throws {
        let body = try Micropod_V1_PingResponse.with {
            $0.status = "running"
            $0.runtimeBackend = "native"
            $0.apiServerVersion = "container-apiserver version 1.3.1 (build: release, commit: a9a62e2)"
        }.jsonUTF8Data()
        let api = await handlers(try environment(dedicated: true, upstream: { _, _, _ in body }))
        let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
        XCTAssertEqual(ping.protocolVersion, 0, "requests cross an API that predates the contract revision")
        let apple = try component(.appleRuntime, in: ping.components)
        XCTAssertEqual(apple.version, "1.3.1")
        XCTAssertEqual(apple.revision, "a9a62e2")
        for name in [MicropodComponent.dedicatedAPI, .kernel, .guest, .vminit] {
            XCTAssertEqual(try component(name, in: ping.components).version, "unknown", name.rawValue)
        }
    }

    func testDedicatedRuntimeUnavailableIsAnErrorUnlessMaintenanceHoldsIt() async throws {
        let environment = try environment(dedicated: true)
        let api = await handlers(environment)
        let request = HTTPRequest(
            method: .post, path: "/api/micropod.v1.SystemService/Ping", query: [:], body: Data("{}".utf8),
            headers: ["content-type": "application/json"])
        guard case .data(let code, _, _) = await api.handle(request) else { return XCTFail("missing response") }
        XCTAssertEqual(code, 503)

        let fence = try environment.runtimeAdmission().begin(operation: UUID())
        defer { withExtendedLifetime(fence) {} }
        let ping = try await call(api, "Ping", as: Micropod_V1_PingResponse.self)
        XCTAssertEqual(ping.status, "maintenance")
        XCTAssertEqual(ping.updateState.kind, .upgrading)
        XCTAssertEqual(ping.updateState.phase, "runtime-maintenance")
    }

    func testGetSystemInFrontOfDedicatedRuntimeHashesThisServersExecutable() async throws {
        let body = try Micropod_V1_SystemSnapshot.with {
            $0.status = Micropod_V1_SystemStatus.with {
                $0.status = "running"
                $0.apiServerVersion = "1.5.0"
            }
            $0.protocolVersion = 1
            $0.components = [ComponentProbe.component(.dedicatedAPI, version: "0.13.0", state: .running)]
        }.jsonUTF8Data()
        let environment = try environment(dedicated: true, upstream: { _, _, _ in body })
        let api = await handlers(environment)
        let snapshot = try await call(api, "GetSystem", as: Micropod_V1_SystemSnapshot.self)
        XCTAssertEqual(snapshot.status.appleApiServerVersion, "1.5.0")
        XCTAssertEqual(snapshot.micropodVersion, "0.14.0")
        XCTAssertEqual(snapshot.protocolVersion, 1)
        let connect = try component(.connectAPI, in: snapshot.components)
        XCTAssertEqual(connect.sha256, try UpdateServiceWitness.digest(environment.executable))
    }

    // MARK: - Components

    func testUnreadableComponentsAreUnknownNotGuessed() throws {
        // A kernel directory this account cannot search.
        let appRoot = root.appendingPathComponent("apple")
        let kernels = appRoot.appendingPathComponent("kernels")
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: kernels.appendingPathComponent("default.kernel-arm64").path,
            withDestinationPath: "vmlinux-6.18.35-197")
        try Data("kernel".utf8).write(to: kernels.appendingPathComponent("vmlinux-6.18.35-197"))
        XCTAssertEqual(ComponentProbe.kernel(appRoot: appRoot, digest: false).version, "6.18.35-197")
        XCTAssertEqual(chmod(kernels.path, 0), 0)
        let kernel = ComponentProbe.kernel(appRoot: appRoot, digest: true)
        XCTAssertEqual(kernel.state, "unknown")
        XCTAssertEqual(kernel.version, "unknown")
        XCTAssertEqual(kernel.sha256, "")
        XCTAssertTrue(kernel.detail.contains("not readable"), kernel.detail)

        // A setup app whose Info.plist cannot be read.
        let setup = root.appendingPathComponent("Setup.app")
        try writeBundle(setup, ["CFBundleShortVersionString": "0.14.0"], executable: "MicropodRuntimeHost")
        XCTAssertEqual(chmod(setup.appendingPathComponent("Contents/Info.plist").path, 0), 0)
        let helper = ComponentProbe.setupHelper(at: setup, running: nil, digest: false)
        XCTAssertEqual(helper.state, "unknown")
        XCTAssertEqual(helper.version, "unknown")

        // A retained service record that does not decode.
        let services = root.appendingPathComponent("services")
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: services.appendingPathComponent("docker-shim.json"))
        let shim = try XCTUnwrap(
            ComponentProbe.retainedService(
                .dockerShim, id: "docker-shim", servicesRoot: services, socket: root.appendingPathComponent("s").path,
                digest: false))
        XCTAssertEqual(shim.state, "unknown")
        XCTAssertEqual(shim.version, "unknown")

        XCTAssertEqual(ComponentProbe.vminit(reference: nil, unavailable: "not read").version, "unknown")
    }

    func testSetupAppPackagedBeforeStampingHasNoVersion() throws {
        let legacy = root.appendingPathComponent("Legacy.app")
        try writeBundle(legacy, ["CFBundleShortVersionString": "0.1.0"], executable: "MicropodRuntimeHost")
        let old = ComponentProbe.setupHelper(at: legacy, running: true, digest: false)
        XCTAssertEqual(old.version, "unknown")
        XCTAssertEqual(old.state, "running")
        XCTAssertTrue(old.detail.contains("placeholder"))

        let stamped = root.appendingPathComponent("Stamped.app")
        try writeBundle(
            stamped, ["CFBundleShortVersionString": "0.14.0", "MicropodSourceRevision": Self.revision],
            executable: "MicropodRuntimeHost")
        let current = ComponentProbe.setupHelper(at: stamped, running: false, digest: true)
        XCTAssertEqual(current.version, "0.14.0")
        XCTAssertEqual(current.revision, Self.revision)
        XCTAssertEqual(current.state, "stopped")
        XCTAssertEqual(
            current.sha256,
            try UpdateServiceWitness.digest(stamped.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")))
    }

    // R4: the fleet sees which rigs still depend on the legacy helper.
    func testTheRuntimeAuthorityIsMissingWhileTheDedicatedRuntimeUsesTheLegacyHelper() throws {
        let plist = root.appendingPathComponent("LaunchDaemons/authority.plist")
        let bundle = root.appendingPathComponent("authority/current/Micropod Runtime Setup.app")
        let legacy = root.appendingPathComponent("Applications/Micropod Runtime Setup.app")
        let program = bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost").path
        let legacyProgram = legacy.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost").path
        let published = root.appendingPathComponent("protection.json")
        func probe(_ helpers: [String], dedicated: Bool) -> Micropod_V1_ComponentVersion {
            ComponentProbe.runtimeAuthority(
                helpers: helpers, dedicated: dedicated, plist: plist, bundle: bundle, legacyBundle: legacy,
                protection: published, protectionOwner: getuid())
        }
        func publish(protected: Bool, legacyActive: Bool) throws {
            try JSONSerialization.data(withJSONObject: [
                "protected": protected, "legacyActive": legacyActive, "reason": protected ? NSNull() : "why",
                "checkedAt": 0,
            ]).write(to: published)
        }
        XCTAssertEqual(probe([], dedicated: false).state, "not_configured")
        let migrate = probe([legacyProgram], dedicated: true)
        XCTAssertEqual(migrate.name, "runtime-authority")
        XCTAssertEqual(migrate.state, "missing")
        XCTAssertTrue(migrate.detail.contains("install-authority` before 2027-04-01"), migrate.detail)
        XCTAssertEqual(probe([legacyProgram], dedicated: false).state, "missing", "a legacy helper alone")

        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: plist)
        try writeBundle(
            bundle, ["CFBundleShortVersionString": "0.14.0", "MicropodSourceRevision": Self.revision],
            executable: "MicropodRuntimeHost")
        XCTAssertEqual(probe([program], dedicated: true).state, "unknown", "no published protection check")
        try publish(protected: true, legacyActive: false)
        let serving = probe([program], dedicated: true)
        XCTAssertEqual(serving.state, "running")
        XCTAssertEqual(serving.version, "0.14.0")
        // F7: a failed protection check is its own state, and a legacy job
        // that is not retired is distinguished from any other failure.
        try publish(protected: false, legacyActive: true)
        let legacyActive = probe([program], dedicated: true)
        XCTAssertEqual(legacyActive.state, "legacy_active")
        XCTAssertTrue(legacyActive.detail.contains("not retired"), legacyActive.detail)
        try publish(protected: false, legacyActive: false)
        XCTAssertEqual(probe([program], dedicated: true).state, "unprotected")
        let blocked = probe([legacyProgram], dedicated: true)
        XCTAssertEqual(blocked.state, "stopped")
        XCTAssertTrue(blocked.detail.contains("run install-authority again"), blocked.detail)
    }

    func testRetainedServiceReportsItsPayloadReleaseNotTheDesktops() throws {
        let payload = root.appendingPathComponent("payloads/0.13.0-abc/Micropod.app")
        try writeBundle(
            payload, ["CFBundleShortVersionString": "0.13.0", "MicropodSourceRevision": Self.revision],
            executable: "micropod-docker-shim")
        let executable = payload.appendingPathComponent("Contents/MacOS/micropod-docker-shim")
        let services = root.appendingPathComponent("services")
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "schema": 1, "sourceVersion": "0.13.0", "executable": executable.path,
            "identifier": "com.skunkworq.micropod.docker-shim", "sha256": "recorded", "arguments": [],
            "environment": [:],
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: services.appendingPathComponent("docker-shim.json"))
        let shim = try XCTUnwrap(
            ComponentProbe.retainedService(
                .dockerShim, id: "docker-shim", servicesRoot: services,
                socket: root.appendingPathComponent("docker.sock").path, digest: true))
        XCTAssertEqual(shim.version, "0.13.0")
        XCTAssertEqual(shim.revision, Self.revision)
        XCTAssertEqual(shim.state, "stopped")
        XCTAssertEqual(shim.sha256, try UpdateServiceWitness.digest(executable))
        XCTAssertTrue(shim.detail.contains("differs from its recorded sha256"), shim.detail)
    }

    func testAppleReleaseParsesBannerAndBareVersions() {
        let banner = ComponentProbe.appleRelease("container-apiserver version 1.3.1 (build: release, commit: a9a62e2)")
        XCTAssertEqual(banner.version, "1.3.1")
        XCTAssertEqual(banner.revision, "a9a62e2")
        let bare = ComponentProbe.appleRelease("1.5.0")
        XCTAssertEqual(bare.version, "1.5.0")
        XCTAssertEqual(bare.revision, "unknown")
        XCTAssertEqual(ComponentProbe.appleRelease("").version, "unknown")
    }

    func testPeerProtocolMatchesTheCoordinationCapability() {
        XCTAssertEqual(
            RuntimeCoordinationEnrollment.capability,
            MicropodProtocol.peerProtocolName + "-v\(MicropodProtocol.peerProtocolMaximum)")
    }

    // MARK: - Typed update status

    func testUpdateStatusKeepsTheBlockerOutOfErrorAndCarriesTheTransaction() async throws {
        let api = await handlers(try environment())
        let operation = UUID().uuidString
        let status = api.updateStatus(from: [
            "state": "updateAvailable", "feedConfigured": true, "currentVersion": "0.13.3",
            "availableVersion": "0.13.7", "restartGuard": "idle", "channel": "stable", "workloadProtocol": 1,
            "payloadCompatible": false,
            "restartBlockedReason": "This release has no compatible signed desktop payload.",
            "currentSourceRevision": "4b1d4906cda28c05a452619149b49fd6f31a72c1", "desktopAdmission": "open",
            "transaction": [
                "operation": operation, "phase": "aborted", "sourceVersion": "0.13.3", "targetVersion": "0.13.5",
                "updatedAt": 784_000_000.0,
            ],
        ])
        XCTAssertEqual(status.state, .updateAvailable)
        XCTAssertEqual(status.error, "")
        XCTAssertEqual(status.restartBlockedReason, "This release has no compatible signed desktop payload.")
        XCTAssertEqual(status.restartGuard, "idle")
        XCTAssertEqual(status.channel, "stable")
        XCTAssertEqual(status.workloadProtocol, 1)
        XCTAssertFalse(status.payloadCompatible)
        XCTAssertEqual(status.desktopAdmission, "open")
        XCTAssertEqual(status.transaction.operationID, operation)
        XCTAssertEqual(status.transaction.phase, "aborted")
        XCTAssertEqual(status.transaction.targetVersion, "0.13.5")
        XCTAssertFalse(status.transaction.updatedAt.isEmpty)
        XCTAssertEqual(status.updateState.kind, .blocked)
        XCTAssertEqual(status.updateState.targetVersion, "0.13.7")
        XCTAssertEqual(status.updateState.reason, status.restartBlockedReason)
    }

    func testRejectedDownloadStatusIsRolledBackNotUpToDate() async throws {
        let api = await handlers(try environment())
        let reason = "No installable update remained after preparation"
        for phase in ["downloadRejected", "aborted"] {
            let status = api.updateStatus(from: [
                "state": "upToDate", "currentVersion": "0.13.6", "restartGuard": "idle",
                "transaction": [
                    "operation": UUID().uuidString, "phase": phase, "sourceVersion": "0.13.6",
                    "targetVersion": "0.13.7", "detail": reason,
                ],
            ])
            XCTAssertEqual(status.updateState.kind, .rolledBack, phase)
            XCTAssertEqual(status.updateState.reason, reason, phase)
            XCTAssertEqual(status.updateState.targetVersion, "0.13.7", phase)
            XCTAssertEqual(status.updateState.currentVersion, "0.13.6", phase)
            XCTAssertEqual(status.updateState.availableVersion, "", phase)
        }
        // Once the target is what runs, the aborted receipt is history.
        let settled = api.updateStatus(from: [
            "state": "upToDate", "currentVersion": "0.13.7",
            "transaction": ["phase": "aborted", "targetVersion": "0.13.7"],
        ])
        XCTAssertEqual(settled.updateState.kind, .current)
    }
}

/// A thread-safe call count.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A thread-safe boolean.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(_ value: Bool) { current = value }

    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
