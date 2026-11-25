import Foundation
import MicropodCore

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
        }
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

    public init(layout: HVFMachineLayout, config: HVFMachineConfig, engine: Engine?) {
        buildkitMissing = layout.missingBuildKitFiles()
        buildkit = buildkitMissing.isEmpty
        self.engine = engine
        publishedPath = Self.publishedPath(config)
    }

    static func publishedPath(_ config: HVFMachineConfig) -> String {
        guard config.publishedNet else { return "off" }
        let prefix = "mp.published_path="
        let chosen = config.kernelArguments.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        return chosen.flatMap { $0.isEmpty ? nil : $0 } ?? "macvlan"
    }

    enum CodingKeys: String, CodingKey { case buildkit, buildkitMissing, engine, publishedPath }

    /// `engine` is always present, `null` when unknown.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(buildkit, forKey: .buildkit)
        try c.encode(buildkitMissing, forKey: .buildkitMissing)
        try c.encode(engine, forKey: .engine)
        try c.encode(publishedPath, forKey: .publishedPath)
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

    /// The machine's capabilities; an unreadable machine.json reads as the
    /// defaults (status reports the configuration problem itself).
    public func capabilities() async -> HVFMachineCapabilities {
        let config = (try? HVFMachineConfig.load(from: layout.config)) ?? HVFMachineConfig()
        return HVFMachineCapabilities(layout: layout, config: config, engine: await engineVersion())
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
