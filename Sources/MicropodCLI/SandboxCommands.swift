import Foundation
import MicropodCore
import MicropodRuntime
import vmnet

/// `micropod sandbox` — ephemeral one-VM-per-run CI sandboxes driven
/// in-process (no apiserver). Dispatched before `Services` resolution so a
/// run never pays the apiserver ping.
enum SandboxCommands {
    static let helpText = """
        micropod sandbox — ephemeral micro-VM per command (CI fast path)

        Usage:
          micropod sandbox run [flags] [image|--from ckpt] [-- cmd…]
          micropod sandbox checkpoint create <name> [flags] [image|--from ckpt] -- cmd…
          micropod sandbox checkpoint ls | rm <name…>
          micropod sandbox prune                     drop cached base disks + stale runs

        The image defaults to \(defaultImage). With no command on a terminal
        the image's default command gets the terminal — a shell for most bases.

        Flags:
          --from <ckpt>              boot from a checkpoint instead of an image
          -c, --cpus <n>             vCPUs (default 2)
          -m, --memory <MiB>         memory (default 2048)
          --disk <GiB>, --disk-size <MiB>   rootfs size for image bases (default 8 GiB)
          --mount <host:/guest[:rw|ro]>  share a host dir; guest writes go to a
                                     per-run copy and are discarded (repeatable)
          --allow-host-writes        allow `--mount …:rw` (writes land on the host)
          -v <host:/guest[:ro|rw|overlay]>  bind mount, read-write by default
          -e <KEY[=val]>             env var (repeatable; bare KEY copies host value)
          -w <dir>                   working directory
          --allow-net, --net         attach a NAT network device (off by default)
          -p <[hostIP:]host:guest>   publish a guest TCP port on the host (loopback
                                     by default); works without --allow-net
          --expose-host <port>       reach a host loopback port from the guest as
                                     host.micropod.internal:<port>
          --dns-resolver <ip>        guest nameserver (with a network)
          --allow-host <host>        with --allow-net: reach only these hosts
                                     (repeatable; *.example.com for subdomains)
          --secret NAME=ENV@host,…   the guest sees a placeholder in $NAME; the
                                     host proxy swaps in $ENV on HTTPS requests
                                     to those hosts — the value never enters the VM
          -i, -t, -it                keep stdin attached / allocate a terminal
          --no-tmpfs                 keep /tmp on the rootfs instead of RAM
          --tmp-size <MiB>           cap the /tmp tmpfs
          --timeout <sec>            kill the guest after <sec>; exits 124
          --config <path>            read defaults from a JSON file (default:
                                     ./micropod.json when present)
        """

    /// What `run` boots with no image, as `shuru run` boots its Alpine base.
    static let defaultImage = "alpine:latest"

    static let valueFlags: Set<String> = [
        "--from", "--cpus", "--memory", "--disk", "--disk-size", "--volume", "--mount", "--env",
        "--workdir", "--tmp-size", "--timeout", "--publish", "--expose-host", "--dns-resolver", "--config",
        "--allow-host", "--secret",
    ]
    static let boolFlags: Set<String> = [
        "--net", "--no-tmpfs", "--allow-host-writes", "--interactive", "--tty",
    ]
    static let aliases = [
        "-c": "--cpus", "-m": "--memory", "-v": "--volume", "-e": "--env", "-w": "--workdir",
        "--allow-net": "--net", "-p": "--publish", "--port": "--publish", "--dns": "--dns-resolver",
        "-i": "--interactive", "-t": "--tty",
    ]

    /// Raw argv (post `sandbox`) — the guest command after `--` must reach
    /// the VM untouched by the global `--json`/`--no-color` stripping.
    static func main(_ args: [String]) async -> Int32 {
        do {
            switch args.first {
            case "run":
                return try await run(Array(args.dropFirst()), saveAs: nil)
            case "checkpoint", "checkpoints", "ckpt":
                return try await checkpoint(Array(args.dropFirst()))
            case "prune":
                try prune()
                return ExitCode.ok
            case nil, "help", "--help", "-h":
                print(helpText)
                return args.isEmpty ? ExitCode.usage : ExitCode.ok
            default:
                throw UsageError(message: "unknown sandbox command '\(args[0])'")
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data("error: \(errorMessage(error))\n".utf8))
            return ExitCode.failure
        }
    }

    static func run(_ args: [String], saveAs: String?) async throws -> Int32 {
        // Split at the first `--`: flags + base before, guest argv after.
        let split = args.firstIndex(of: "--")
        let head = split.map { Array(args[..<$0]) } ?? args
        let command = split.map { Array(args[($0 + 1)...]) } ?? []
        let parsed = try parseArgs(
            head.flatMap { ["-it", "-ti"].contains($0) ? ["-i", "-t"] : [$0] },
            boolFlags: boolFlags, valueFlags: valueFlags, aliases: aliases, commandName: "sandbox run")
        let config = try SandboxConfig.load(explicit: parsed.value("--config"))

        let base: SandboxVM.Base
        var trailing = parsed.positionals
        if let ckpt = parsed.value("--from") ?? (trailing.isEmpty ? config?.from : nil) {
            base = .checkpoint(ckpt)
        } else if !trailing.isEmpty {
            base = .image(trailing.removeFirst())
        } else {
            base = .image(config?.image ?? defaultImage)
        }

        var options = SandboxVM.Options(base: base)
        // `sandbox run alpine echo hi` works too — positionals past the
        // image are the command when there's no `--`.
        options.arguments = !command.isEmpty ? command : !trailing.isEmpty ? trailing : config?.command ?? []
        options.cpus = parsed.value("--cpus").flatMap(Int.init) ?? config?.cpus ?? 2
        options.memoryMiB = parsed.value("--memory").flatMap(UInt64.init) ?? config?.memory ?? 2048
        if let gib = parsed.value("--disk").flatMap(UInt64.init) {
            options.diskBytes = gib << 30
        } else if let mib = parsed.value("--disk-size").flatMap(UInt64.init) ?? config?.diskSize {
            options.diskBytes = mib << 20
        }
        let allowHostWrites = parsed.has("--allow-host-writes") || config?.allowHostWrites == true
        options.mounts =
            try parsed.values("--volume")
            + (parsed.values("--mount") + (config?.mounts ?? [])).map {
                try mountSpec($0, allowHostWrites: allowHostWrites)
            }
        options.env = (config?.env ?? []) + parsed.values("--env")
        options.workdir = parsed.value("--workdir") ?? config?.workdir
        options.network = parsed.has("--net") || config?.allowNet == true
        options.ports =
            try (config?.ports ?? []).map(PortForward.parse)
            + parsed.values("--publish").map(PortForward.parse)
        options.exposeHost =
            try
            ((config?.exposeHost ?? [])
            + parsed.values("--expose-host").map {
                guard let port = UInt16($0), port > 0 else {
                    throw UsageError(message: "--expose-host wants a port, got '\($0)'")
                }
                return port
            })
        options.dnsResolvers = parsed.values("--dns-resolver") + (config?.dnsResolver.map { [$0] } ?? [])
        options.egress = EgressPolicy(
            allowHosts: (config?.network?.allow ?? []) + parsed.values("--allow-host"),
            secrets: try (config?.sandboxSecrets() ?? [])
                + parsed.values("--secret").map { try SandboxSecret.parse($0) })
        options.tmpfsTmp = !parsed.has("--no-tmpfs")
        options.tmpSizeMiB = parsed.value("--tmp-size").flatMap(UInt64.init)
        options.timeoutSeconds = parsed.value("--timeout").flatMap(Int64.init) ?? config?.timeout
        options.saveAs = saveAs

        // No command on a terminal is an interactive shell, as with
        // `shuru run`; -t on a pipe can't drive a pty.
        let onTerminal = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        options.tty = parsed.has("--tty") || (options.arguments.isEmpty && onTerminal && saveAs == nil)
        options.interactive = parsed.has("--interactive") || options.tty
        if options.tty && isatty(STDIN_FILENO) != 1 {
            throw UsageError(message: "-t needs a terminal on stdin")
        }
        if !options.dnsResolvers.isEmpty && options.networkMode == nil {
            throw UsageError(message: "--dns-resolver needs a network (--allow-net)")
        }
        if !options.egress.isEmpty && !options.network {
            throw UsageError(message: "--allow-host and --secret need --allow-net")
        }

        return try await SandboxVM.run(options) { msg in
            FileHandle.standardError.write(Data("sandbox: \(msg)\n".utf8))
        }
    }

    /// `--mount` semantics (shuru-compatible): the host copy is untouched
    /// unless `:rw` is asked for — and that must be opted into.
    static func mountSpec(_ spec: String, allowHostWrites: Bool) throws -> String {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else {
            throw UsageError(message: "--mount '\(spec)' — want host:/guest[:rw|ro]")
        }
        let host = (parts[0] as NSString).expandingTildeInPath
        switch parts.count == 3 ? parts[2] : "" {
        case "": return "\(host):\(parts[1]):overlay"
        case "ro": return "\(host):\(parts[1]):ro"
        case "rw":
            guard allowHostWrites else {
                throw UsageError(message: "--mount '\(spec)' writes to the host — add --allow-host-writes")
            }
            return "\(host):\(parts[1]):rw"
        default:
            throw UsageError(message: "--mount '\(spec)' — mode must be rw or ro")
        }
    }

    static func checkpoint(_ args: [String]) async throws -> Int32 {
        switch args.first {
        case "create":
            guard args.count > 1, !args[1].hasPrefix("-") else {
                throw UsageError(message: "missing <name>")
            }
            return try await run(Array(args.dropFirst(2)), saveAs: args[1])
        case "ls", "list", nil:
            let items = SandboxVM.listCheckpoints()
            if items.isEmpty { print("no checkpoints") }
            for item in items {
                let mb = Double(item.sizeBytes) / 1_048_576
                print(
                    "\(item.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                        + String(format: "%7.0f MB  ", mb) + item.image)
            }
            return ExitCode.ok
        case "rm", "delete":
            let names = Array(args.dropFirst())
            guard !names.isEmpty else { throw UsageError(message: "missing <name>") }
            for name in names {
                try SandboxVM.deleteCheckpoint(name)
                print("removed \(name)")
            }
            return ExitCode.ok
        default:
            throw UsageError(message: "unknown checkpoint command '\(args[0])'")
        }
    }

    static func prune() throws {
        let fm = FileManager.default
        for dir in ["images", "runs"] {
            let url = SandboxVM.root.appendingPathComponent(dir)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        print("pruned cached base disks and stale runs (checkpoints kept)")
    }
}

/// `micropod.json` — per-directory sandbox defaults (the same keys as
/// shuru.json, so a project's file carries over).
/// Flags win over the file; mounts use `--mount` semantics.
struct SandboxConfig: Decodable {
    var image: String?
    var from: String?
    var command: [String]?
    var cpus: Int?
    /// MiB.
    var memory: UInt64?
    /// MiB.
    var diskSize: UInt64?
    var allowNet: Bool?
    var allowHostWrites: Bool?
    var ports: [String]?
    var mounts: [String]?
    var exposeHost: [UInt16]?
    var dnsResolver: String?
    var env: [String]?
    var workdir: String?
    var timeout: Int64?
    var network: Network?
    /// The `secrets` map by guest env var name.
    var secrets: [String: Secret]?
    /// The directory holding the file: secret commands run there.
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    struct Network: Decodable {
        var allow: [String]?
    }

    /// `{"from": "ENV_VAR", "hosts": […]}` reads a host env var;
    /// `{"command": [argv…], "hosts": […], "ttl": "15m"}` runs a host command
    /// that mints (and re-mints) the value.
    struct Secret: Decodable {
        var from: String?
        var command: [String]?
        var hosts: [String]
        var ttl: String?
    }

    /// The `secrets` map as sandbox secrets, sorted by name.
    func sandboxSecrets(environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> [SandboxSecret]
    {
        try (secrets ?? [:]).sorted { $0.key < $1.key }.map { name, secret in
            switch (secret.from, secret.command) {
            case (let env?, nil):
                return try SandboxSecret.parse(
                    "\(name)=\(env)@\(secret.hosts.joined(separator: ","))", environment: environment)
            case (nil, let argv?) where !argv.isEmpty:
                var ttl: Duration?
                if let text = secret.ttl {
                    guard let parsed = SandboxSecretSpec.parseTTL(text) else {
                        throw UsageError(message: "secret \(name): ttl '\(text)' — want e.g. 90s, 15m, 1h")
                    }
                    ttl = parsed
                }
                return try SandboxSecret.from(
                    SandboxSecretSpec(name: name, command: argv, ttl: ttl, hosts: secret.hosts),
                    directory: directory)
            default:
                throw UsageError(message: "secret \(name): set exactly one of \"from\" or \"command\"")
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case image, from, command, cpus, memory, ports, mounts, env, workdir, timeout, network, secrets
        case diskSize = "disk_size"
        case allowNet = "allow_net"
        case allowHostWrites = "allow_host_writes"
        case exposeHost = "expose_host"
        case dnsResolver = "dns_resolver"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        command = try c.decodeIfPresent([String].self, forKey: .command)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        memory = try c.decodeIfPresent(UInt64.self, forKey: .memory)
        diskSize = try c.decodeIfPresent(UInt64.self, forKey: .diskSize)
        allowNet = try c.decodeIfPresent(Bool.self, forKey: .allowNet)
        allowHostWrites = try c.decodeIfPresent(Bool.self, forKey: .allowHostWrites)
        ports = try c.decodeIfPresent([String].self, forKey: .ports)
        mounts = try c.decodeIfPresent([String].self, forKey: .mounts)
        exposeHost = try c.decodeIfPresent([UInt16].self, forKey: .exposeHost)
        dnsResolver = try c.decodeIfPresent(String.self, forKey: .dnsResolver)
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir)
        timeout = try c.decodeIfPresent(Int64.self, forKey: .timeout)
        network = try c.decodeIfPresent(Network.self, forKey: .network)
        secrets = try c.decodeIfPresent([String: Secret].self, forKey: .secrets)
        // `env` as ["K=V"] or {"K": "V"}.
        if let list = try? c.decodeIfPresent([String].self, forKey: .env) {
            env = list
        } else if let map = try c.decodeIfPresent([String: String].self, forKey: .env) {
            env = map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
    }

    /// `--config PATH`, else `./micropod.json` when present, else nil.
    static func load(explicit path: String?) throws -> SandboxConfig? {
        let url = URL(fileURLWithPath: path ?? "micropod.json")
        guard path != nil || FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            var config = try JSONDecoder().decode(SandboxConfig.self, from: Data(contentsOf: url))
            config.directory = url.deletingLastPathComponent().standardizedFileURL
            return config
        } catch {
            throw UsageError(message: "\(url.path): \(error.localizedDescription)")
        }
    }
}
