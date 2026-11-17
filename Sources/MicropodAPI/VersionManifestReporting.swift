import Foundation
import MicropodBuildInfo
import MicropodCore
import MicropodRuntime
import SwiftProtobuf

/// Which API server is answering.
enum APIServerRole: Sendable, Equatable {
    /// The desktop account's Connect API on loopback.
    case connect
    /// The dedicated runtime account's API (`MICROPOD_ISOLATED_RUNTIME=1`).
    case dedicated

    static var current: APIServerRole {
        ProcessInfo.processInfo.environment["MICROPOD_ISOLATED_RUNTIME"] == "1" ? .dedicated : .connect
    }
}

/// Everything the version manifest reads, injectable for tests.
struct VersionEnvironment: Sendable {
    var role: APIServerRole
    var build: ComponentProbe.Stamp
    /// This server's executable (its siblings ship with the same build).
    var executable: URL
    /// The account's home: `~/.micropod/services` and the default sockets.
    var home: URL
    var setupApp: URL
    var dockerShimSocket: String
    var sharedFSSocket: String
    /// The admission gate runtime maintenance closes, as this server sees it.
    var runtimeAdmission: @Sendable () -> RuntimeAdmission
    /// Whether this account reaches its runtime through a dedicated runtime.
    var usesDedicatedRuntime: @Sendable () -> Bool
    /// The desktop app's `update.status` report, within `timeout` seconds.
    var desktopReport: @Sendable (_ timeout: TimeInterval) async throws -> [String: Any]
    var desktopReachable: @Sendable () -> Bool
    /// One authenticated request to the dedicated runtime API.
    var dedicatedRequest: @Sendable (_ path: String, _ body: Data, _ timeout: Duration) async throws -> Data
    /// A disruptive rig upgrade's state from this account's journal, if any.
    var rigUpgrade: @Sendable () -> Micropod_V1_UpdateState? = { nil }

    static func live(client: ContainerCLIClient) -> VersionEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let executable =
            Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "MicropodAPI")
        return VersionEnvironment(
            role: .current,
            build: .init(version: MicropodBuildInfo.version, revision: MicropodBuildInfo.sourceRevision),
            executable: executable,
            home: home,
            setupApp: RuntimeSetupInstallation.installedURL,
            dockerShimSocket: environment["MICROPOD_SHIM_SOCKET"]
                ?? home.appendingPathComponent(".micropod/docker.sock").path,
            sharedFSSocket: environment["MICROPOD_SHAREDFS_SOCKET"]
                ?? home.appendingPathComponent("micropod/share-cache/socket").path,
            runtimeAdmission: {
                client.usesIsolatedTransport
                    ? RuntimeAdmission(root: IsolatedRuntimePolicy.admissionRoot) : RuntimeAdmission.shared
            },
            usesDedicatedRuntime: { client.usesIsolatedTransport },
            desktopReport: { timeout in try await AppControlClient(requestTimeout: timeout).updateStatus() },
            desktopReachable: { AppControlClient().isReachable },
            dedicatedRequest: { path, body, timeout in
                try await IsolatedRuntimeTransport.shared.request(path: path, body: body, timeout: timeout)
            },
            rigUpgrade: { UpdateStateResolver.rig(layout: RigUpgradeLayout(home: home)) })
    }
}

/// The version manifest fields Ping and GetSystem share.
struct VersionManifest: Sendable {
    var micropodVersion: String
    var sourceRevision: String
    var protocolVersion: UInt32
    var peerProtocol: Micropod_V1_ProtocolRange
    var components: [Micropod_V1_ComponentVersion]
    var updateState: Micropod_V1_UpdateState

    func apply(to ping: inout Micropod_V1_PingResponse) {
        ping.micropodVersion = micropodVersion
        ping.sourceRevision = sourceRevision
        ping.protocolVersion = protocolVersion
        ping.peerProtocol = peerProtocol
        ping.components = components
        ping.updateState = updateState
        ping.appleApiServerVersion = ping.apiServerVersion
    }

    func apply(to snapshot: inout Micropod_V1_SystemSnapshot) {
        snapshot.micropodVersion = micropodVersion
        snapshot.sourceRevision = sourceRevision
        snapshot.protocolVersion = protocolVersion
        snapshot.peerProtocol = peerProtocol
        snapshot.components = components
        snapshot.updateState = updateState
        if snapshot.hasStatus { snapshot.status.appleApiServerVersion = snapshot.status.apiServerVersion }
    }

    /// Components the dedicated runtime observes for itself. In front of a
    /// dedicated runtime, the desktop's Connect API takes these from it.
    static let runtimeOwned: Set<String> = [
        MicropodComponent.dedicatedAPI, .appleRuntime, .vminit, .guest, .kernel,
    ].reduce(into: []) { $0.insert($1.rawValue) }

    /// This (desktop) server's manifest in front of the dedicated runtime
    /// API's answer. The runtime's own components come from it; an older
    /// API that sent none leaves them "unknown" rather than guessed.
    func merging(
        dedicated components: [Micropod_V1_ComponentVersion], protocolVersion upstream: UInt32,
        peerProtocol: Micropod_V1_ProtocolRange?, appleReported: String
    ) -> VersionManifest {
        var merged = self
        let remote = Dictionary(components.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        merged.components = MicropodComponent.allCases.map { name in
            guard Self.runtimeOwned.contains(name.rawValue) else {
                return self.components.first { $0.name == name.rawValue }
                    ?? ComponentProbe.component(name, state: .unknown)
            }
            if let reported = remote[name.rawValue] { return reported }
            if name == .appleRuntime, !appleReported.isEmpty {
                let release = ComponentProbe.appleRelease(appleReported)
                return ComponentProbe.component(
                    .appleRuntime, version: release.version, revision: release.revision, state: .running,
                    detail: "reported by the dedicated runtime API")
            }
            return ComponentProbe.component(
                name, state: .unknown, detail: "The dedicated runtime API predates the version manifest")
        }
        // Requests cross both servers: promise only what both implement.
        merged.protocolVersion = min(self.protocolVersion, upstream)
        if let peerProtocol, !peerProtocol.name.isEmpty { merged.peerProtocol = peerProtocol }
        return merged
    }
}

/// What the desktop app said about itself and its updater.
struct DesktopObservation: Sendable {
    var app: Micropod_V1_ComponentVersion
    var updateState: Micropod_V1_UpdateState

    init(report: [String: Any]) {
        let version = report["currentVersion"] as? String ?? ""
        let revision = report["currentSourceRevision"] as? String ?? ""
        app = ComponentProbe.component(
            .app, version: version, revision: revision, state: .running, detail: "reported by the running app")
        updateState = UpdateStateResolver.desktop(report: report)
    }

    init(unavailable reason: String, appState: ComponentState) {
        app = ComponentProbe.component(.app, state: appState, detail: reason)
        updateState = UpdateStateResolver.unobservable(
            scope: UpdateStateResolver.desktopScope, reason: reason)
    }
}

/// Asks the desktop app for its update report at most once per `maxAge`,
/// so Ping stays cheap while health ticks arrive every few seconds.
final class DesktopObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (observation: DesktopObservation, at: ContinuousClock.Instant)?

    func observe(_ environment: VersionEnvironment, maxAge: Duration, timeout: TimeInterval) async
        -> DesktopObservation
    {
        let now = ContinuousClock.now
        if let hit = lock.withLock({ cached }), now - hit.at < maxAge { return hit.observation }
        let observation: DesktopObservation
        if !environment.desktopReachable() {
            observation = DesktopObservation(
                unavailable: "The desktop app is not running, so its updater cannot be observed",
                appState: .stopped)
        } else {
            do {
                observation = DesktopObservation(report: try await environment.desktopReport(timeout))
            } catch {
                observation = DesktopObservation(
                    unavailable: "The desktop app did not report its updater: \(error.localizedDescription)",
                    appState: .unknown)
            }
        }
        lock.withLock { cached = (observation, ContinuousClock.now) }
        return observation
    }
}

/// What this request learned about Apple's runtime.
struct AppleObservation: Sendable {
    /// Version as the apiserver reported it (banner or bare release).
    var reported: String
    var commit: String = ""
    var state: ComponentState
    var appRoot: URL?
    var installRoot: String?
    var detail: String = ""
}

extension APIHandlers {
    /// The version manifest this server can observe. `digests` (GetSystem)
    /// also hashes executables and checks the root helper is running.
    func versionManifest(apple: AppleObservation, digests: Bool, desktopAge: Duration = .seconds(2)) async
        -> VersionManifest
    {
        let environment = versionEnvironment
        let build = environment.build
        var found: [MicropodComponent: Micropod_V1_ComponentVersion] = [:]
        let notObservable = "Not observable from the dedicated runtime account"
        let selfComponent = ComponentProbe.component(
            environment.role == .connect ? .connectAPI : .dedicatedAPI, version: build.version,
            revision: build.revision,
            sha256: digests ? (ComponentProbe.sha256(environment.executable) ?? "") : "", state: .running,
            detail: environment.executable.path)
        var desktopState: Micropod_V1_UpdateState?
        switch environment.role {
        case .connect:
            let observed = await desktopObserver.observe(
                environment, maxAge: desktopAge, timeout: digests ? 2 : 0.5)
            desktopState = observed.updateState
            found[.app] = observed.app
            found[.connectAPI] = selfComponent
            found[.dedicatedAPI] =
                environment.usesDedicatedRuntime()
                ? ComponentProbe.component(
                    .dedicatedAPI, state: .unknown, detail: "Reported by the dedicated runtime API")
                : ComponentProbe.component(
                    .dedicatedAPI, state: .notConfigured, detail: "No dedicated runtime is configured for this account")
            let services = environment.home.appendingPathComponent(".micropod/services")
            for (name, id, binary, socket) in [
                (MicropodComponent.dockerShim, "docker-shim", "micropod-docker-shim", environment.dockerShimSocket),
                (MicropodComponent.sharedFS, "shared-fs", "micropod-sharedfs", environment.sharedFSSocket),
            ] {
                found[name] =
                    ComponentProbe.retainedService(
                        name, id: id, servicesRoot: services, socket: socket, digest: digests)
                    ?? ComponentProbe.bundledService(
                        name, binary: binary, besides: environment.executable, build: build, socket: socket,
                        digest: digests)
            }
        case .dedicated:
            found[.app] = ComponentProbe.component(.app, state: .unknown, detail: notObservable)
            found[.connectAPI] = ComponentProbe.component(.connectAPI, state: .unknown, detail: notObservable)
            found[.dedicatedAPI] = selfComponent
            found[.dockerShim] = ComponentProbe.component(.dockerShim, state: .unknown, detail: notObservable)
            found[.sharedFS] = ComponentProbe.component(.sharedFS, state: .unknown, detail: notObservable)
        }
        let helperRunning = digests ? (try? RuntimeSetupInstallation.helperIsRunning()) : nil
        found[.setupHelper] = ComponentProbe.setupHelper(
            at: environment.setupApp, running: helperRunning, digest: digests)
        if environment.role == .connect, environment.usesDedicatedRuntime() {
            // The dedicated runtime reports these itself (VersionManifest.merging);
            // this account's legacy runtime files say nothing about it.
            for name in [MicropodComponent.appleRuntime, .vminit, .guest, .kernel] {
                found[name] = ComponentProbe.component(
                    name, state: .unknown, detail: "Reported by the dedicated runtime API")
            }
        } else {
            found[.appleRuntime] = appleComponent(apple, digest: digests)
            found[.vminit] = await vminitComponent(fresh: digests)
            found[.guest] = ComponentProbe.guest(besides: environment.executable, build: build, digest: digests)
            found[.kernel] = ComponentProbe.kernel(
                appRoot: apple.appRoot
                    ?? environment.home.appendingPathComponent("Library/Application Support/com.apple.container"),
                digest: digests)
        }

        let runtimeState = UpdateStateResolver.runtime(
            admission: environment.runtimeAdmission(),
            currentVersion: environment.role == .dedicated ? build.version : ComponentProbe.unknown)
        return VersionManifest(
            micropodVersion: build.version, sourceRevision: build.revision,
            protocolVersion: MicropodProtocol.apiVersion, peerProtocol: MicropodProtocol.peerProtocol,
            components: MicropodComponent.allCases.compactMap { found[$0] },
            updateState: desktopState.map {
                UpdateStateResolver.combined(desktop: $0, runtime: runtimeState, rig: environment.rigUpgrade())
            } ?? runtimeState)
    }

    /// GetUpdateState: the desktop answers for both updaters; the dedicated
    /// runtime API answers for runtime maintenance only.
    func currentUpdateState() async -> Micropod_V1_UpdateState {
        let environment = versionEnvironment
        let runtimeState = UpdateStateResolver.runtime(
            admission: environment.runtimeAdmission(),
            currentVersion: environment.role == .dedicated ? environment.build.version : ComponentProbe.unknown)
        guard environment.role == .connect else { return runtimeState }
        let desktop = await desktopObserver.observe(environment, maxAge: .zero, timeout: 2)
        return UpdateStateResolver.combined(
            desktop: desktop.updateState, runtime: runtimeState, rig: environment.rigUpgrade())
    }

    private func appleComponent(_ apple: AppleObservation, digest: Bool) -> Micropod_V1_ComponentVersion {
        guard !apple.reported.isEmpty else {
            return ComponentProbe.component(
                .appleRuntime, state: apple.state == .running ? .unknown : apple.state,
                detail: apple.detail.isEmpty ? "The runtime did not report its version" : apple.detail)
        }
        let release = ComponentProbe.appleRelease(apple.reported)
        var hash = ""
        if digest, let root = apple.installRoot, !root.isEmpty {
            hash =
                ComponentProbe.sha256(URL(fileURLWithPath: root).appendingPathComponent("bin/container-apiserver"))
                ?? ""
        }
        return ComponentProbe.component(
            .appleRuntime, version: release.version,
            revision: apple.commit.isEmpty ? release.revision : apple.commit, sha256: hash, state: apple.state,
            detail: apple.detail.isEmpty ? apple.reported : apple.detail)
    }

    /// The `vminit.image` property. Ping uses the kept value and refreshes it
    /// in the background; GetSystem reads it.
    private func vminitComponent(fresh: Bool) async -> Micropod_V1_ComponentVersion {
        if fresh {
            return ComponentProbe.vminit(
                reference: await initImage.value(), unavailable: "The runtime did not report vminit.image")
        }
        if let kept = await initImage.peek() {
            return ComponentProbe.vminit(reference: kept, unavailable: "")
        }
        let initImage = self.initImage
        Task { _ = await initImage.value() }
        return ComponentProbe.vminit(reference: nil, unavailable: "Not read yet; GetSystem reads vminit.image")
    }

    /// One SystemService call answered by the dedicated runtime API.
    func dedicatedSystemCall<M: Message>(_ method: String, as type: M.Type, timeout: Duration) async throws -> M {
        let data = try await versionEnvironment.dedicatedRequest(
            "/api/micropod.v1.SystemService/" + method, Data("{}".utf8), timeout)
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        return try M(jsonUTF8Data: data, options: options)
    }
}
