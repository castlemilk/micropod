import Foundation
import MicropodCore
import MicropodRuntime

#if canImport(Darwin)
    import Darwin
#endif

enum ResourceCommands {
    static func volumes(_ args: [String], _ services: Services) async throws {
        guard let sub = args.first else {
            try await volumeList([], services)
            return
        }
        switch sub {
        case "ls", "list": try await volumeList(Array(args.dropFirst()), services)
        case "create": try await volumeCreate(Array(args.dropFirst()), services)
        case "rm", "delete": try await volumeRemove(Array(args.dropFirst()), services)
        case "prune": try await volumePrune(Array(args.dropFirst()), services)
        default:
            if sub.hasPrefix("-") {
                try await volumeList(args, services)
            } else {
                throw UsageError(message: "unknown volumes subcommand '\(sub)'")
            }
        }
    }

    static func volumeList(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: ["-q"], valueFlags: ["--runtime"], commandName: "volumes")
        let volumes = try await services.volumes.list(runtime: parsed.value("--runtime"))
        if parsed.has("-q") {
            for volume in volumes { print(volume.id) }
            return
        }
        if MicropodCLI.jsonOutput {
            emitJSON(volumes)
            return
        }
        let rows = volumes.map { volume in
            [
                volume.id,
                volume.driver,
                ByteFormat.string(volume.sizeBytes),
                relativeAge(from: volume.createdAt),
            ]
        }
        // A RUNTIME column only once more than one engine is in play, as in `ps`.
        let runtimes = volumes.map(RuntimeStamp.runtime(of:))
        if Set(runtimes).count > 1 {
            print(
                renderTable(
                    headers: ["NAME", "DRIVER", "SIZE", "CREATED", "RUNTIME"],
                    rows: zip(rows, runtimes).map { $0 + [$1] }))
            return
        }
        print(renderTable(headers: ["NAME", "DRIVER", "SIZE", "CREATED"], rows: rows))
    }

    /// " on <runtime>" after a result line when a non-Apple runtime was named.
    static func onRuntime(_ parsed: ParsedArgs) -> String {
        guard let runtime = parsed.value("--runtime"), !runtime.isEmpty, runtime != "apple" else { return "" }
        return " on \(runtime)"
    }

    static func volumeCreate(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--size", "--label", "--opt", "--runtime"],
            commandName: "volume create")
        guard let name = parsed.positionals.first else {
            throw UsageError(
                message: "volume create <name> [--size 1GB] [--label k=v] [--opt k=v] [--runtime r]")
        }
        try await services.volumes.create(
            name: name,
            size: parsed.value("--size"),
            labels: parsed.values("--label"),
            options: parsed.values("--opt"),
            runtime: parsed.value("--runtime"))
        print("Created volume \(name)\(onRuntime(parsed))")
    }

    static func volumeRemove(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: ["--runtime"], commandName: "volume rm")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "volume rm <name…> [--runtime r]")
        }
        for name in parsed.positionals {
            try await services.volumes.delete(name, runtime: parsed.value("--runtime"))
            print("Deleted volume \(name)\(onRuntime(parsed))")
        }
    }

    /// `volume prune` has always ignored its arguments (`-f` included); only
    /// `--runtime r` (or `--runtime=r`) means anything.
    static func volumePrune(_ args: [String], _ services: Services) async throws {
        let report = try await services.volumes.prune(runtime: runtimeFlag(in: args))
        print(report.isEmpty ? "Pruned" : report)
    }

    static func runtimeFlag(in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == "--runtime", index + 1 < args.count { return args[index + 1] }
            if arg.hasPrefix("--runtime=") { return String(arg.dropFirst("--runtime=".count)) }
        }
        return nil
    }

    static func networks(_ args: [String], _ services: Services) async throws {
        guard let sub = args.first else {
            try await networkList([], services)
            return
        }
        switch sub {
        case "ls", "list": try await networkList(Array(args.dropFirst()), services)
        case "create": try await networkCreate(Array(args.dropFirst()), services)
        case "rm", "delete": try await networkRemove(Array(args.dropFirst()), services)
        case "prune": try await networkPrune(services)
        default:
            if sub.hasPrefix("-") {
                try await networkList(args, services)
            } else {
                throw UsageError(message: "unknown networks subcommand '\(sub)'")
            }
        }
    }

    static func networkList(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: ["-q"], valueFlags: [], commandName: "networks")
        let networks = try await services.networks.list()
        if parsed.has("-q") {
            for network in networks { print(network.id) }
            return
        }
        if MicropodCLI.jsonOutput {
            emitJSON(networks)
            return
        }
        let rows = networks.map { network in
            [
                network.id,
                network.plugin,
                network.ipv4Subnet.isEmpty ? "—" : network.ipv4Subnet,
                network.builtin ? "yes" : "",
            ]
        }
        print(renderTable(headers: ["NAME", "PLUGIN/DRIVER", "SUBNET", "BUILTIN"], rows: rows))
    }

    static func networkCreate(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--internal"],
            valueFlags: ["--subnet", "--subnet-v6", "--driver", "--opt", "--label"],
            commandName: "network create")
        guard let name = parsed.positionals.first else {
            throw UsageError(message: "network create <name> [--subnet cidr] [--internal] [--driver d]")
        }
        try await services.networks.create(
            name: name,
            internal: parsed.has("--internal"),
            subnet: parsed.value("--subnet"),
            subnetV6: parsed.value("--subnet-v6"),
            driver: parsed.value("--driver"),
            options: parsed.values("--opt"),
            labels: parsed.values("--label"))
        print("Created network \(name)")
    }

    static func networkRemove(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "network rm")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "network rm <name…>")
        }
        for name in parsed.positionals {
            try await services.networks.delete(name)
            print("Deleted network \(name)")
        }
    }

    static func networkPrune(_ services: Services) async throws {
        let report = try await services.networks.prune()
        print(report.isEmpty ? "Pruned" : report)
    }

    static func registry(_ args: [String], _ services: Services) async throws {
        guard let sub = args.first else {
            throw UsageError(message: "registry ls|login|logout")
        }
        switch sub {
        case "ls", "list":
            let logins = try await services.registry.list()
            if MicropodCLI.jsonOutput {
                emitJSON(logins)
                return
            }
            let rows = logins.map { login in [login.server, login.username, login.scheme] }
            print(renderTable(headers: ["SERVER", "USERNAME", "SCHEME"], rows: rows))
        case "login":
            let parsed = try parseArgs(
                Array(args.dropFirst()),
                boolFlags: [],
                valueFlags: ["--username", "--password"],
                aliases: ["-u": "--username", "-p": "--password"],
                commandName: "registry login")
            guard let server = parsed.positionals.first else {
                throw UsageError(message: "registry login <server> -u user [-p pass]")
            }
            var username = parsed.value("--username") ?? ""
            var password = parsed.value("--password") ?? ""
            if username.isEmpty {
                print("Username: ", terminator: "")
                username = readLine() ?? ""
            }
            if password.isEmpty {
                password = String(cString: getpass("Password: "))
            }
            try await services.registry.login(server: server, username: username, password: password)
            print("Logged in to \(server)")
        case "logout":
            let parsed = try parseArgs(
                Array(args.dropFirst()), boolFlags: [], valueFlags: [], commandName: "registry logout")
            guard let server = parsed.positionals.first else {
                throw UsageError(message: "registry logout <server>")
            }
            try await services.registry.logout(server)
            print("Logged out of \(server)")
        default:
            throw UsageError(message: "unknown registry subcommand '\(sub)'")
        }
    }
}
