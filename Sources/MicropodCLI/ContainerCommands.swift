import Foundation
import MicropodCore

enum ContainerCommands {
    static let lifecycleFlags: Set<String> = [
        "--all", "--force", "--time",
    ]

    static func ps(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--all", "-a", "--quiet", "-q", "--stats", "-s"],
            valueFlags: ["--state"],
            commandName: "ps")
        var containers = try await services.containers.list()
        if !parsed.has("--all"), let stateFilter = parsed.value("--state") {
            containers = containers.filter { $0.state.lowercased() == stateFilter.lowercased() }
        } else if !parsed.has("--all") {
            containers = containers.filter { $0.state.lowercased() == "running" }
        }
        if parsed.has("-q") {
            for container in containers { print(container.id) }
            return
        }
        if MicropodCLI.jsonOutput {
            emitJSON(containers)
            return
        }

        var statsByID = [String: Micropod_V1_ContainerStats]()
        if parsed.has("--stats") || parsed.has("-s") {
            let snapshot = try await services.stats.snapshot()
            statsByID = Dictionary(snapshot.containers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        let rows = containers.map { container -> [String] in
            var row = [
                container.id,
                container.image,
                Ansi.state(container.state),
            ]
            if let stats = statsByID[container.id] {
                row.append(String(format: "%.1f%%", stats.cpuPercent))
                row.append("\(ByteFormat.string(stats.memoryUsedBytes))/\(ByteFormat.string(stats.memoryLimitBytes))")
            } else if parsed.has("--stats") || parsed.has("-s") {
                row.append("—")
                row.append("—")
            }
            row.append(container.ipv4Address.isEmpty ? "—" : container.ipv4Address)
            let ports = container.publishedPorts
                .map { "\($0.hostPort):\($0.containerPort)/\($0.protocol)" }
                .joined(separator: ",")
            row.append(ports.isEmpty ? "—" : ports)
            if container.state.lowercased() != "running", !container.exitCode.isEmpty {
                row.append(relativeAge(from: container.createdAt) + " (exit \(container.exitCode))")
            } else {
                row.append(relativeAge(from: container.createdAt))
            }
            return row
        }
        var headers = ["ID", "IMAGE", "STATE"]
        if parsed.has("--stats") || parsed.has("-s") {
            headers += ["CPU", "MEMORY"]
        }
        headers += ["IP", "PORTS", "CREATED"]
        print(renderTable(headers: headers, rows: rows))
    }

    enum SimpleAction {
        case start, stop, restart, kill

        var verb: String {
            switch self {
            case .start: return "Started"
            case .stop: return "Stopped"
            case .restart: return "Restarted"
            case .kill: return "Killed"
            }
        }
    }

    static func simpleAction(_ args: [String], _ services: Services, action: SimpleAction) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--all"],
            valueFlags: ["--time"],
            commandName: action.verb.lowercased())
        if parsed.has("--all") {
            guard action == .stop else {
                throw UsageError(message: "\(action.verb.lowercased()) --all is only supported for stop")
            }
            try await services.containers.stopAll()
            print("Stopped all running containers")
            return
        }
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "\(action.verb.lowercased()) <id…>")
        }
        let timeout = parsed.intValue("--time", default: 10)
        for id in parsed.positionals {
            switch action {
            case .start:
                try await services.containers.start(id)
            case .stop:
                try await services.containers.stop(id, timeout: timeout)
            case .restart:
                try await services.containers.restart(id)
            case .kill:
                try await services.containers.kill(id)
            }
            print("\(action.verb) \(id)")
        }
    }

    static func remove(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--force", "-f", "--all"],
            valueFlags: [],
            commandName: "rm")
        if parsed.has("--all") {
            try await services.containers.deleteAll(force: true)
            print("Deleted all containers")
            return
        }
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "rm <id…> [--force]")
        }
        let force = parsed.has("--force") || parsed.has("-f")
        for id in parsed.positionals {
            try await services.containers.delete(id, force: force)
            print("Deleted \(id)")
        }
    }

    static func run(_ args: [String], _ services: Services, create: Bool) async throws {
        let boolFlags: Set<String> = [
            "--attach", "-a", "--tty", "-t", "--interactive", "-i", "--init",
            "--read-only", "--rosetta",
        ]
        let valueFlags: Set<String> = [
            "--name", "--env", "-e", "--env-file", "--publish", "-p", "--volume", "-v",
            "--tmpfs", "--label", "-l", "--network", "--memory", "-m", "--cpus",
            "--entrypoint", "--workdir", "-w", "--user", "-u", "--platform",
            "--shm-size", "--dns", "--dns-search", "--cap-add", "--cap-drop", "--ulimit",
        ]
        let aliases = [
            "-e": "--env", "-p": "--publish", "-v": "--volume", "-l": "--label",
            "-m": "--memory", "-w": "--workdir", "-u": "--user",
        ]
        let expanded = expandAliases(args, aliases: aliases)
        let parsed = try parseArgs(expanded, boolFlags: boolFlags, valueFlags: valueFlags, commandName: "run")
        guard let image = parsed.positionals.first else {
            throw UsageError(message: "run [flags] <image> [args…]")
        }
        let request = buildRunRequest(parsed, image: image)
        if create {
            let id = try await services.containers.create(request)
            print("Created \(id)")
            return
        }
        if parsed.has("--attach") {
            var attached = request
            attached.detach = false
            for try await chunk in services.client.stream(ContainerCommandFactory.run(attached)) {
                FileHandle.standardOutput.write(chunk)
            }
            return
        }
        let id = try await services.containers.run(request)
        print(MicropodCLI.jsonOutput ? "{\"id\":\"\(id)\"}" : id)
    }

    static func buildRunRequest(_ parsed: ParsedArgs, image: String) -> ContainerRunRequest {
        ContainerRunRequest(
            image: image,
            name: parsed.value("--name"),
            detach: !parsed.has("--attach"),
            cpus: parsed.doubleValue("--cpus"),
            memory: parsed.value("--memory"),
            env: parsed.values("--env"),
            envFiles: parsed.values("--env-file"),
            publishedPorts: parsed.values("--publish").flatMap(parsePorts),
            volumes: parsed.values("--volume"),
            tmpfs: parsed.values("--tmpfs"),
            labels: parsed.values("--label").flatMap(parseKeyValuePairs).map {
                LabelSpec(key: $0.key, value: $0.value)
            },
            interactive: parsed.has("--interactive"),
            tty: parsed.has("--tty"),
            useInit: parsed.has("--init"),
            readOnly: parsed.has("--read-only"),
            rosetta: parsed.has("--rosetta"),
            user: parsed.value("--user"),
            shmSize: parsed.value("--shm-size"),
            dns: parsed.values("--dns"),
            dnsSearch: parsed.values("--dns-search"),
            capAdd: parsed.values("--cap-add"),
            capDrop: parsed.values("--cap-drop"),
            ulimits: parsed.values("--ulimit"),
            networks: parsed.values("--network"),
            platform: parsed.value("--platform"),
            workdir: parsed.value("--workdir"),
            entrypoint: parsed.value("--entrypoint"),
            arguments: Array(parsed.positionals.dropFirst()))
    }

    static func parsePorts(_ spec: String) -> [PortSpec] {
        var parts = spec.split(separator: "/")
        let proto = parts.count > 1 ? String(parts.removeLast()).lowercased() : "tcp"
        let mapping = parts.joined(separator: "/").split(separator: ":")
        guard let containerPort = Int(mapping.last ?? "") else { return [] }
        let hostPort = mapping.count > 1 ? Int(mapping[0]) ?? containerPort : containerPort
        return [PortSpec(hostPort: hostPort, containerPort: containerPort, transportProtocol: proto)]
    }

    static func parseKeyValuePairs(_ spec: String) -> [(key: String, value: String)] {
        guard let eq = spec.firstIndex(of: "=") else {
            return [(key: spec, value: "")]
        }
        return [(key: String(spec[spec.startIndex..<eq]), value: String(spec[spec.index(after: eq)...]))]
    }

    static func exec(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--tty", "-t", "--interactive", "-i", "--detach", "-d"],
            valueFlags: ["--user", "-u", "--workdir", "-w", "--env", "-e"],
            commandName: "exec")
        guard parsed.positionals.count >= 2 else {
            throw UsageError(message: "exec <id> <command> [args…]")
        }
        let request = ContainerExecRequest(
            containerID: parsed.positionals[0],
            arguments: Array(parsed.positionals.dropFirst()),
            interactive: parsed.has("--interactive"),
            tty: parsed.has("--tty"),
            detach: parsed.has("--detach"),
            user: parsed.value("--user"),
            workdir: parsed.value("--workdir"),
            env: parsed.values("--env"))
        let output = try await services.containers.exec(request)
        print(output.trimmingCharacters(in: .newlines))
    }

    static func logs(_ args: [String], _ services: Services) async throws {
        let expanded = expandAliases(args, aliases: ["-n": "--tail"])
        let parsed = try parseArgs(
            expanded,
            boolFlags: ["--follow", "-f", "--boot"],
            valueFlags: ["--tail"],
            commandName: "logs")
        guard let id = parsed.positionals.first else {
            throw UsageError(message: "logs <id> [-f] [-n N]")
        }
        let tail = parsed.intValue("--tail", default: 100)
        if parsed.has("--follow") {
            for try await line in services.logs.stream(id: id, tail: tail, boot: parsed.has("--boot")) {
                print(line.text, terminator: "\n")
            }
        } else {
            let lines = try await services.logs.tail(id: id, lines: tail, boot: parsed.has("--boot"))
            for line in lines { print(line.text) }
        }
    }

    static func inspect(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--raw"],
            valueFlags: [],
            commandName: "inspect")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "inspect <id…>")
        }
        var chunks = [String]()
        for id in parsed.positionals {
            let data = try await services.containers.inspect(id)
            if parsed.has("--raw") {
                chunks.append(String(data: data, encoding: .utf8) ?? "")
                continue
            }
            let object = try JSONSerialization.jsonObject(with: data)
            if parsed.positionals.count == 1 {
                chunks.append(try prettyJSON(object))
            } else {
                chunks.append("// \(id)\n" + (try prettyJSON(object)))
            }
        }
        print(chunks.joined(separator: "\n\n"))
    }

    static func prettyJSON(_ object: Any) throws -> String {
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: pretty, encoding: .utf8) ?? ""
    }

    static func export(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--output", "-o"],
            commandName: "export")
        guard let id = parsed.positionals.first else {
            throw UsageError(message: "export <id> -o <path>")
        }
        guard let path = parsed.value("--output") ?? parsed.value("-o") else {
            throw UsageError(message: "export requires -o <path>")
        }
        try await services.containers.export(id, to: path)
        print("Exported \(id) → \(path)")
    }

    static func copy(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "cp")
        guard parsed.positionals.count == 2 else {
            throw UsageError(message: "cp <src> <dst>  (container paths as containerID:/path)")
        }
        try await services.containers.copy(from: parsed.positionals[0], to: parsed.positionals[1])
        print("Copied \(parsed.positionals[0]) → \(parsed.positionals[1])")
    }

    static func prune(_ args: [String], _ services: Services) async throws {
        _ = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "prune")
        let report = try await services.containers.prune()
        print(report.isEmpty ? "Pruned" : report)
    }
}
