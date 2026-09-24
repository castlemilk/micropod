import Foundation
import MicropodCore
import MicropodRuntime

struct Services {
    let client: ContainerCLIClient
    let system: SystemService
    let containers: any ContainerServing
    let images: ImageService
    let volumes: VolumeService
    let networks: NetworkService
    let registry: RegistryService
    let machines: MachineService
    let stats: any StatsSampling
    let logs: any LogStreaming
    let compose: ComposeService
    let usage: UsageService
    let runtime: RuntimeServices

    init(cliPath: String?) async {
        let resolved =
            cliPath
            ?? ProcessInfo.processInfo.environment["MICROPOD_CONTAINER_CLI_PATH"]
            ?? "/usr/local/bin/container"
        client = ContainerCLIClient(executableURL: URL(fileURLWithPath: resolved))
        runtime = await RuntimeBackendResolver.resolve(client: client)
        system = SystemService(client: client)
        containers = runtime.containers
        images = ImageService(client: client)
        volumes = VolumeService(client: client)
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
        #if canImport(Darwin)
            setvbuf(stdout, nil, _IOLBF, 8192)
        #endif
        var args = Array(CommandLine.arguments.dropFirst())
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { Ansi.enabled = false }
        args.removeAll(where: { $0 == "--no-color" })
        jsonOutput = args.contains("--json")
        args.removeAll(where: { $0 == "--json" })
        if jsonOutput || !isTTY() { Ansi.enabled = false }
        var cliPath: String?
        if let idx = args.firstIndex(of: "--cli"), idx + 1 < args.count {
            cliPath = args[idx + 1]
            args.removeSubrange(idx...idx + 1)
        }

        guard let command = args.first else {
            print(helpText)
            exit(ExitCode.usage)
        }
        let rest = Array(args.dropFirst())

        let services = await Services(cliPath: cliPath)
        do {
            try await dispatch(command, rest, services)
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
        case "status": try await SystemCommands.status(args, services)
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

        Containers:
          ps [-a] [-s] [--json]              list containers (add -a for stopped, -s for stats)
          run <image> [args…]                create+start a container (default detached; -a to attach)
          create <image> [args…]             prepare a container without starting it
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

        Images:
          images [--json]                    list local images
          pull|push <ref> [--platform p]     registry transfer (streams progress)
          build <ctx> [--tag t]…             build via BuildKit shim
          tag <src> <target>                 retag an image
          rmi <ref> [--force]                delete an image
          save <ref> -o <path> / load -i <path>

        Resources:
          volumes / volume create|rm|prune   named volumes
          networks / network create|rm|prune networks
          registry ls|login|logout           registry credentials

        Stacks & system:
          compose up <file> [--profile p,…]  dependency-ordered compose up with readiness probes
          compose down <name> / compose ps <name>
          df [--json]                        disk usage by category
          share mount|list|inspect|sync|gc   synchronized file shares
          build-cache stats|inspect        content-addressed build contexts
          machines [--json]                  runtime VMs (create/run/stop/rm for keep-alive CI)
          system start|stop|logs             daemon control + log access
          status / version                   runtime + version info

        Global flags:
          --json                             machine-readable output where supported
          --cli <path>                       override container CLI path
                                             (env MICROPOD_CONTAINER_CLI_PATH also honored)
          --no-color                         disable ANSI color
        """
}
