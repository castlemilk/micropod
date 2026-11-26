import Foundation
import MicropodCore

/// The host loopback TCP ports a guest may reach through the gateway
/// (`10.42.0.1:<port>`, `host.micropod.internal:<port>`): micropod-vmm's
/// `--allow-host-port` list.
///
/// micropod-vmm forwards an allowed flow to `127.0.0.1:<port>`, so every
/// container in the machine, whatever its trust tier, reaches an opened
/// port as a local client. The list is therefore built only from what the
/// machine's owner configured, never from a URL alone:
///
/// - `HVFMachineConfig.allowHostPorts`, as written (validation refuses the
///   control ports, see `controlPorts`);
/// - `HVFMachineConfig.depproxyPort` (7677, the rig dependency proxy), and
///   only while the cache policy's `goProxy` or `npmRegistry` names it at
///   the gateway.
///
/// A policy URL that names any other gateway port opens nothing. It is
/// listed in `refused`, shown by `machine status`, logged by the supervisor
/// and returned as a warning when the policy changes through the API, so a
/// proxy containers cannot reach is visible instead of hidden behind a
/// `|direct` fallback.
public struct HVFHostPortAllowlist: Sendable, Equatable {
    /// A cache-policy URL at the gateway that opens no port, and why.
    public struct Refusal: Codable, Sendable, Equatable {
        /// `goProxy` or `npmRegistry`.
        public var field: String
        public var url: String
        /// The port the URL names (its scheme's default when it names none).
        public var port: UInt16?
        public var reason: String

        public init(field: String, url: String, port: UInt16?, reason: String) {
            self.field = field
            self.url = url
            self.port = port
            self.reason = reason
        }

        /// One line for logs, `machine status` and API warnings.
        public var message: String { "cache policy \(field) \(url) opens no host port: \(reason)" }
    }

    /// `allowHostPorts`, deduplicated and sorted, control ports removed.
    public let explicit: [UInt16]
    /// Ports opened because the cache policy names them (`depproxyPort`).
    public let fromPolicy: [UInt16]
    public let refused: [Refusal]

    /// What micropod-vmm is given, sorted.
    public var ports: [UInt16] { Array(Set(explicit + fromPolicy)).sorted() }

    /// Micropod's own unauthenticated loopback listeners: MicropodAPI
    /// (45454) and the Docker shim's TCP listener (45455). A guest that
    /// reached either could drive the host's runtime.
    public static let defaultControlPorts: Set<UInt16> = [45454, 45455]

    /// `defaultControlPorts` plus the ports `MICROPOD_API_PORT` and
    /// `MICROPOD_SHIM_TCP_PORT` move those listeners to.
    public static func controlPorts(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<UInt16> {
        var ports = defaultControlPorts
        for key in ["MICROPOD_API_PORT", "MICROPOD_SHIM_TCP_PORT"] {
            if let raw = environment[key], let port = UInt16(raw), port > 0 { ports.insert(port) }
        }
        return ports
    }

    /// Names guest init maps to the host gateway in `/etc/hosts`.
    public static let gatewayHosts: Set<String> = ["10.42.0.1", "host.micropod.internal", "host.docker.internal"]
    /// The published-port network's gateway (eth1). It carries published
    /// ports to the host but forwards nothing to host loopback.
    public static let publishedNetGateway = "10.43.0.1"
    /// Ports below this are privileged host services (sshd, CUPS, SMB); a
    /// URL never opens one.
    public static let minimumPolicyPort: UInt16 = 1024

    public init(config: HVFMachineConfig, controlPorts: Set<UInt16> = HVFHostPortAllowlist.controlPorts()) {
        let explicit = Set(config.allowHostPorts.filter { $0 > 0 && !controlPorts.contains($0) })
        self.explicit = explicit.sorted()
        var fromPolicy = Set<UInt16>()
        var refused: [Refusal] = []
        let policy = config.cache
        let urls =
            (policy?.goProxy.map(HVFMachineCachePolicy.goProxyElements) ?? []).map { ("goProxy", $0) }
            + (policy?.npmRegistry.map { [$0] } ?? []).map { ("npmRegistry", $0) }
        for (field, raw) in urls {
            guard let url = HVFMachineCachePolicy.proxyURL(raw), let host = url.host?.lowercased() else { continue }
            let port = url.port.map { UInt16($0) } ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
            func refuse(_ reason: String) {
                refused.append(Refusal(field: field, url: raw, port: port, reason: reason))
            }
            if host == Self.publishedNetGateway {
                refuse(
                    "\(host) is the published-port network, which reaches no host service; "
                        + "name the gateway 10.42.0.1 (host.micropod.internal) instead")
                continue
            }
            // Anything else is an ordinary egress URL: nothing to open.
            guard Self.gatewayHosts.contains(host) else { continue }
            if port < Self.minimumPolicyPort {
                refuse("ports below \(Self.minimumPolicyPort) are never opened from a URL")
            } else if controlPorts.contains(port) {
                refuse("\(port) is a Micropod control port, which guests must never reach")
            } else if explicit.contains(port) {
                continue
            } else if config.depproxyPort != 0, port == config.depproxyPort {
                fromPolicy.insert(port)
            } else {
                refuse(
                    "\(port) is neither the depproxy port (\(config.depproxyPort)) nor in machine.json "
                        + "allowHostPorts; add it there to open it")
            }
        }
        self.fromPolicy = fromPolicy.sorted()
        self.refused = refused
    }

    /// `7677 (cache policy), 8080`, or `none`.
    public var description: String {
        let listed = ports.map { fromPolicy.contains($0) ? "\($0) (cache policy)" : "\($0)" }
        return listed.isEmpty ? "none" : listed.joined(separator: ", ")
    }
}

// MARK: - What the machine has open

/// The host ports the running machine opened beside the ones its next start
/// will open, for `machine status`: a cache policy changed through the API
/// is re-read by the guest at once, but its ports open only at the next
/// VMM launch.
public struct HVFHostPortStatus: Codable, Sendable, Equatable {
    /// The ports the running VMM was launched with; nil when no VMM runs,
    /// or a supervisor that predates the record launched it.
    public var open: [UInt16]?
    /// The ports the next launch opens, from machine.json as it is now.
    public var nextStart: [UInt16]
    public var refused: [HVFHostPortAllowlist.Refusal]
    /// A VMM runs and the next start opens a different set.
    public var restartPending: Bool
    /// The `host ports:` line of `machine status`.
    public var summary: String

    public init(config: HVFMachineConfig, state: HVFMachineState?, supervisorAlive: Bool) {
        let next = HVFHostPortAllowlist(config: config)
        let running = supervisorAlive && state?.vmmPID != nil
        open = running ? state?.allowHostPorts : nil
        nextStart = next.ports
        refused = next.refused
        restartPending = running && open != next.ports
        var summary: String
        if !running {
            summary = "\(next.description) at the next start"
        } else if let open, open == next.ports {
            summary = next.description
        } else if let open {
            let now = open.isEmpty ? "none" : open.map(String.init).joined(separator: ", ")
            summary = "\(now); the next start opens \(next.description) (restart to apply)"
        } else {
            summary = "unknown (an older supervisor launched the VMM); the next start opens \(next.description)"
        }
        if !next.refused.isEmpty {
            summary += "; \(next.refused.count) cache policy URL\(next.refused.count == 1 ? "" : "s") open nothing"
        }
        self.summary = summary
    }

    /// Why a cache policy just saved may not work in the running machine:
    /// URLs that open nothing, and policy ports the running VMM has not
    /// opened yet. Empty when nothing needs attention.
    public var policyWarnings: [String] {
        var warnings = refused.map(\.message)
        func list(_ ports: [UInt16]) -> String {
            "host port\(ports.count == 1 ? "" : "s") \(ports.map(String.init).joined(separator: ", "))"
        }
        if let open {
            let pending = nextStart.filter { !open.contains($0) }
            if !pending.isEmpty {
                warnings.append(
                    "\(list(pending)): not open in the running machine; opened at the next machine start "
                        + "(`micropod machine restart`)")
            }
        } else if restartPending, !nextStart.isEmpty {
            // A VMM runs, but its supervisor did not record what it opened.
            warnings.append(
                "\(list(nextStart)): the running machine does not say whether it opened "
                    + "\(nextStart.count == 1 ? "it" : "them"); restart it to apply (`micropod machine restart`)")
        }
        return warnings
    }
}

// MARK: - PUT /v1/caches/policy

/// The policy just saved, as `GET /v1/caches/policy` returns it, plus
/// `warnings` (`HVFHostPortStatus.policyWarnings`) when there are any. The
/// key exists only in this response: the policy itself never stores it.
public struct HVFCachePolicyUpdateResponse: Encodable, Sendable {
    public let policy: HVFMachineCachePolicy
    public let warnings: [String]

    public init(policy: HVFMachineCachePolicy, warnings: [String]) {
        self.policy = policy
        self.warnings = warnings
    }

    /// Reads the machine as it is now: call it after saving `config`.
    public init(saved config: HVFMachineConfig, client: HVFMachineClient) {
        let status = client.status()
        self.init(
            policy: config.effectiveCachePolicy,
            warnings: HVFHostPortStatus(config: config, state: status.state, supervisorAlive: status.supervisorAlive)
                .policyWarnings)
    }

    public func encode(to encoder: any Encoder) throws {
        try policy.encode(to: encoder)
        guard !warnings.isEmpty else { return }
        var c = encoder.container(keyedBy: HVFJSONKey.self)
        try c.encode(warnings, forKey: HVFJSONKey("warnings"))
    }
}
