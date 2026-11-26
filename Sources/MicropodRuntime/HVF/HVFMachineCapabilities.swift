import Foundation
import MicropodCore

/// `runner/manifest.json` in a guest tool bundle, written by
/// `ci/build-runner-tools.sh`: which engine it carries and what that engine
/// serves. A bundle without one predates caches and `/grpc` builds.
///
/// ```json
/// {"engineCommit": "<git rev-parse HEAD>", "cacheApi": 1,
///  "buildkit": "<buildkitd --version>", "capabilities": ["caches", "buildkit", "grpc-build"]}
/// ```
public struct HVFToolsManifest: Codable, Sendable, Equatable {
    /// Relative to the bundle root.
    public static let path = "runner/manifest.json"

    public var engineCommit: String?
    public var cacheApi: Int?
    public var buildkit: String?
    public var capabilities: [String]

    public init(engineCommit: String? = nil, cacheApi: Int? = nil, buildkit: String? = nil, capabilities: [String] = [])
    {
        self.engineCommit = engineCommit
        self.cacheApi = cacheApi
        self.buildkit = buildkit
        self.capabilities = capabilities
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineCommit = try c.decodeIfPresent(String.self, forKey: .engineCommit)
        cacheApi = try c.decodeIfPresent(Int.self, forKey: .cacheApi)
        buildkit = try c.decodeIfPresent(String.self, forKey: .buildkit)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    /// nil when the bundle has none, or an unreadable one.
    public static func load(bundle: URL) -> HVFToolsManifest? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(path)) else { return nil }
        return try? JSONDecoder().decode(HVFToolsManifest.self, from: data)
    }

    /// The engine attaches dependency caches (cache API 1 or later).
    public var caches: Bool { capabilities.contains("caches") && (cacheApi ?? 0) >= 1 }
    /// The engine serves `docker build` on its Docker socket (`/grpc` + `/session`).
    public var grpcBuild: Bool { capabilities.contains("grpc-build") }
}

/// What the installed hvf machine offers beyond running containers, so
/// callers (and the app) can gate features on it: `machine status --json`
/// reports it as `capabilities`.
public struct HVFMachineCapabilities: Codable, Sendable, Equatable {
    /// The guest engine's `/version`.
    public struct Engine: Codable, Sendable, Equatable {
        public var version: String
        /// The newest Docker API version it serves.
        public var apiVersion: String
        /// The oldest one (`MinAPIVersion`; "1.0" when it names none).
        public var minAPIVersion: String
        public var os: String?
        public var arch: String?
        /// `GitCommit`: the commit the engine was built from, when it says
        /// (an engine built without one reports "unknown").
        public var gitCommit: String?
        /// `MicropodCapabilities` ("caches", "buildkit", "grpc-build").
        public var capabilities: [String]?

        /// nil when the reply names no `ApiVersion`.
        public init?(version data: Data) {
            guard let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let api = info["ApiVersion"] as? String, !api.isEmpty
            else { return nil }
            version = info["Version"] as? String ?? ""
            apiVersion = api
            minAPIVersion = info["MinAPIVersion"] as? String ?? "1.0"
            os = info["Os"] as? String
            arch = info["Arch"] as? String
            gitCommit = (info["GitCommit"] as? String).flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
            capabilities = info["MicropodCapabilities"] as? [String]
        }
    }

    /// How stock `docker build` reaches BuildKit on this machine.
    public enum DockerBuild: String, Codable, Sendable, Equatable {
        /// Through the Docker socket: buildx's docker driver works as is.
        case ready
        /// Only through a remote buildx builder on `run/buildkit.sock`
        /// (`micropod machine builder install`).
        case fallback
        /// The tool bundle has no BuildKit.
        case unavailable
    }

    /// The installed tool bundle ships BuildKit (`HVFMachineLayout.buildkitBundleFiles`).
    public var buildkit: Bool
    /// The bundle files BuildKit still needs; empty when `buildkit`.
    public var buildkitMissing: [String]
    /// The engine's API range, read live; nil while the machine is not
    /// running (nothing is booted to find out).
    public var engine: Engine?
    /// How published ports reach containers, from machine.json: "off"
    /// without `publishedNet`; else the last `mp.published_path=` kernel
    /// argument ("macvlan", "bridge", or "default": the engine's own
    /// choice); else "macvlan", guest init's default.
    public var publishedPath: String
    /// The engine attaches dependency caches: the bundle manifest says so
    /// (or, while running, the engine's own `/version`). A bundle without a
    /// manifest has none.
    public var caches: Bool
    /// `docker build` works through the Docker socket: while running, the
    /// live `POST /grpc` (`Upgrade: h2c`) probe got 101, the same probe
    /// buildx makes; while stopped, the bundle manifest says so.
    public var grpcBuild: Bool
    /// The `/grpc` probe's HTTP status; nil when the machine was not probed.
    public var grpcProbeStatus: Int?
    /// `engineCommit` from the bundle manifest.
    public var engineCommit: String?
    /// `cacheApi` from the bundle manifest.
    public var cacheApi: Int?
    public var dockerBuild: DockerBuild

    public init(layout: HVFMachineLayout, config: HVFMachineConfig, engine: Engine?, grpcProbeStatus: Int? = nil) {
        buildkitMissing = layout.missingBuildKitFiles()
        buildkit = buildkitMissing.isEmpty
        self.engine = engine
        publishedPath = Self.publishedPath(config)
        let manifest = HVFToolsManifest.load(bundle: layout.tools)
        engineCommit = manifest?.engineCommit
        cacheApi = manifest?.cacheApi
        caches = manifest?.caches == true || engine?.capabilities?.contains("caches") == true
        self.grpcProbeStatus = grpcProbeStatus
        if let grpcProbeStatus {
            grpcBuild = buildkit && grpcProbeStatus == 101
        } else {
            grpcBuild = buildkit && manifest?.grpcBuild == true
        }
        dockerBuild = grpcBuild ? .ready : buildkit ? .fallback : .unavailable
    }

    static func publishedPath(_ config: HVFMachineConfig) -> String {
        guard config.publishedNet else { return "off" }
        let prefix = "mp.published_path="
        let chosen = config.kernelArguments.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        return chosen.flatMap { $0.isEmpty ? nil : $0 } ?? "macvlan"
    }

    /// The bundle's commit agrees with the running engine's; nil when
    /// either does not say.
    public var engineCommitMatches: Bool? {
        guard let engineCommit, let live = engine?.gitCommit else { return nil }
        return engineCommit == live
    }

    enum CodingKeys: String, CodingKey {
        case buildkit, buildkitMissing, engine, publishedPath, caches, grpcBuild, grpcProbeStatus, engineCommit
        case cacheApi, dockerBuild, engineCommitMatches
    }

    /// `engine`, `engineCommit` and `grpcProbeStatus` are always present,
    /// `null` when unknown.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(buildkit, forKey: .buildkit)
        try c.encode(buildkitMissing, forKey: .buildkitMissing)
        try c.encode(engine, forKey: .engine)
        try c.encode(publishedPath, forKey: .publishedPath)
        try c.encode(caches, forKey: .caches)
        try c.encode(grpcBuild, forKey: .grpcBuild)
        try c.encode(grpcProbeStatus, forKey: .grpcProbeStatus)
        try c.encode(engineCommit, forKey: .engineCommit)
        try c.encode(cacheApi, forKey: .cacheApi)
        try c.encode(dockerBuild, forKey: .dockerBuild)
        try c.encode(engineCommitMatches, forKey: .engineCommitMatches)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buildkit = try c.decode(Bool.self, forKey: .buildkit)
        buildkitMissing = try c.decodeIfPresent([String].self, forKey: .buildkitMissing) ?? []
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine)
        publishedPath = try c.decodeIfPresent(String.self, forKey: .publishedPath) ?? "macvlan"
        caches = try c.decodeIfPresent(Bool.self, forKey: .caches) ?? false
        grpcBuild = try c.decodeIfPresent(Bool.self, forKey: .grpcBuild) ?? false
        grpcProbeStatus = try c.decodeIfPresent(Int.self, forKey: .grpcProbeStatus)
        engineCommit = try c.decodeIfPresent(String.self, forKey: .engineCommit)
        cacheApi = try c.decodeIfPresent(Int.self, forKey: .cacheApi)
        dockerBuild =
            try c.decodeIfPresent(DockerBuild.self, forKey: .dockerBuild)
            ?? (grpcBuild ? .ready : buildkit ? .fallback : .unavailable)
    }
}

extension HVFMachineClient {
    /// The guest engine's `/version` while the machine serves; nil when it
    /// is not running or does not answer. Never boots it.
    public func engineVersion(timeout: Duration = .seconds(2)) async -> HVFMachineCapabilities.Engine? {
        guard isServing, let response = try? await docker.request("GET", "/version", timeout: timeout),
            response.status == 200
        else { return nil }
        return HVFMachineCapabilities.Engine(version: response.body)
    }

    /// buildx's docker-driver probe: `POST /grpc` asking to upgrade to h2c.
    /// 101 means the engine serves `docker build` on its socket; an older
    /// engine answers 501, one without BuildKit 503. nil when the machine is
    /// not serving or the socket fails. Never boots it.
    public func grpcBuildProbe(timeout: Duration = .seconds(3)) async -> Int? {
        guard isServing else { return nil }
        return try? await docker.upgradeStatus("POST", "/grpc", protocol: "h2c", timeout: timeout)
    }

    /// The machine's capabilities; an unreadable machine.json reads as the
    /// defaults (status reports the configuration problem itself).
    public func capabilities() async -> HVFMachineCapabilities {
        let config = (try? HVFMachineConfig.load(from: layout.config)) ?? HVFMachineConfig()
        async let engine = engineVersion()
        async let probe = grpcBuildProbe()
        return HVFMachineCapabilities(
            layout: layout, config: config, engine: await engine, grpcProbeStatus: await probe)
    }

    /// `unix://…/run/buildkit.sock`, or why there is none: the installed
    /// tool bundle has no BuildKit.
    public func buildkitEndpoint() throws -> String {
        guard layout.missingAssets().isEmpty else {
            throw MicropodError.message(
                "failedPrecondition: hvf machine not installed under \(layout.root.path); run `micropod machine install`"
            )
        }
        let missing = layout.missingBuildKitFiles()
        guard missing.isEmpty else {
            throw MicropodError.message(
                "failedPrecondition: the guest tool bundle installed in \(layout.tools.path) has no BuildKit "
                    + "(missing \(missing.joined(separator: ", "))); install a bundle built with it: "
                    + "`micropod machine install --tools <dir>`")
        }
        return layout.buildkitEndpoint
    }
}
