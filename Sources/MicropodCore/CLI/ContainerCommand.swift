import Foundation

/// A fully-formed invocation of the `container` CLI.
public struct ContainerCommand: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]
    /// Optional stdin payload (e.g. registry passwords via `--password-stdin`).
    public var stdinData: Data?

    public init(arguments: [String], environment: [String: String] = [:], stdinData: Data? = nil) {
        self.arguments = arguments
        self.environment = environment
        self.stdinData = stdinData
    }

    public var displayName: String {
        "container " + arguments.joined(separator: " ")
    }

    /// Low-cardinality label for metrics: the verb, plus a sub-verb for
    /// resource-grouped commands (`image list`, `system start`). Arguments
    /// (names, ids, flags) are never included — one label per operation.
    public var metricLabel: String {
        let grouped: Set<String> = [
            "image", "system", "network", "volume", "registry", "builder",
            "plugin", "machine", "dns",
        ]
        guard let verb = arguments.first else { return "container" }
        if grouped.contains(verb), let sub = arguments.dropFirst().first,
            !sub.hasPrefix("-")
        {
            return "\(verb) \(sub)"
        }
        return verb
    }
}

/// Type-safe builders for every `container` subcommand Micropod uses.
///
/// Command availability mirrors the installed CLI contract (v1.2.x).
/// Every command that can emit JSON is built with `--format json`.
public enum ContainerCommandFactory {
    // MARK: - System

    public static func systemStatus() -> ContainerCommand {
        .init(arguments: ["system", "status", "--format", "json"])
    }

    public static func systemVersion() -> ContainerCommand {
        .init(arguments: ["system", "version", "--format", "json"])
    }

    public static func systemStart() -> ContainerCommand {
        .init(arguments: ["system", "start", "--disable-kernel-install"])
    }

    public static func systemStop() -> ContainerCommand {
        .init(arguments: ["system", "stop"])
    }

    public static func systemDF() -> ContainerCommand {
        .init(arguments: ["system", "df", "--format", "json"])
    }

    public static func systemKernelSetRecommended() -> ContainerCommand {
        .init(arguments: ["system", "kernel", "set", "--recommended"])
    }

    public static func systemLogs(last: String = "5m") -> ContainerCommand {
        .init(arguments: ["system", "logs", "--last", last])
    }

    public static func systemLogsFollow() -> ContainerCommand {
        .init(arguments: ["system", "logs", "--follow"])
    }

    // MARK: - Containers

    public static func listContainers(all: Bool = true) -> ContainerCommand {
        // `all` was previously ignored — running-only is the cheaper probe.
        .init(arguments: ["list"] + (all ? ["--all"] : []) + ["--format", "json"])
    }

    public static func inspectContainers(_ ids: [String]) -> ContainerCommand {
        .init(arguments: ["inspect"] + ids)
    }

    public static func startContainer(_ id: String) -> ContainerCommand {
        .init(arguments: ["start", id])
    }

    public static func stopContainer(_ id: String, timeout: Int = 10) -> ContainerCommand {
        .init(arguments: ["stop", "--time", String(timeout), id])
    }

    public static func stopAllContainers() -> ContainerCommand {
        .init(arguments: ["stop", "--all", "--time", "10"])
    }

    public static func killContainer(_ id: String, signal: String = "KILL") -> ContainerCommand {
        .init(arguments: ["kill", "--signal", signal, id])
    }

    public static func deleteContainer(_ id: String, force: Bool = false) -> ContainerCommand {
        var args = ["delete"]
        if force { args.append("--force") }
        args.append(id)
        return .init(arguments: args)
    }

    public static func deleteAllContainers(force: Bool = false) -> ContainerCommand {
        var args = ["delete", "--all"]
        if force { args.append("--force") }
        return .init(arguments: args)
    }

    public static func pruneContainers() -> ContainerCommand {
        .init(arguments: ["prune"])
    }

    public static func statsSnapshot() -> ContainerCommand {
        .init(arguments: ["stats", "--no-stream", "--format", "json"])
    }

    public static func logs(_ id: String, tail: Int? = nil, follow: Bool = false, boot: Bool = false)
        -> ContainerCommand
    {
        var args = ["logs"]
        if boot { args.append("--boot") }
        if follow { args.append("--follow") }
        if let tail { args += ["-n", String(tail)] }
        args.append(id)
        return .init(arguments: args)
    }

    public static func exportContainer(_ id: String, to outputPath: String) -> ContainerCommand {
        .init(arguments: ["export", "-o", outputPath, id])
    }

    public static func copyFile(from: String, to: String) -> ContainerCommand {
        .init(arguments: ["copy", from, to])
    }

    /// Builds a `container create` invocation (prepared, not started).
    /// Docker-compatible: `create` == `run` without `--detach`/start.
    public static func create(_ request: ContainerRunRequest) -> ContainerCommand {
        var command = run(request)
        command.arguments = command.arguments.filter { $0 != "--detach" }
        if let index = command.arguments.firstIndex(of: "--detach") {
            command.arguments.remove(at: index)
        }
        command.arguments[0] = "create"
        return command
    }

    /// Formats a CPU count for `--cpus`: Apple rejects float spellings
    /// ("2.0" is invalid — verified 2026-09-09), so whole numbers render
    /// as integers. Fractional counts (1.5) pass through and fail loudly
    /// at the runtime if unsupported, rather than rounding silently.
    public static func cpuCountString(_ cpus: Double) -> String {
        if cpus.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(cpus))
        }
        // String(Double) renders shortest round-trip ("1.5"); strip any
        // trailing ".0" defensively.
        var text = String(cpus)
        if text.hasSuffix(".0") { text = String(text.dropLast(2)) }
        return text
    }

    /// Builds a `container run` invocation from a run request.
    public static func run(_ request: ContainerRunRequest) -> ContainerCommand {
        var args = ["run"]
        if request.detach { args.append("--detach") }
        if let name = request.name { args += ["--name", name] }
        if let cpus = request.cpus { args += ["--cpus", Self.cpuCountString(cpus)] }
        if let memory = request.memory { args += ["--memory", memory] }
        for env in request.env { args += ["--env", env] }
        for file in request.envFiles { args += ["--env-file", file] }
        for port in request.publishedPorts {
            var spec = ""
            if let hostIP = port.hostIP, !hostIP.isEmpty { spec += hostIP + ":" }
            spec += "\(port.hostPort):\(port.containerPort)/\(port.transportProtocol)"
            args += ["--publish", spec]
        }
        for volume in request.volumes { args += ["--volume", volume] }
        for tmpfs in request.tmpfs { args += ["--tmpfs", tmpfs] }
        for label in request.labels { args += ["--label", "\(label.key)=\(label.value)"] }
        if request.interactive { args.append("--interactive") }
        if request.tty { args.append("--tty") }
        if request.useInit { args.append("--init") }
        if request.readOnly { args.append("--read-only") }
        if request.rosetta { args.append("--rosetta") }
        if let user = request.user { args += ["--user", user] }
        if let shmSize = request.shmSize { args += ["--shm-size", shmSize] }
        for dns in request.dns { args += ["--dns", dns] }
        for domain in request.dnsSearch { args += ["--dns-search", domain] }
        for cap in request.capAdd { args += ["--cap-add", cap] }
        for cap in request.capDrop { args += ["--cap-drop", cap] }
        for limit in request.ulimits { args += ["--ulimit", limit] }
        for network in request.networks { args += ["--network", network] }
        if let platform = request.platform { args += ["--platform", platform] }
        if let workdir = request.workdir { args += ["--workdir", workdir] }
        if let entrypoint = request.entrypoint { args += ["--entrypoint", entrypoint] }
        args.append(request.image)
        args += request.arguments
        return .init(arguments: args)
    }

    public static func exec(_ request: ContainerExecRequest) -> ContainerCommand {
        var args = ["exec"]
        if request.detach { args.append("--detach") }
        if request.interactive { args.append("--interactive") }
        if request.tty { args.append("--tty") }
        if let user = request.user { args += ["--user", user] }
        if let workdir = request.workdir { args += ["--workdir", workdir] }
        for env in request.env { args += ["--env", env] }
        args.append(request.containerID)
        args += request.arguments
        return .init(arguments: args)
    }

    // MARK: - Images

    public static func listImages(verbose: Bool = true) -> ContainerCommand {
        var args = ["image", "list", "--format", "json"]
        if verbose { args.append("--verbose") }
        return .init(arguments: args)
    }

    /// Layer-download parallelism for image pulls. Apple defaults to 3;
    /// CI images (node:22 etc.) are layer-heavy and pull-bound, so fetch
    /// with 8-way parallelism.
    public static let imagePullConcurrency = 8

    public static func pullImage(_ reference: String, platform: String? = nil) -> ContainerCommand {
        var args = ["image", "pull", "--progress", "plain"]
        if imagePullConcurrency > 0 {
            args += ["--max-concurrent-downloads", String(imagePullConcurrency)]
        }
        if let platform { args += ["--platform", platform] }
        args.append(reference)
        return .init(arguments: args)
    }

    public static func pushImage(_ reference: String, platform: String? = nil) -> ContainerCommand {
        var args = ["image", "push", "--progress", "plain"]
        if let platform { args += ["--platform", platform] }
        args.append(reference)
        return .init(arguments: args)
    }

    public static func saveImage(_ reference: String, to outputPath: String) -> ContainerCommand {
        .init(arguments: ["image", "save", "-o", outputPath, reference])
    }

    public static func saveImages(_ references: [String], to outputPath: String) -> ContainerCommand {
        .init(arguments: ["image", "save", "-o", outputPath] + references)
    }

    public static func loadImage(from inputPath: String) -> ContainerCommand {
        .init(arguments: ["image", "load", "--input", inputPath])
    }

    public static func tagImage(source: String, target: String) -> ContainerCommand {
        .init(arguments: ["image", "tag", source, target])
    }

    public static func deleteImage(_ reference: String, force: Bool = false) -> ContainerCommand {
        var args = ["image", "delete"]
        if force { args.append("--force") }
        args.append(reference)
        return .init(arguments: args)
    }

    public static func pruneImages(all: Bool = false) -> ContainerCommand {
        var args = ["image", "prune"]
        if all { args.append("--all") }
        return .init(arguments: args)
    }

    public static func inspectImage(_ reference: String) -> ContainerCommand {
        .init(arguments: ["image", "inspect", reference])
    }

    // MARK: - Build

    public static func build(_ request: ContainerBuildRequest) -> ContainerCommand {
        var args = ["build", "--progress", "plain"]
        if let file = request.dockerfile { args += ["--file", file] }
        for tag in request.tags { args += ["--tag", tag] }
        for arg in request.buildArgs { args += ["--build-arg", arg] }
        if let target = request.target { args += ["--target", target] }
        if let platform = request.platform { args += ["--platform", platform] }
        if request.noCache { args.append("--no-cache") }
        if request.pull { args.append("--pull") }
        if let cpus = request.cpus { args += ["--cpus", Self.cpuCountString(cpus)] }
        if let memory = request.memory { args += ["--memory", memory] }
        for label in request.labels { args += ["--label", "\(label.key)=\(label.value)"] }
        args.append(request.contextDirectory)
        return .init(arguments: args)
    }

    // MARK: - Volumes

    public static func listVolumes() -> ContainerCommand {
        .init(arguments: ["volume", "list", "--format", "json"])
    }

    public static func createVolume(
        _ name: String, size: String? = nil, labels: [String] = [], options: [String] = []
    ) -> ContainerCommand {
        var args = ["volume", "create"]
        if let size { args += ["-s", size] }
        for label in labels { args += ["--label", label] }
        for option in options { args += ["--opt", option] }
        args.append(name)
        return .init(arguments: args)
    }

    public static func deleteVolume(_ name: String) -> ContainerCommand {
        .init(arguments: ["volume", "delete", name])
    }

    public static func pruneVolumes() -> ContainerCommand {
        .init(arguments: ["volume", "prune"])
    }

    public static func inspectVolume(_ name: String) -> ContainerCommand {
        .init(arguments: ["volume", "inspect", name])
    }

    // MARK: - Machines & properties (4.1)

    public static func listMachines() -> ContainerCommand {
        .init(arguments: ["machine", "list", "--format", "json"])
    }

    public static func createMachine(_ image: String, name: String?, cpus: String?, memory: String?) -> ContainerCommand
    {
        var args = ["machine", "create", image]
        if let name { args += ["--name", name] }
        if let cpus { args += ["--cpus", cpus] }
        if let memory { args += ["--memory", memory] }
        return .init(arguments: args)
    }

    public static func deleteMachine(_ name: String) -> ContainerCommand {
        .init(arguments: ["machine", "delete", name])
    }

    public static func runMachine(_ name: String, extraArgs: [String], command: [String]) -> ContainerCommand {
        .init(arguments: ["machine", "run", "-n", name] + extraArgs + command)
    }

    public static func stopMachine(_ name: String) -> ContainerCommand {
        .init(arguments: ["machine", "stop", name])
    }

    public static func listProperties() -> ContainerCommand {
        .init(arguments: ["system", "property", "list", "--format", "json"])
    }

    // MARK: - Networks

    public static func listNetworks() -> ContainerCommand {
        .init(arguments: ["network", "list", "--format", "json"])
    }

    public static func createNetwork(
        _ name: String,
        internal: Bool = false,
        subnet: String? = nil,
        subnetV6: String? = nil,
        driver: String? = nil,
        options: [String] = [],
        labels: [String] = []
    ) -> ContainerCommand {
        var args = ["network", "create"]
        if `internal` { args.append("--internal") }
        if let subnet { args += ["--subnet", subnet] }
        if let subnetV6 { args += ["--subnet-v6", subnetV6] }
        // docker-generic driver names map to the default plugin on the
        // Apple runtime; anything else is passed through as the plugin.
        // An empty driver (compose sends "" for default networks) also
        // means default — emitting `--plugin ""` makes Apple fail plugin
        // lookup instead.
        if let driver, !driver.isEmpty, !["bridge", "overlay", "host", "none"].contains(driver) {
            args += ["--plugin", driver]
        }
        for option in options { args += ["--option", option] }
        for label in labels { args += ["--label", label] }
        args.append(name)
        return .init(arguments: args)
    }

    public static func deleteNetwork(_ name: String) -> ContainerCommand {
        .init(arguments: ["network", "delete", name])
    }

    public static func pruneNetworks() -> ContainerCommand {
        .init(arguments: ["network", "prune"])
    }

    public static func inspectNetwork(_ name: String) -> ContainerCommand {
        .init(arguments: ["network", "inspect", name])
    }

    // MARK: - Registry

    public static func registryLogin(server: String, username: String, password: String) -> ContainerCommand {
        .init(
            arguments: ["registry", "login", "--username", username, "--password-stdin", server],
            stdinData: Data((password + "\n").utf8))
    }

    public static func registryLogout(_ server: String) -> ContainerCommand {
        .init(arguments: ["registry", "logout", server])
    }

    public static func registryList() -> ContainerCommand {
        .init(arguments: ["registry", "list", "--format", "json"])
    }
}

// MARK: - Request payloads

public struct ContainerRunRequest: Sendable, Equatable {
    public var image: String
    public var name: String?
    public var detach: Bool
    public var cpus: Double?
    public var memory: String?
    public var env: [String]
    public var envFiles: [String]
    public var publishedPorts: [PortSpec]
    public var volumes: [String]
    public var tmpfs: [String]
    public var labels: [LabelSpec]
    public var interactive: Bool
    public var tty: Bool
    public var useInit: Bool
    public var readOnly: Bool
    public var rosetta: Bool
    public var user: String?
    public var shmSize: String?
    public var dns: [String]
    public var dnsSearch: [String]
    public var capAdd: [String]
    public var capDrop: [String]
    public var ulimits: [String]
    public var networks: [String]
    public var platform: String?
    public var workdir: String?
    public var entrypoint: String?
    public var arguments: [String]

    public init(
        image: String,
        name: String? = nil,
        detach: Bool = true,
        cpus: Double? = nil,
        memory: String? = nil,
        env: [String] = [],
        envFiles: [String] = [],
        publishedPorts: [PortSpec] = [],
        volumes: [String] = [],
        tmpfs: [String] = [],
        labels: [LabelSpec] = [],
        interactive: Bool = false,
        tty: Bool = false,
        useInit: Bool = false,
        readOnly: Bool = false,
        rosetta: Bool = false,
        user: String? = nil,
        shmSize: String? = nil,
        dns: [String] = [],
        dnsSearch: [String] = [],
        capAdd: [String] = [],
        capDrop: [String] = [],
        ulimits: [String] = [],
        networks: [String] = [],
        platform: String? = nil,
        workdir: String? = nil,
        entrypoint: String? = nil,
        arguments: [String] = []
    ) {
        self.image = image
        self.name = name
        self.detach = detach
        self.cpus = cpus
        self.memory = memory
        self.env = env
        self.envFiles = envFiles
        self.publishedPorts = publishedPorts
        self.volumes = volumes
        self.tmpfs = tmpfs
        self.labels = labels
        self.interactive = interactive
        self.tty = tty
        self.useInit = useInit
        self.readOnly = readOnly
        self.rosetta = rosetta
        self.user = user
        self.shmSize = shmSize
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.ulimits = ulimits
        self.networks = networks
        self.platform = platform
        self.workdir = workdir
        self.entrypoint = entrypoint
        self.arguments = arguments
    }
}

public struct PortSpec: Sendable, Equatable {
    public var hostPort: Int
    public var containerPort: Int
    public var transportProtocol: String
    public var hostIP: String?

    public init(hostPort: Int, containerPort: Int, transportProtocol: String = "tcp", hostIP: String? = nil) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.transportProtocol = transportProtocol
        self.hostIP = hostIP
    }
}

public struct LabelSpec: Sendable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct ContainerExecRequest: Sendable, Equatable {
    public var containerID: String
    public var arguments: [String]
    public var interactive: Bool
    public var tty: Bool
    public var detach: Bool
    public var user: String?
    public var workdir: String?
    public var env: [String]

    public init(
        containerID: String,
        arguments: [String],
        interactive: Bool = false,
        tty: Bool = false,
        detach: Bool = false,
        user: String? = nil,
        workdir: String? = nil,
        env: [String] = []
    ) {
        self.containerID = containerID
        self.arguments = arguments
        self.interactive = interactive
        self.tty = tty
        self.detach = detach
        self.user = user
        self.workdir = workdir
        self.env = env
    }
}

public struct ContainerBuildRequest: Sendable, Equatable {
    public var contextDirectory: String
    public var dockerfile: String?
    public var tags: [String]
    public var buildArgs: [String]
    public var target: String?
    public var platform: String?
    public var noCache: Bool
    public var cpus: Double?
    public var memory: String?
    /// Force a base-image refresh (`container build --pull`, Docker `pull=1`).
    public var pull: Bool
    public var labels: [LabelSpec]

    public init(
        contextDirectory: String,
        dockerfile: String? = nil,
        tags: [String] = [],
        buildArgs: [String] = [],
        target: String? = nil,
        platform: String? = nil,
        noCache: Bool = false,
        cpus: Double? = nil,
        memory: String? = nil,
        pull: Bool = false,
        labels: [LabelSpec] = []
    ) {
        self.contextDirectory = contextDirectory
        self.dockerfile = dockerfile
        self.tags = tags
        self.buildArgs = buildArgs
        self.target = target
        self.platform = platform
        self.noCache = noCache
        self.cpus = cpus
        self.memory = memory
        self.pull = pull
        self.labels = labels
    }
}
