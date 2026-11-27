import AppKit
import Foundation
import MicropodCore
import MicropodRuntime

/// `micropod runtime` — list and configure execution engines (apple VMs,
/// Docker, sandbox micro-VMs). The same settings the API's
/// ListRuntimes / SetDefaultRuntime / UpdateRuntime manage.
enum RuntimeCommands {
    static let usage = """
        runtime ls                            engines, availability, default
        runtime mode [container|sandbox]      show or switch between Containers (hvf) and Isolated Sandboxes (sandbox)
        runtime use <name>                    make <name> the default (aliases: container -> hvf, isolated -> sandbox)
        runtime enable|disable <name>         include/exclude an engine from ps and run
        runtime endpoint <name> <url|default> point docker at another socket (unix:// or tcp://)
        runtime status                        Apple dependency readiness and next action (--json supported)
        runtime install|repair|start|stop|restart  legacy Apple managed runtime operations
        runtime operation|cancel|recover        legacy Apple runtime operation state
        runtime update [--rollback]           legacy Apple dedicated runtime update
        runtime install-authority             legacy Apple root helper setup (sudo)
        """

    /// The legacy Apple subcommands, which still manage Apple's runtime
    /// while it is not enabled (say so first).
    static let appleSubcommands: Set<String> = [
        "update", "install-authority", "install", "repair", "start", "stop", "restart", "cancel", "recover",
        "operation", "status",
    ]

    static func run(_ args: [String], _ services: Services) async throws {
        let registry = EngineRegistry.shared
        let apple = services.runtime.router?.apple ?? AppleEngine(services: services.runtime)
        if let sub = args.first, appleSubcommands.contains(sub), let note = appleNote(registry) {
            FileHandle.standardError.write(Data("note: \(note)\n".utf8))
        }
        switch args.first ?? "ls" {
        case "update":
            try await RuntimeUpdateCommands.run(Array(args.dropFirst()))
        case "install-authority":
            try await RuntimeAuthorityCommands.run(Array(args.dropFirst()))
        case "install", "repair", "start", "stop", "restart", "cancel", "recover", "operation":
            let parsed = try parseArgs(
                Array(args.dropFirst()), boolFlags: [], valueFlags: [], commandName: "runtime " + args[0])
            guard !parsed.has("--help") else {
                print("usage: micropod runtime \(args[0]) [--json]")
                return
            }
            guard parsed.positionals.isEmpty else {
                throw UsageError(message: "usage: micropod runtime \(args[0]) [--json]")
            }
            let response: IsolatedRuntimeStatus
            if ["install", "repair"].contains(args[0]),
                (try? await IsolatedRuntimeClient().call(.init(action: .status))) == nil
            {
                response = try await bootstrapInstallation()
            } else {
                response = try await ManagedRuntimeControl.request(args[0])
            }
            if MicropodCLI.jsonOutput {
                print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
            } else {
                print(response.message)
                if let error = response.error { print(error) }
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
            print(listing(response, origin: registry.origin))
        case "mode":
            if let requested = args.dropFirst().first {
                guard let mode = RuntimeMode(rawValue: requested.lowercased()) else {
                    throw UsageError(
                        message: "runtime mode wants 'container' (shared HVF VM) or 'sandbox' (isolated microVM)")
                }
                try await registry.setDefault(mode.engineName, apple: apple)
                if MicropodCLI.jsonOutput {
                    let payload: [String: String] = [
                        "mode": mode.rawValue, "runtime": mode.engineName, "summary": mode.summary,
                    ]
                    let data = try JSONSerialization.data(
                        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print("mode → \(mode.rawValue) (\(mode.engineName)): \(mode.summary)")
                }
            } else {
                let current = registry.defaultName
                let mode = registry.activeMode
                if MicropodCLI.jsonOutput {
                    let payload: [String: String] = [
                        "mode": mode?.rawValue ?? "legacy",
                        "runtime": current,
                        "summary": mode?.summary ?? "Legacy runtime '\(current)'",
                    ]
                    let data = try JSONSerialization.data(
                        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                } else if let mode {
                    print("mode: \(mode.rawValue) (\(mode.engineName)) — \(mode.summary)")
                } else {
                    print("mode: legacy (\(current)) — switch with `micropod runtime mode container|sandbox`")
                }
            }
        case "use", "default":
            let name = EngineRegistry.canonicalName(try requireName(args))
            try await registry.setDefault(name, apple: apple)
            print("default runtime → \(name)")
        case "enable", "disable":
            let name = EngineRegistry.canonicalName(try requireName(args))
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

    /// `runtime ls`: the table, then where the default came from.
    static func listing(_ response: Micropod_V1_ListRuntimesResponse, origin: InstallOrigin?) -> String {
        let rows = response.runtimes.map { r -> [String] in
            let optIn = r.name == "apple" && !r.enabled && origin == .fresh
            let notSetUp = r.name == "hvf" && !r.available && r.reason.contains("not installed")
            let detail =
                optIn
                ? "opt-in: `micropod runtime enable apple`"
                : notSetUp ? "not set up: `micropod setup`" : r.available ? r.endpoint : r.reason
            return [
                (r.default ? "* " : "  ") + r.name, r.kind, r.available ? "yes" : "no",
                r.enabled ? "yes" : optIn ? "opt-in" : "no", r.version.isEmpty ? "—" : r.version, detail,
            ]
        }
        let table = renderTable(
            headers: ["NAME", "KIND", "AVAILABLE", "ENABLED", "VERSION", "ENDPOINT / REASON"], rows: rows)
        let why =
            origin == .fresh && response.default == InstallOrigin.freshDefaultRuntime
            ? "chosen for a fresh install; " : ""
        return table + "\ndefault: \(response.default) (\(why)`micropod runtime use <name>` changes it)"
    }

    /// Said before a legacy Apple subcommand while Apple is not enabled.
    static func appleNote(_ registry: EngineRegistry) -> String? {
        registry.isEnabled("apple")
            ? nil
            : "the Apple runtime is not enabled (`micropod runtime enable apple` turns it on); this command manages it "
                + "anyway"
    }

    static func requireName(_ args: [String]) throws -> String {
        guard args.count > 1 else { throw UsageError(message: "missing <name> (apple, docker, sandbox, ci, hvf)") }
        return args[1]
    }

    @MainActor
    private static func bootstrapInstallation() async throws -> IsolatedRuntimeStatus {
        guard !FileManager.default.fileExists(atPath: IsolatedRuntimePolicy.identityURL.path),
            try !RuntimeSetupInstallation.helperIsRunning()
        else {
            throw MicropodError.message(
                "The existing runtime helper is unavailable. Its installation and approval were left unchanged.")
        }
        guard case .appManaged(let app) = CLIInstall.kind(of: CLIInstall.currentExecutable()) else {
            throw MicropodError.message("Initial administrator setup needs the signed Micropod app installation")
        }
        _ = app
        // The privileged helper is installed once by an administrator as a
        // root-owned LaunchDaemon; then this command continues on its own.
        if !MicropodCLI.jsonOutput { print(RuntimeAuthorityCommands.instructions) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let status = try? await IsolatedRuntimeClient().call(.init(action: .status)) {
                if status.nativeState == "nativeReady", status.isTerminal, status.error == nil,
                    status.identity?.ownerUID == getuid()
                {
                    return status
                }
                if ["failed", "blocked", "recoveryRequired"].contains(status.phase) {
                    throw MicropodError.message(status.error ?? status.message)
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw MicropodError.message(
            "Administrator setup has not completed. Its setup window and any runtime operation were retained.")
    }
}
