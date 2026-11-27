import Foundation
import MicropodCore
import MicropodRuntime

struct Services {
    let client: ContainerCLIClient
    let system: SystemService
    let containers: any ContainerServing
    /// Apple's image and volume services, routed like `containers` across
    /// the enabled engines that keep their own (pass-through when none do).
    let images: ImageRouter
    let volumes: VolumeRouter
    let networks: NetworkService
    let registry: RegistryService
    let machines: MachineService
    let stats: any StatsSampling
    let logs: any LogStreaming
    let compose: ComposeService
    let usage: UsageService
    let runtime: RuntimeServices

    init(cliPath: String?) async {
        client = ContainerCLIClient(executableURL: cliPath.map { URL(fileURLWithPath: $0) })
        runtime = await RuntimeBackendResolver.resolve(client: client)
        system = SystemService(client: client)
        containers = runtime.containers
        images = ImageRouter(apple: ImageService(client: client), registry: runtime.router?.registry)
        volumes = VolumeRouter(apple: VolumeService(client: client), registry: runtime.router?.registry)
        networks = NetworkService(client: client)
        registry = RegistryService(client: client)
        machines = MachineService(client: client)
        stats = runtime.stats
        logs = runtime.logs
        compose = ComposeService(client: client)
        usage = UsageService(containers: containers, images: images, volumes: volumes)
    }
}

enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

@main
struct MicropodCLI {
    nonisolated(unsafe) static var jsonOutput = false
    nonisolated(unsafe) static var exitOverride: Int32?

    static func main() async {
        // First: anything written under ~/.micropod before it would make a
        // fresh install look like an existing one.
        InstallOrigin.resolve()
        #if canImport(Darwin)
            setvbuf(stdout, nil, _IOLBF, 8192)
        #endif
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "update" {
            let json = args.contains("--json")
            exit(await UpdateCommands.main(Array(args.dropFirst()).filter { $0 != "--json" }, json: json))
        }
        if args.first == "storage" {
            let json = args.contains("--json")
            exit(await StorageCommands.main(Array(args.dropFirst()).filter { $0 != "--json" }, json: json))
        }
        if args.first == "ci" {
            exit(await CICommands.main(Array(args.dropFirst())))
        }
        if args.first == "telemetry" {
            exit(await TelemetryCommands.main(Array(args.dropFirst())))
        }
        if args.first == "config" {
            exit(await TelemetryCommands.mainConfigAlias(Array(args.dropFirst())))
        }
        if args.first == "sandbox" {
            exit(await SandboxCommands.main(Array(args.dropFirst())))
        }
        // Global flags may come before the command (`micropod --json machine status`).
        if let cache = CacheCommands.route(args) {
            exit(await CacheCommands.main(cache.args, json: cache.json))
        }
        if let machine = MachineCommands.route(args) {
            exit(await MachineCommands.main(machine.args, json: machine.json))
        }
        if let docker = DockerCommands.route(args) {
            exit(await DockerCommands.main(docker.args, json: docker.json))
        }
        if let status = StatusCommand.route(args) {
            exit(await StatusCommand.main(status.args, json: status.json, cliPath: status.cliPath))
        }
        let globals = GlobalArguments(args)
        jsonOutput = globals.json
        if globals.noColor || ProcessInfo.processInfo.environment["NO_COLOR"] != nil || jsonOutput || !isTTY() {
            Ansi.enabled = false
        }

        guard let command = globals.arguments.first else {
            print(helpText)
            exit(ExitCode.usage)
        }
        let rest = Array(globals.arguments.dropFirst())

        let services = await Services(cliPath: globals.cliPath)
        do {
            try await dispatch(command, rest, services)
            UpdateNotice.run(json: jsonOutput)
            exit(exitOverride ?? ExitCode.ok)
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            exit(ExitCode.usage)
        } catch is CancellationError {
            exit(ExitCode.ok)
        } catch {
            let prefix = Ansi.enabled ? Ansi.red : ""
            let suffix = Ansi.enabled ? Ansi.reset : ""
            FileHandle.standardError.write(
                Data("\(prefix)error:\(suffix) \(errorMessage(error))\n".utf8))
            exit(exitOverride ?? ExitCode.failure)
        }
    }

    static func isTTY() -> Bool {
        #if canImport(Darwin)
            return isatty(STDOUT_FILENO) == 1
        #else
            return false
        #endif
    }

    static func dispatch(_ command: String, _ args: [String], _ services: Services) async throws {
        switch command {
        case "ps", "list", "ls": try await ContainerCommands.ps(args, services)
        case "run": try await ContainerCommands.run(args, services, create: false)
        case "create": try await ContainerCommands.run(args, services, create: true)
        case "start": try await ContainerCommands.simpleAction(args, services, action: .start)
        case "stop": try await ContainerCommands.simpleAction(args, services, action: .stop)
        case "restart": try await ContainerCommands.simpleAction(args, services, action: .restart)
        case "kill": try await ContainerCommands.simpleAction(args, services, action: .kill)
        case "rm", "delete": try await ContainerCommands.remove(args, services)
        case "exec": try await ContainerCommands.exec(args, services)
        case "logs": try await ContainerCommands.logs(args, services)
        case "inspect": try await ContainerCommands.inspect(args, services)
        case "export": try await ContainerCommands.export(args, services)
        case "cp", "copy": try await ContainerCommands.copy(args, services)
        case "prune": try await SystemCommands.systemPrune(args, services)
        case "stats": try await MonitorCommands.statsOnce(args, services)
        case "metrics": try MonitorCommands.metrics(args)
        case "top": try await MonitorCommands.top(args, services)
        case "watch", "events": try await MonitorCommands.watch(args, services)
        case "doctor", "debug": try await DebugCommands.doctor(args, services)

        case "images", "image":
            try await ImageCommands.listOrSubcommand(args, services)
        case "pull": try await ImageCommands.pull(args, services)
        case "push": try await ImageCommands.push(args, services)
        case "build": try await ImageCommands.build(args, services)
        case "tag": try await ImageCommands.tag(args, services)
        case "rmi": try await ImageCommands.rmi(args, services)
        case "save": try await ImageCommands.save(args, services)
        case "load": try await ImageCommands.load(args, services)

        case "volumes", "volume":
            try await ResourceCommands.volumes(args, services)
        case "networks", "network":
            try await ResourceCommands.networks(args, services)
        case "registry":
            try await ResourceCommands.registry(args, services)

        case "compose": try await ComposeCommands.dispatch(args, services)
        case "k8s", "kubernetes": try await K8sCommands.run(args, services)
        case "runtime", "runtimes": try await RuntimeCommands.run(args, services)

        case "df": try await SystemCommands.df(args, services)
        case "machines", "machine":
            try await SystemCommands.machines(args, services)
        case "system": try await SystemCommands.system(args, services)
        case "share": try await SharedCommands.run(args)
        case "build-cache", "buildcache": try await BuildCacheCommands.run(args)

        case "version": try await SystemCommands.version(services)
        case "help", "--help", "-h": print(helpText)
        default:
            throw UsageError(message: "unknown command '\(command)' — run `micropod help`")
        }
    }

    static let helpText = """
        micropod — CLI for the Apple container runtime

        Usage: micropod <command> [flags] [args]

        CI worker:
          ci runner-start|status|health|stop manage the dedicated HVF/containerd CI worker
          ci docker|run|snapshot|job         run builds, compose stacks, cached & native OCI jobs

        Observability & configuration:
          cache status|ls|explain|dedupe|prune|policy
                                             unified L0/L1 cache usage, diagnosis, pruning & proxy policy
          telemetry init|show|set|validate   manage YAML config (~/.micropod/observability.yaml)
          telemetry enable|disable <target>  toggle prometheus, otlp, or tracing (live on VM!)
          telemetry health|metrics           live engine/workload health, Prometheus & OTLP metrics
          telemetry trace status|enable|dump on-demand distributed tracing & bottleneck breakdown
          config init|show|set|validate      alias for telemetry YAML configuration management

        Containers:
          ps [-a] [-s] [--json]              list containers (add -a for stopped, -s for stats)
          run <image> [args…]                create+start a container (default detached; -a to attach)
          create <image> [args…]             prepare a container without starting it
            run|create --cache auto|off|<tools> --cache-scope <scope>
                                             dependency caches on the hvf machine (labels
                                             io.micropod.cache[.scope]); tools: go,npm,pnpm,yarn,
                                             yarnberry,pip,uv,cargo,corepack,maven,gradle,bun,
                                             sccache,playwright (+tool / -tool)
          start|stop|restart|kill <id…>      lifecycle actions (stop --all supported)
          rm <id…> [--force] [--all]         remove containers
          exec <id> <cmd…>                   run a command in a running container
          logs <id> [-f] [-n N] [--boot]     container logs (stream with -f)
          inspect <id…>                      pretty-printed inspect JSON (--raw for raw output)
          export <id> -o <path>              export container filesystem
          cp <src> <dst>                     copy files between container and host
          prune                              prune stopped containers

        Monitoring & debugging:
          top [-i 2]                         live per-container CPU/mem/net monitor
          watch [-i 2] [--json]              state-transition event feed (created/removed/started/died)
          doctor                             full runtime diagnostic report
          system logs [--last 5m] [-f]       backing apiserver logs (the debug surface)
          stats [--json]                     one-shot resource snapshot

        Images (--runtime r on each picks an engine; listings merge every enabled one):
          images [--json]                    list local images
          pull|push <ref> [--platform p]     registry transfer (streams progress)
          build <ctx> [--tag t]…             build via BuildKit shim
          tag <src> <target>                 retag an image
          rmi <ref> [--force]                delete an image
          save <ref> -o <path> / load -i <path>

        Resources:
          volumes / volume create|rm|prune   named volumes (--runtime r, as for images)
          networks / network create|rm|prune networks
          registry ls|login|logout           registry credentials

        Stacks & system:
          compose up <file> [--profile p,…]  dependency-ordered compose up with readiness probes
          compose down <name> / compose ps <name>
          df [--json]                        disk usage by category
          share mount|list|inspect|sync|gc   synchronized file shares
          build-cache stats|inspect        content-addressed build contexts
          machines [--json]                  runtime VMs (create/run/stop/rm for keep-alive CI)
          sandbox run|checkpoint             ephemeral micro-VM per command (CI fast path)
          runtime ls|use|enable|disable      execution engines: apple, docker, sandbox, ci, hvf
          machines stats [name]|logs <name>  VM metrics / stdio+boot logs (-f, -n N, --boot)
          machine install|start|stop|restart|status|logs|serve|docker-endpoint|buildkit-endpoint
          machine autostart on|off|status    start the machine at login and stop it cleanly at logout
          machine cache policy|builder install|status|rm
                                             the shared hvf Linux machine behind --runtime hvf
                                             (`micropod machine help`)
          docker install [--use]|uninstall|status
                                             docker context `micropod` on the hvf machine for the
                                             docker CLI, compose and buildx; --use selects it
                                             (`micropod docker help`)
          k8s enable|up|down|status          lightweight Kubernetes (opt-in; k3s micro-VM + MetalLB)
          k8s load <ref|file.tar>|images     push images into the cluster via the host puller
          system start|stop|logs             daemon control + log access
          update [status|check|apply|cli]    keep the app and this CLI current
          storage [show|volumes|set <dir>]  where runtime data lives; move it to another volume
          storage dev-volume                create and manage a development APFS volume
          metrics [id] [--range 1h] [--machine]  recorded resource history (peak/avg/now + sparkline)
          status [--json]                    the hvf machine (state, engine, containers, cache disk,
                                             disk flush, update, autostart), its docker endpoint and
                                             the API; the Apple runtime too when it is enabled
          version                            version info

        Global flags:
          --json                             machine-readable output where supported
          --cli <path>                       override container CLI path
                                             (env MICROPOD_CONTAINER_CLI_PATH also honored)
          --no-color                         disable ANSI color
        """
}
