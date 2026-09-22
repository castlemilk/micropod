import Foundation

// Docker Engine API JSON shapes (v1.44 subset) that testcontainers + ryuk read.
// Field names are fixed by the API; use explicit CodingKeys everywhere the
// Docker name differs from Swift conventions.

struct DockerPortBinding: Codable {
    var HostIp: String?
    var HostPort: String?
}

struct DockerCreateRequest: Codable {
    var Hostname: String?
    var Image: String
    var Labels: [String: String]?
    var Env: [String]?
    var Cmd: [String]?
    var Entrypoint: [String]?
    var WorkingDir: String?
    var User: String?
    var Tty: Bool?
    var OpenStdin: Bool?
    var ExposedPorts: [String: JSONEmpty]?
    var HostConfig: DockerHostConfig?
    /// Docker API healthcheck (top-level create field). Durations are
    /// nanoseconds, matching dockerd. Nil/absent or Test==["NONE"] disables.
    var Healthcheck: DockerHealthcheck?
    /// Per-network endpoint config (aliases, static IPs). The Apple runtime
    /// has no multi-attach/static-IP/hostname primitives: attachment still
    /// follows NetworkMode only, but aliases feed the managed /etc/hosts
    /// DNS emulation (see HostsFile).
    var NetworkingConfig: DockerNetworkingConfig?

    struct JSONEmpty: Codable {}

    /// Flat "host:container/proto" port map from ExposedPorts keys.
    var exposedPortSpecs: [String] {
        Array((ExposedPorts ?? [:]).keys)
    }
}

/// Docker API healthcheck descriptor (create-time config).
struct DockerHealthcheck: Codable {
    /// ["NONE"] disables; ["CMD", args...] execs directly;
    /// ["CMD-SHELL", script] runs under /bin/sh -c.
    var Test: [String]?
    var Interval: Int64?
    var Timeout: Int64?
    var Retries: Int?
    var StartPeriod: Int64?
    var StartInterval: Int64?
}

struct DockerRestartPolicy: Codable {
    var Name: String?
    var MaximumRetryCount: Int?
}

struct DockerNetworkingConfig: Codable {
    var EndpointsConfig: [String: DockerEndpointSettings]?
}

struct DockerEndpointSettings: Codable {
    var Aliases: [String]?
    var IPAddress: String?
}

/// Network attachment shared by create handling and state tracking.
/// "", default, bridge, host and none all mean "no custom attachment"
/// (the Apple default network, which has working name DNS); anything else
/// is a custom Apple network (needs an explicit subnet + managed hosts).
extension DockerCreateRequest {
    var attachedNetworks: [String] {
        let mode = HostConfig?.NetworkMode ?? ""
        switch mode {
        case "", "default", "bridge", "host", "none":
            return []
        default:
            return [mode]
        }
    }

    /// Aliases requested per network (service DNS names in compose flows).
    func aliases(for network: String) -> [String] {
        NetworkingConfig?.EndpointsConfig?[network]?.Aliases ?? []
    }
}

struct DockerHostConfig: Codable {
    var Binds: [String]?
    var NetworkMode: String?
    var PortBindings: [String: [DockerPortBinding]]?
    var AutoRemove: Bool?
    var Privileged: Bool?
    var ReadonlyRootfs: Bool?
    var Init: Bool?
    var Memory: Int64?
    var ShmSize: Int64?
    var CapAdd: [String]?
    var CapDrop: [String]?
    var ExtraHosts: [String]?
    var RestartPolicy: DockerRestartPolicy?
    /// CPU quota in billionths of a CPU (Docker NanoCpus). Missing/zero =
    /// no limit (Apple default applies).
    var NanoCpus: Int64?
    /// tmpfs mounts path → options (Docker map form). Apple accepts bare
    /// paths only; non-empty options are dropped at translation (documented
    /// there) — the mount itself is always honored.
    var Tmpfs: [String: String]?
    var Dns: [String]?
    var DnsSearch: [String]?
    var Ulimits: [DockerUlimit]?
}

/// One Docker ulimit entry (HostConfig.Ulimits[]): mapped to Apple's
/// `<type>=<soft>[:<hard>]` flag form.
struct DockerUlimit: Codable {
    var Name: String
    var Soft: Int64
    var Hard: Int64
}

struct DockerCreateResponse: Codable {
    var Id: String
    var Warnings: [String]
}

struct DockerContainerSummary: Codable {
    var Id: String
    var Names: [String]
    var Image: String
    var ImageID: String
    var Command: String
    var Created: Int64
    var State: String
    var Status: String
    var Labels: [String: String]
    var Ports: [DockerSummaryPort]
    var HostConfig: HostRef
    var NetworkSettings: SummaryNetworkSettings
    var Mounts: [DockerMount]
    /// Only set by /system/df.
    var SizeRw: Int64?
    var SizeRootFs: Int64?

    struct HostRef: Codable {
        var NetworkMode: String
    }

    struct SummaryNetworkSettings: Codable {
        var Networks: [String: DockerNetworkSummary]

        struct DockerNetworkSummary: Codable {
            var IPAddress: String
            var Gateway: String?
        }
    }

    struct DockerSummaryPort: Codable {
        var IP: String?
        var PrivatePort: Int
        var PublicPort: Int?
        var `Type`: String
    }

    struct DockerMount: Codable {
        var `Type`: String
        var Source: String?
        var Destination: String?
        var RW: Bool?
    }
}

struct DockerContainerInspect: Codable {
    var Id: String
    var Created: String
    var Path: String
    var Args: [String]
    var State: DockerState
    var Image: String
    var Name: String
    var Platform: String
    var Config: DockerConfig
    var HostConfig: DockerHostConfig
    var NetworkSettings: InspectNetworkSettings
    var Mounts: [DockerContainerSummary.DockerMount]

    struct DockerState: Codable {
        var Status: String
        var Running: Bool
        var Paused: Bool
        var Restarting: Bool
        var OOMKilled: Bool
        var Dead: Bool
        var Pid: Int
        var ExitCode: Int
        var Error: String
        var StartedAt: String
        var FinishedAt: String
        /// Nil when the container has no healthcheck configured (dockerd
        /// omits the key; synthesized Codable emits null, which clients
        /// tolerate identically).
        var Health: DockerHealth?
    }

    /// Docker API health state (inspect State.Health).
    struct DockerHealth: Codable {
        var Status: String
        var FailingStreak: Int
        var Log: [DockerHealthLog]
    }

    struct DockerHealthLog: Codable {
        var Start: String
        var End: String
        var ExitCode: Int
        var Output: String
    }

    struct DockerConfig: Codable {
        var Hostname: String
        var Env: [String]
        var Cmd: [String]
        var Image: String
        var Labels: [String: String]
        var WorkingDir: String
        var Entrypoint: [String]?
        var Tty: Bool
        var OpenStdin: Bool
    }

    struct InspectNetworkSettings: Codable {
        var IPAddress: String
        var IPPrefixLen: Int
        var Gateway: String
        var Ports: [String: [DockerPortBinding]?]
        var Networks: [String: DockerNetworkInspect]

        struct DockerNetworkInspect: Codable {
            var IPAddress: String
            var IPPrefixLen: Int
            var Gateway: String
            var MacAddress: String
        }
    }
}

struct DockerImageSummary: Codable {
    var Id: String
    var ParentId: String
    var RepoTags: [String]
    var RepoDigests: [String]
    var Created: Int64
    var Size: Int64
    var Labels: [String: String]
    /// Only set by /system/df: number of containers using this image.
    var Containers: Int?
    /// Only set by /system/df: virtual size alias docker clients expect.
    var SharedSize: Int?
}

struct DockerEvent: Codable {
    var `Type`: String
    var Action: String
    var Actor: Actor
    var time: Int64
    var timeNano: Int64
    // Legacy flat fields — ryuk and older clients read these.
    var status: String
    var id: String
    var from: String

    struct Actor: Codable {
        var ID: String
        var Attributes: [String: String]
    }
}

struct DockerVolume: Codable {
    var Name: String
    var Driver: String
    var Mountpoint: String
    var CreatedAt: String?
    var Labels: [String: String]
    var Scope: String
    /// Only set by /system/df.
    var UsageData: UsageData?
    var Size: Int64?

    struct UsageData: Codable {
        var Size: Int64
        var RefCount: Int64
    }
}

struct DockerNetworkResource: Codable {
    var Name: String
    var Id: String
    var Created: String
    var Scope: String
    var Driver: String
    var Internal: Bool
    var IPAM: IPAM
    var Labels: [String: String]

    struct IPAM: Codable {
        var Driver: String
        var Config: [IPAMConfig]

        struct IPAMConfig: Codable {
            var Subnet: String?
            var Gateway: String?
        }
    }
}
