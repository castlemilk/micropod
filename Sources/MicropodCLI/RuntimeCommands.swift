import Foundation
import MicropodCore
import MicropodRuntime

/// `micropod runtime` — list and configure execution engines (apple VMs,
/// Docker, sandbox micro-VMs). The same settings the API's
/// ListRuntimes / SetDefaultRuntime / UpdateRuntime manage.
enum RuntimeCommands {
    static let usage = """
        runtime ls                            engines, availability, default
        runtime install|repair|start|stop|restart  managed runtime operations (app must be running)
        runtime operation|cancel|recover        progress, cancellation and verified recovery
        runtime status                        Apple dependency readiness and next action (--json supported)
        runtime use <name>                    make <name> the default for new containers
        runtime enable|disable <name>         include/exclude an engine from ps and run
        runtime endpoint <name> <url|default> point docker at another socket (unix:// or tcp://)
        """

    static func run(_ args: [String], _ services: Services) async throws {
        let registry = EngineRegistry.shared
        let apple = services.runtime.router?.apple ?? AppleEngine(services: services.runtime)
        switch args.first ?? "ls" {
        case "install", "repair", "start", "stop", "restart", "cancel", "recover", "operation":
            let method = args[0] == "operation" ? "status" : args[0]
            let response = try await AppControlClient().call("runtime." + method)
            if MicropodCLI.jsonOutput {
                print(
                    String(
                        decoding: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
                        as: UTF8.self))
            } else {
                print(response["message"] as? String ?? response["phase"] as? String ?? "Runtime operation requested")
            }
        case "status":
            let parsed = try parseArgs(
                Array(args.dropFirst()), boolFlags: [], valueFlags: [], commandName: "runtime status")
            guard !parsed.has("--help") else {
                print("usage: micropod runtime status [--json]")
                return
            }
            let report = await RuntimeDependencyProbe.inspect(
                system: services.system, services: services.runtime)
            if MicropodCLI.jsonOutput {
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            } else {
                print("dependency: \(report.state.rawValue)")
                print("cli: \(report.cliPath)\(report.cliVersion.isEmpty ? "" : " (\(report.cliVersion))")")
                print(report.message)
                print("next: \(report.nextAction)")
                if report.state == .missingCLI { print("installer: \(report.installerURL)") }
            }
        case "ls", "list":
            let response = await registry.describe(apple: apple)
            if MicropodCLI.jsonOutput {
                emitJSON(response.runtimes)
                return
            }
            let rows = response.runtimes.map { r in
                [
                    (r.default ? "* " : "  ") + r.name, r.kind,
                    r.available ? "yes" : "no",
                    r.enabled ? "yes" : "no", r.version.isEmpty ? "—" : r.version,
                    r.available ? r.endpoint : r.reason,
                ]
            }
            print(
                renderTable(
                    headers: ["NAME", "KIND", "AVAILABLE", "ENABLED", "VERSION", "ENDPOINT / REASON"], rows: rows))
        case "use", "default":
            let name = try requireName(args)
            try await registry.setDefault(name, apple: apple)
            print("default runtime → \(name)")
        case "enable", "disable":
            let name = try requireName(args)
            try registry.update(name, enabled: args[0] == "enable", endpoint: nil)
            print("\(name) \(args[0])d")
        case "endpoint":
            let name = try requireName(args)
            guard args.count > 2 else { throw UsageError(message: "runtime endpoint <name> <url|default>") }
            try registry.update(name, enabled: nil, endpoint: args[2] == "default" ? "" : args[2])
            print("\(name) endpoint → \(args[2])")
        default:
            throw UsageError(message: "unknown runtime command '\(args[0])'\n\(usage)")
        }
    }

    static func requireName(_ args: [String]) throws -> String {
        guard args.count > 1 else { throw UsageError(message: "missing <name> (apple, docker, sandbox)") }
        return args[1]
    }
}
