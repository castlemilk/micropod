import Foundation
import MicropodCore
import MicropodRuntime

/// `micropod docker …`: the docker CLI, compose and buildx on the hvf
/// machine through a docker context named `micropod`. Dispatched before
/// `Services` resolution: none of it needs the Apple runtime, and none of
/// it starts the machine.
enum DockerCommands {
    static let helpText = """
        micropod docker — use the docker CLI, compose and buildx with the hvf machine

        Usage:
          micropod docker install [--use] [--builder auto|remote|none] [--force] [--system-socket] [--json]
                                    docker context `micropod` on the machine's Docker socket
                                    (<root>/run/docker.sock). Without --use the current context is
                                    never changed; --use selects `micropod` and records the context
                                    it replaces, which `uninstall` selects again.
                                    --builder auto (default): the context's own builder when the
                                    engine builds on its Docker socket, else the remote builder
                                    micropod-buildkit; remote: always micropod-buildkit; none: no
                                    builder is added.
                                    --force repoints a `micropod` context that names another endpoint.
                                    --system-socket also prints the sudo command that links
                                    /var/run/docker.sock here, for clients that ignore contexts; it
                                    runs nothing.
          micropod docker uninstall [--force] [--json]
                                    selects the recorded previous context (else `default`) when
                                    `micropod` is current, then removes micropod-buildkit and the
                                    context if they are this machine's (--force: a `micropod`
                                    context that points elsewhere too)
          micropod docker status [--json]
                                    the docker CLI and its API version, the context and whether it
                                    is selected, DOCKER_HOST / DOCKER_CONTEXT set in this shell,
                                    compose, buildx, the builder, credential helpers, other
                                    runtimes' contexts, ~/.micropod/docker.sock and
                                    /var/run/docker.sock

        None of these starts the machine (`micropod machine start`). Contexts change only
        through the docker CLI (MICROPOD_DOCKER_CLI, else `docker` on PATH), so DOCKER_CONFIG
        decides whose docker configuration changes. Problems that do not stop the command
        (a missing plugin, a shell override, a stopped machine) are printed as `note:` lines
        on stderr. `micropod machine builder` is the lower-level form of the builder part.
        """

    /// The docker command in a whole `micropod` argv, if it is one: the
    /// arguments after `docker`, with the global flags (`--json`,
    /// `--no-color`, `--cli <path>`) removed wherever they sit.
    static func route(_ argv: [String]) -> (args: [String], json: Bool)? {
        var args = argv
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" || $0 == "--no-color" }
        if let index = args.firstIndex(of: "--cli"), index + 1 < args.count {
            args.removeSubrange(index...index + 1)
        }
        guard args.first == "docker" else { return nil }
        return (Array(args.dropFirst()), json)
    }

    static func main(_ args: [String], json: Bool) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let client = HVFMachineClient(environment: environment)
        let sub = args.first ?? "status"
        let rest = Array(args.dropFirst())
        do {
            switch sub {
            case "help", "--help", "-h":
                print(helpText)
            case "install":
                let parsed = try parseArgs(
                    rest, boolFlags: ["--use", "--force", "--system-socket"], valueFlags: ["--builder"],
                    commandName: "docker install")
                guard parsed.positionals.isEmpty else {
                    throw UsageError(message: "docker install takes no positional arguments")
                }
                let mode = try builderMode(parsed.value("--builder"))
                let wiring = HVFDockerWiring(layout: client.layout, environment: environment)
                var outcome = try wiring.install(
                    use: parsed.has("--use"), builder: mode, force: parsed.has("--force"),
                    machine: await machine(client))
                if parsed.has("--system-socket") { outcome.manual += wiring.systemSocketAdvice() }
                try emit(outcome, json: json)
            case "uninstall", "rm", "remove":
                let parsed = try parseArgs(
                    rest, boolFlags: ["--force"], valueFlags: [], commandName: "docker uninstall")
                guard parsed.positionals.isEmpty else {
                    throw UsageError(message: "docker uninstall takes no positional arguments")
                }
                let wiring = HVFDockerWiring(layout: client.layout, environment: environment)
                try emit(try wiring.uninstall(force: parsed.has("--force")), json: json)
            case "status":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "docker status")
                let wiring = HVFDockerWiring(
                    layout: client.layout, environment: environment, runner: HVFProcessRunner(timeout: .seconds(10)))
                try show(wiring.status(machine: await machine(client)), json: json)
            default:
                throw UsageError(message: "docker install|uninstall|status (`micropod docker help`)")
            }
            return ExitCode.ok
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data("error: \(errorMessage(error))\n".utf8))
            return ExitCode.failure
        }
    }

    static func builderMode(_ raw: String?) throws -> HVFDockerWiring.BuilderMode {
        guard let raw else { return .auto }
        guard let mode = HVFDockerWiring.BuilderMode(rawValue: raw.lowercased()) else {
            throw UsageError(message: "docker install: --builder wants auto, remote or none, got '\(raw)'")
        }
        return mode
    }

    /// The machine as the wiring needs it; never boots it (the engine is
    /// asked for its build capability only while it serves).
    static func machine(_ client: HVFMachineClient) async -> HVFDockerWiring.Machine {
        let status = client.status()
        let capabilities = await client.capabilities()
        return HVFDockerWiring.Machine(
            missing: status.missing, phase: status.phase, dockerBuild: capabilities.dockerBuild)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func emit(_ outcome: HVFDockerWiring.Outcome, json: Bool) throws {
        if json {
            print(String(decoding: try encoder().encode(outcome), as: UTF8.self))
            return
        }
        for line in outcome.actions + outcome.manual { print(line) }
        note(outcome.notes)
    }

    static func note(_ notes: [String]) {
        for line in notes { FileHandle.standardError.write(Data("note: \(line)\n".utf8)) }
    }

    static func show(_ status: HVFDockerWiring.Status, json: Bool) throws {
        if json {
            print(String(decoding: try encoder().encode(status), as: UTF8.self))
            return
        }
        for (label, value) in lines(status) {
            print(label.padding(toLength: 17, withPad: " ", startingAt: 0) + value)
        }
        note(status.notes)
    }

    /// One `label: value` pair per status field, in display order.
    static func lines(_ status: HVFDockerWiring.Status) -> [(String, String)] {
        let cli: String
        if let path = status.dockerCLI.path {
            let version = status.dockerCLI.version.map { " \($0)" } ?? ""
            let api = status.dockerCLI.apiVersion.map { " (API \($0)\(status.dockerCLI.tooOld ? ", too old" : ""))" }
            cli = path + version + (api ?? "")
        } else {
            cli = "not found (set MICROPOD_DOCKER_CLI)"
        }
        let context: String
        switch status.context.state {
        case .ok?: context = "\(HVFDockerWiring.contextName) -> \(status.context.host ?? status.endpoint)"
        case .mismatch?:
            context =
                "\(HVFDockerWiring.contextName) -> \(status.context.host ?? "?") (not this machine: "
                + "`micropod docker install --force`)"
        case .absent?: context = "absent (`micropod docker install`)"
        case nil: context = "unknown" + (status.context.error.map { " (\($0))" } ?? "")
        }
        var current = status.currentContext ?? "unknown"
        if status.selected {
            current += " (selected" + (status.previousContext.map { "; uninstall restores \($0)" } ?? "") + ")"
        } else if status.context.state == .ok {
            current += " (\(HVFDockerWiring.contextName) not selected: `docker context use micropod`)"
        }
        let overrides =
            status.environmentOverride.isEmpty
            ? "none"
            : status.environmentOverride.keys.sorted().map { "\($0)=\(status.environmentOverride[$0] ?? "")" }
                .joined(separator: ", ")
        let credentials =
            status.credentialHelpers.isEmpty
            ? "no helper configured"
            : status.credentialHelpers.map {
                "\($0.key == "credsStore" ? "credsStore" : $0.key) \($0.name) (\($0.found ? "found" : "not on PATH"))"
            }.joined(separator: ", ")
        let others =
            status.otherRuntimes.isEmpty
            ? "none" : status.otherRuntimes.map { "\($0.name) \($0.endpoint ?? "?")" }.joined(separator: ", ")
        return [
            ("docker CLI:", cli),
            ("endpoint:", status.endpoint),
            ("context:", context),
            ("current context:", current),
            ("shell overrides:", overrides),
            ("compose:", status.compose.version ?? "missing"),
            ("buildx:", status.buildx.version ?? "missing"),
            ("builder:", status.builder),
            ("docker build:", status.dockerBuild.rawValue),
            ("credentials:", credentials),
            ("other runtimes:", others),
            ("canonical link:", "\(status.canonicalLink.path) \(status.canonicalLink.summary)"),
            ("system socket:", "\(status.systemSocket.path) \(status.systemSocket.summary)"),
            ("machine:", status.machinePhase),
        ]
    }
}
