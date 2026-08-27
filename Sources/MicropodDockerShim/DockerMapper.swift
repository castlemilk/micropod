import Foundation
import MicropodCore

struct DockerVersion: Codable {
    var Platform: NameOnly
    var Components: [Component]
    var Version: String
    var ApiVersion: String
    var MinAPIVersion: String
    var GitCommit: String
    var GoVersion: String
    var Os: String
    var Arch: String
    var KernelVersion: String
    var BuildTime: String

    struct NameOnly: Codable { var Name: String }
    struct Component: Codable {
        var Name: String
        var Version: String
    }
}

struct DockerInfo: Codable {
    var ID: String
    var Containers: Int
    var ContainersRunning: Int
    var ContainersPaused: Int
    var ContainersStopped: Int
    var Images: Int
    var Driver: String
    var MemoryLimit: Bool
    var SwapLimit: Bool
    var KernelMemoryTCP: Bool
    var CpuCfsPeriod: Bool
    var CpuCfsQuota: Bool
    var CPUShares: Bool
    var CPUSet: Bool
    var PidsLimit: Bool
    var IPv4Forwarding: Bool
    var BridgeNfIptables: Bool
    var BridgeNfIp6tables: Bool
    var Debug: Bool
    var NFd: Int
    var OomKillDisable: Bool
    var NGoroutines: Int
    var SystemTime: String
    var LoggingDriver: String
    var CgroupDriver: String
    var CgroupVersion: String
    var NEventsListener: Int
    var KernelVersion: String
    var OperatingSystem: String
    var OSVersion: String
    var OSType: String
    var Architecture: String
    var NCPU: Int
    var MemTotal: Int64
    var Name: String
    var ServerVersion: String
    var DockerRootDir: String
}

/// Maps MicropodCore runtime models onto the Docker Engine JSON surface.
enum DockerMapper {
    static func stateName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "running": return "running"
        case "stopped", "exited": return "exited"
        case "created", "creating": return "created"
        case "paused": return "paused"
        default: return raw.lowercased()
        }
    }

    /// Docker-style names for a container; the runtime has a single
    /// identifier which doubles as its name.
    static func names(for container: Micropod_V1_Container) -> [String] {
        ["/\(container.id)"]
    }

    static func unixSeconds(_ iso: String) -> Int64 {
        guard let date = parseDate(iso) else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }

    static func rfc3339(_ iso: String) -> String {
        if let date = parseDate(iso) {
            return Self.formatter.string(from: date)
        }
        return "0001-01-01T00:00:00Z"
    }

    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func summary(
        _ container: Micropod_V1_Container, create: DockerCreateRequest?
    ) -> DockerContainerSummary {
        let state = stateName(container.state)
        var ports = [DockerContainerSummary.DockerSummaryPort]()
        for published in container.publishedPorts {
            ports.append(
                DockerContainerSummary.DockerSummaryPort(
                    IP: published.hostIp.isEmpty ? "0.0.0.0" : published.hostIp,
                    PrivatePort: Int(published.containerPort),
                    PublicPort: Int(published.hostPort),
                    Type: published.protocol.isEmpty ? "tcp" : published.protocol))
        }
        if let create, let exposed = create.ExposedPorts {
            for key in exposed.keys {
                let parts = key.split(separator: "/")
                guard let port = Int(parts[0]) else { continue }
                let proto = parts.count > 1 ? String(parts[1]) : "tcp"
                let alreadyPublished = ports.contains { $0.PrivatePort == port && $0.Type == proto }
                if !alreadyPublished {
                    ports.append(
                        DockerContainerSummary.DockerSummaryPort(
                            IP: nil, PrivatePort: port, PublicPort: nil, Type: proto))
                }
            }
        }

        let mounts = self.mounts(container)
        let networkName = container.networks.first ?? "default"

        return DockerContainerSummary(
            Id: container.id,
            Names: ["/\(container.id)"],
            Image: create?.Image ?? container.image,
            ImageID: "sha256:\(container.image.sha256Prefix)",
            Command: create?.Cmd?.joined(separator: " ") ?? "",
            Created: unixSeconds(container.createdAt),
            State: state == "created" ? "created" : state,
            Status: statusText(container),
            Labels: mergeLabels(runtime: container.labels, create: create),
            Ports: ports,
            HostConfig: DockerContainerSummary.HostRef(
                NetworkMode: create?.HostConfig?.NetworkMode ?? networkName),
            NetworkSettings: DockerContainerSummary.SummaryNetworkSettings(
                Networks: [
                    networkName:
                        .init(IPAddress: plainIP(container.ipv4Address), Gateway: nil)
                ]),
            Mounts: mounts)
    }

    /// Runtime reports addresses with a CIDR suffix (192.168.64.7/24);
    /// Docker clients expect a bare address.
    static func plainIP(_ raw: String) -> String {
        raw.split(separator: "/").first.map(String.init) ?? raw
    }

    /// Builds a Container proto from the runtime's raw `container inspect`
    /// JSON so the shim can serve /containers/{id}/json with a single
    /// flat-cost CLI call instead of a full list enumeration.
    static func container(fromRawInspect data: Data) -> Micropod_V1_Container? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
            let entries = parsed as? [[String: Any]],
            let entry = entries.first
        else { return nil }
        let configuration = entry["configuration"] as? [String: Any] ?? [:]
        let status = entry["status"] as? [String: Any] ?? [:]

        var container = Micropod_V1_Container()
        container.id = (entry["id"] as? String) ?? (configuration["id"] as? String) ?? ""
        container.image =
            ((configuration["image"] as? [String: Any])?["reference"] as? String) ?? ""
        container.state = (status["state"] as? String) ?? ""
        container.createdAt = (configuration["creationDate"] as? String) ?? ""
        if let platform = configuration["platform"] as? [String: Any] {
            let os = platform["os"] as? String ?? ""
            let arch = platform["architecture"] as? String ?? ""
            container.platform = "\(os)/\(arch)"
        }
        for raw in (configuration["publishedPorts"] as? [[String: Any]]) ?? [] {
            var port = Micropod_V1_PortMapping()
            port.hostPort = UInt32(raw["hostPort"] as? Int ?? 0)
            port.containerPort = UInt32(raw["containerPort"] as? Int ?? 0)
            port.`protocol` = (raw["proto"] as? String) ?? "tcp"
            port.hostIp = (raw["hostAddress"] as? String) ?? ""
            container.publishedPorts.append(port)
        }
        for raw in (configuration["mounts"] as? [[String: Any]]) ?? [] {
            var mount = Micropod_V1_Mount()
            mount.source = (raw["source"] as? String) ?? ""
            mount.destination = (raw["destination"] as? String) ?? ""
            mount.readOnly = (raw["readOnly"] as? Bool) ?? false
            container.mounts.append(mount)
        }
        for raw in (status["networks"] as? [[String: Any]]) ?? [] {
            if let name = raw["network"] as? String, !name.isEmpty {
                container.networks.append(name)
            }
            if container.ipv4Address.isEmpty {
                container.ipv4Address = plainIP((raw["ipv4Address"] as? String) ?? "")
            }
        }
        if let initProcess = configuration["initProcess"] as? [String: Any] {
            container.env = (initProcess["environment"] as? [String]) ?? []
        }
        container.labels = (configuration["labels"] as? [String: String]) ?? [:]
        return container
    }

    static func inspect(
        _ container: Micropod_V1_Container, create: DockerCreateRequest?
    ) -> DockerContainerInspect {
        let state = stateName(container.state)
        let running = state == "running"
        var exitCode = Int(container.exitCode) ?? 0
        if running { exitCode = 0 }
        let started = running || exitCode != 0 ? rfc3339(container.createdAt) : "0001-01-01T00:00:00Z"
        let finishedAt = !running && exitCode != 0 ? started : "0001-01-01T00:00:00Z"
        let cmd = create?.Cmd ?? []
        let entrypoint = create?.Entrypoint
        let path = entrypoint?.first ?? cmd.first ?? ""
        let args: [String] = {
            var all: [String] = []
            if let entrypoint, entrypoint.count > 1 {
                all.append(contentsOf: entrypoint.dropFirst())
            }
            if entrypoint != nil {
                all.append(contentsOf: cmd)
            } else if cmd.count > 1 {
                all.append(contentsOf: cmd.dropFirst())
            }
            return all
        }()

        var portMap = [String: [DockerPortBinding]?]()
        for published in container.publishedPorts {
            let key = "\(published.containerPort)/\(published.protocol.isEmpty ? "tcp" : published.protocol)"
            portMap[key] = [
                DockerPortBinding(
                    HostIp: published.hostIp.isEmpty ? "0.0.0.0" : published.hostIp,
                    HostPort: String(published.hostPort))
            ]
        }

        let networkName = container.networks.first ?? "default"
        let ipAddress = plainIP(container.ipv4Address)
        let gateway = ipAddress.isEmpty ? "" : ipAddress.split(separator: ".").dropLast().joined(separator: ".") + ".1"

        return DockerContainerInspect(
            Id: container.id,
            Created: rfc3339(container.createdAt),
            Path: path,
            Args: args,
            State: DockerContainerInspect.DockerState(
                Status: state, Running: running, Paused: false, Restarting: false,
                OOMKilled: false, Dead: false, Pid: running ? 1 : 0, ExitCode: exitCode,
                Error: "", StartedAt: started, FinishedAt: finishedAt),
            Image: "sha256:\(container.image.sha256Prefix)",
            Name: "/\(container.id)",
            Platform: container.platform.isEmpty ? "linux" : container.platform,
            Config: DockerContainerInspect.DockerConfig(
                Hostname: String(container.id.prefix(12)),
                Env: create?.Env ?? container.env,
                Cmd: cmd,
                Image: create?.Image ?? container.image,
                Labels: mergeLabels(runtime: container.labels, create: create),
                WorkingDir: create?.WorkingDir ?? "/",
                Entrypoint: entrypoint,
                Tty: false,
                OpenStdin: false),
            HostConfig: create?.HostConfig ?? DockerHostConfig(),
            NetworkSettings: DockerContainerInspect.InspectNetworkSettings(
                IPAddress: ipAddress,
                Gateway: ipAddress.isEmpty ? "" : gateway,
                Ports: portMap,
                Networks: [
                    networkName:
                        DockerContainerInspect.InspectNetworkSettings.DockerNetworkInspect(
                            IPAddress: ipAddress, Gateway: gateway, MacAddress: "")
                ]),
            Mounts: mounts(container))
    }

    static func statusText(_ container: Micropod_V1_Container) -> String {
        let state = stateName(container.state)
        switch state {
        case "running":
            return "Up \(relativeAge(unixSeconds(container.createdAt)))"
        case "exited":
            return "Exited (\(Int(container.exitCode) ?? 0)) \(relativeAge(unixSeconds(container.createdAt))) ago"
        default:
            return state.capitalized
        }
    }

    static func relativeAge(_ seconds: Int64) -> String {
        let interval = max(0, Date().timeIntervalSince1970 - TimeInterval(seconds))
        let minutes = Int(interval / 60)
        if minutes < 1 { return "Less than a second" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private static func mounts(_ container: Micropod_V1_Container)
        -> [DockerContainerSummary.DockerMount]
    {
        container.mounts.map { mount in
            DockerContainerSummary.DockerMount(
                Type: mount.type == "volume" ? "volume" : "bind",
                Source: mount.source,
                Destination: mount.destination,
                RW: !mount.readOnly)
        }
    }

    private static func mergeLabels(
        runtime: [String: String], create: DockerCreateRequest?
    ) -> [String: String] {
        var merged = create?.Labels ?? [:]
        for (key, value) in runtime { merged[key] = value }
        return merged
    }

    /// Re-shapes the runtime's raw `container image inspect` JSON (an array
    /// with per-platform variants) into the Docker Engine inspect object
    /// docker-py and friends expect.
    static func dockerImageInspect(fromRaw data: Data, reference: String) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries = parsed as? [[String: Any]] ?? []
        guard let entry = entries.first else { return nil }

        let configuration = entry["configuration"] as? [String: Any] ?? [:]
        let id = entry["id"] as? String ?? ""
        let createdAt = configuration["creationDate"] as? String ?? ""
        let name = (configuration["name"] as? String) ?? reference
        let descriptor = configuration["descriptor"] as? [String: Any] ?? [:]
        let manifestDigest = descriptor["digest"] as? String ?? ""

        let variants = (entry["variants"] as? [[String: Any]]) ?? []
        let preferred =
            variants.first { v in
                let platform = v["platform"] as? [String: Any] ?? [:]
                return (platform["os"] as? String) == "linux" && (platform["architecture"] as? String) == "arm64"
            } ?? variants.first { v in
                ((v["platform"] as? [String: Any])?["os"] as? String) == "linux"
            } ?? variants.first

        let platform = (preferred?["platform"] as? [String: Any]) ?? [:]
        let variantConfig = ((preferred?["config"] as? [String: Any])?["config"] as? [String: Any]) ?? [:]
        let size = preferred?["size"] as? Int64 ?? 0

        var inspect: [String: Any] = [
            "Id": "sha256:\(id)",
            "RepoTags": [name],
            "RepoDigests": manifestDigest.isEmpty ? [] : ["\(baseRepository(of: name))@\(manifestDigest)"],
            "Created": createdAt,
            "Architecture": platform["architecture"] ?? "arm64",
            "Os": platform["os"] ?? "linux",
            "Size": size,
            "VirtualSize": size,
            "Descriptor": [
                "mediaType": descriptor["mediaType"] ?? "",
                "digest": manifestDigest,
                "size": descriptor["size"] ?? 0,
            ],
        ]
        if let variant = platform["variant"] as? String {
            inspect["Variant"] = variant
        }
        inspect["Config"] = [
            "Cmd": variantConfig["Cmd"] ?? [],
            "Env": variantConfig["Env"] ?? [],
            "Labels": variantConfig["Labels"] ?? [:],
            "User": variantConfig["User"] ?? "",
            "WorkingDir": variantConfig["WorkingDir"] ?? "",
            "Entrypoint": variantConfig["Entrypoint"] ?? [],
            "ExposedPorts": variantConfig["ExposedPorts"] ?? [:],
        ]
        inspect["RootFS"] = ["Type": "layers"]
        inspect["GraphDriver"] = ["Name": "container", "Data": [:] as [String: Any]]
        inspect["Metadata"] = ["LastTagTime": "0001-01-01T00:00:00Z"]

        guard
            let output = try? JSONSerialization.data(
                withJSONObject: inspect, options: [.sortedKeys])
        else { return nil }
        return output
    }

    /// Strips the tag/digest so repo@digest can be composed.
    private static func baseRepository(of name: String) -> String {
        var repository = name
        if let at = repository.firstIndex(of: "@") {
            repository = String(repository[repository.startIndex..<at])
        } else if let colon = repository.lastIndex(of: ":"),
            repository[repository.startIndex..<colon].contains("/")
        {
            repository = String(repository[repository.startIndex..<colon])
        }
        return repository
    }

    static func imageSummary(_ image: Micropod_V1_Image) -> DockerImageSummary {
        DockerImageSummary(
            Id: image.id.hasPrefix("sha256:") ? image.id : "sha256:\(image.id)",
            ParentId: "",
            RepoTags: image.names.filter { !$0.contains("@") },
            RepoDigests: image.names.filter { $0.contains("@") },
            Created: unixSeconds(image.createdAt),
            Size: Int64(image.sizeBytes),
            Labels: [:])
    }
}

extension String {
    /// Stable short hash stand-in for image IDs the runtime doesn't expose.
    var sha256Prefix: String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016x%016x", hash, hash & 0xdead_beef_cafe_f00d)
    }
}
