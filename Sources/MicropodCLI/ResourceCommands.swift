import Foundation
import MicropodCore

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
        case "prune": try await volumePrune(services)
        default:
            if sub.hasPrefix("-") {
                try await volumeList(args, services)
            } else {
                throw UsageError(message: "unknown volumes subcommand '\(sub)'")
            }
        }
    }

    static func volumeList(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: ["-q"], valueFlags: [], commandName: "volumes")
        let volumes = try await services.volumes.list()
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
        print(renderTable(headers: ["NAME", "DRIVER", "SIZE", "CREATED"], rows: rows))
    }

    static func volumeCreate(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--size", "--label", "--opt"],
            commandName: "volume create")
        guard let name = parsed.positionals.first else {
            throw UsageError(message: "volume create <name> [--size 1GB] [--label k=v] [--opt k=v]")
        }
        try await services.volumes.create(
            name: name,
            size: parsed.value("--size"),
            labels: parsed.values("--label"),
            options: parsed.values("--opt"))
        print("Created volume \(name)")
    }

    static func volumeRemove(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "volume rm")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "volume rm <name…>")
        }
        for name in parsed.positionals {
            try await services.volumes.delete(name)
            print("Deleted volume \(name)")
        }
    }

    static func volumePrune(_ services: Services) async throws {
        let report = try await services.volumes.prune()
        print(report.isEmpty ? "Pruned" : report)
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
                valueFlags: ["--username", "-u", "--password", "-p"],
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
