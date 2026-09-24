import Foundation
import MicropodCore

/// Backend selection: direct `container-apiserver` XPC calls vs the
/// `container` CLI subprocess.
public enum RuntimeBackendKind: String, Sendable {
    /// One persistent XPC connection; each op is a single round trip.
    case native
    /// Per-call `container` process spawns (the historic path).
    case cli
}

/// The resolved set of runtime-facing services.
public struct RuntimeServices: Sendable {
    public let kind: RuntimeBackendKind
    public let containers: any ContainerServing
    public let logs: any LogStreaming
    public let stats: any StatsSampling
    /// Present when the native backend is active — the XPC client for
    /// guest/vsock consumers (vminitd, the API bridge endpoint).
    public let api: APIServerClient?
    /// Apiserver identity from the `ping` handshake, when known.
    public let health: APIServerHealth?

    /// True when the apiserver reported a version we've verified the
    /// protocol against. Unknown versions still work when the route set is
    /// additive, but callers may choose to be conservative.
    public var versionSupported: Bool {
        guard let health, let version = health.semver else { return false }
        return Self.supportedVersions.contains(version) || version.hasPrefix("1.3.")
    }

    /// Versions the wire protocol was verified against.
    public static let supportedVersions: Set<String> = ["1.3.1"]
}

/// Resolves `RuntimeServices` from the environment.
///
/// `MICROPOD_RUNTIME`:
///   - `cli`    → force the CLI backend (also used by the mock-CLI tests)
///   - `native` → force native, fail if the apiserver is unreachable
///   - unset/`auto` → native when the `ping` handshake succeeds, else CLI
public enum RuntimeBackendResolver {
    public static func resolve(
        client: ContainerCLIClient,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> RuntimeServices {
        let mode = environment["MICROPOD_RUNTIME"] ?? "auto"
        let cliContainers = ContainerService(client: client)
        let cliLogs = LogStreamer(client: client)
        let cliStats = StatsSampler(client: client)

        func cliServices(health: APIServerHealth? = nil) -> RuntimeServices {
            RuntimeServices(
                kind: .cli,
                containers: cliContainers,
                logs: cliLogs,
                stats: cliStats,
                api: nil,
                health: health
            )
        }

        guard mode != "cli" else { return cliServices() }

        // An explicit CLI path means the caller deliberately chose a
        // container binary (mock CLIs in tests, custom installs) — auto
        // mode must not silently bypass it for the native path. Only an
        // explicit MICROPOD_RUNTIME=native overrides that choice.
        if mode == "auto", environment["MICROPOD_CONTAINER_CLI_PATH"] != nil {
            return cliServices()
        }

        let api = APIServerClient()
        do {
            let health = try await api.ping(timeout: .seconds(10))
            let services = RuntimeServices(
                kind: .native,
                containers: NativeContainerService(api: api, cli: cliContainers),
                logs: NativeLogStreamer(api: api),
                stats: NativeStatsSampler(api: api),
                api: api,
                health: health
            )
            guard services.versionSupported else {
                // The wire DTOs are versioned by us, not on the wire — an
                // unverified apiserver version is a correctness risk, so
                // auto stays on CLI. Explicit `native` is an opt-in and
                // proceeds with a warning.
                if mode == "native" {
                    let notice =
                        "micropod: apiserver version \(health.apiServerVersion) is unverified "
                        + "(supported: \(RuntimeServices.supportedVersions.sorted().joined(separator: ", ")) or 1.3.x); proceeding anyway\n"
                    FileHandle.standardError.write(Data(notice.utf8))
                    return services
                }
                return cliServices(health: health)
            }
            return services
        } catch {
            if mode == "native" {
                let notice =
                    "micropod: MICROPOD_RUNTIME=native but apiserver ping failed "
                    + "(\(error.localizedDescription)); falling back to CLI\n"
                FileHandle.standardError.write(Data(notice.utf8))
            }
            return cliServices()
        }
    }
}
