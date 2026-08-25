import Foundation
import MicropodCore

enum ComposeCommands {
    static func dispatch(_ args: [String], _ services: Services) async throws {
        guard let sub = args.first else {
            throw UsageError(message: "compose up|down|ps <file-or-name>")
        }
        switch sub {
        case "up": try await up(Array(args.dropFirst()), services)
        case "down": try await down(Array(args.dropFirst()), services)
        case "ps": try await ps(Array(args.dropFirst()), services)
        case "config": try await config(Array(args.dropFirst()), services)
        default:
            throw UsageError(message: "unknown compose subcommand '\(sub)'")
        }
    }

    static func resolveSpecPath(_ pathArg: String?) -> URL {
        let raw = pathArg ?? "docker-compose.yml"
        let url = URL(fileURLWithPath: raw)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if !raw.hasSuffix(".yml") && !raw.hasSuffix(".yaml") {
            for name in ["docker-compose.yml", "compose.yml", "docker-compose.yaml"] {
                let candidate = url.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return url
    }

    static func up(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--pull", "--build"],
            valueFlags: ["--profile", "--name"],
            commandName: "compose up")
        let specURL = resolveSpecPath(parsed.positionals.first)
        let spec = try await services.compose.parse(url: specURL)
        let profiles = Set(parsed.values("--profile").flatMap { $0.split(separator: ",").map(String.init) })
        let plan = try services.compose.plan(spec: spec, enabledProfiles: profiles)
        guard !plan.steps.isEmpty else {
            print("Nothing to do — no active services in \(specURL.lastPathComponent)")
            return
        }
        print(Ansi.paint("compose \(plan.composeName): \(plan.steps.count) steps from \(specURL.path)", Ansi.dim))
        let stream = await services.compose.up(plan: plan)
        for try await message in stream {
            print("  \(message)")
        }
        print(Ansi.ok("stack \(plan.composeName) is up"))
    }

    static func down(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "compose down")
        var composeName = parsed.positionals.first ?? ""
        if composeName.isEmpty, parsed.positionals.isEmpty {
            let spec = try await services.compose.parse(url: resolveSpecPath(nil))
            composeName = spec.name
        }
        guard !composeName.isEmpty else {
            throw UsageError(message: "compose down <name> (or run from a directory containing a compose file)")
        }
        try await services.compose.down(composeName: composeName)
        print(Ansi.ok("stack \(composeName) is down"))
    }

    static func ps(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "compose ps")
        guard let composeName = parsed.positionals.first else {
            throw UsageError(message: "compose ps <name>")
        }
        let containers = try await services.containers.list().filter {
            $0.labels["com.skunkworq.micropod.compose"] == composeName
        }
        if MicropodCLI.jsonOutput {
            emitJSON(containers)
            return
        }
        let rows = containers.map { container -> [String] in
            let service = container.labels["com.skunkworq.micropod.service"] ?? container.id
            return [
                service,
                container.id,
                Ansi.state(container.state),
                container.ipv4Address.isEmpty ? "—" : container.ipv4Address,
            ]
        }
        print(renderTable(headers: ["SERVICE", "CONTAINER", "STATE", "IP"], rows: rows))
    }

    static func config(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--profile"],
            commandName: "compose config")
        let spec = try await services.compose.parse(url: resolveSpecPath(parsed.positionals.first))
        let profiles = Set(parsed.values("--profile"))
        let plan = try services.compose.plan(spec: spec, enabledProfiles: profiles)
        print("compose name: \(plan.composeName)")
        print("steps:")
        for step in plan.steps {
            switch step {
            case .network(let network):
                print("  network  \(network.name)")
            case .volume(let volume):
                print("  volume   \(volume.name)")
            case .pull(let image, _):
                print("  pull     \(image)")
            case .build(_, let tag):
                print("  build    \(tag)")
            case .run(let request):
                print("  run      \(request.name ?? request.image)")
            case .readiness(let service):
                print("  probe    \(service.containerName): \(service.healthcheckCommand)")
            }
        }
    }
}
