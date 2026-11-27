import Foundation
import MicropodCore
import MicropodRuntime

/// `micropod status`: the hvf machine first (its state and why, the engine,
/// containers, the Docker endpoint, cache disk, disk flush, a pending
/// update, autostart), read from the API's RigService `GetMachineStatus`
/// when an API answers within two seconds and in-process otherwise, then
/// the Apple runtime's four lines when Apple is the default or enabled.
/// Dispatched before `Services`, so a machine-only setup never pings Apple.
enum StatusCommand {
    /// The `status` command in a whole argv, global flags removed wherever
    /// they sit; nil for any other command.
    static func route(_ argv: [String]) -> (args: [String], json: Bool, cliPath: String?)? {
        var args = argv
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" || $0 == "--no-color" }
        var cliPath: String?
        if let index = args.firstIndex(of: "--cli"), index + 1 < args.count {
            cliPath = args[index + 1]
            args.removeSubrange(index...index + 1)
        }
        guard args.first == "status" else { return nil }
        return (Array(args.dropFirst()), json, cliPath)
    }

    /// Where the machine facts came from.
    enum Source: Equatable {
        /// The API answered for this machine root.
        case api(String)
        /// No API answered; read in this process.
        case disk
        /// An API answered, but for another machine root (its own
        /// MICROPOD_HVF_ROOT); read in this process.
        case otherRoot(api: String, root: String)
        /// An API answered without the machine fields (an older one).
        case olderAPI(String)
    }

    struct Report {
        var defaultRuntime: String
        var enabledRuntimes: [String]
        var machine: Micropod_V1_HVFMachineStatus
        var source: Source
        /// The `micropod` docker context's record (`micropod docker install`).
        var docker: HVFDockerWiring.Record?
        /// The context and the selection as the docker CLI's files have
        /// them now: the record does not follow a `docker context use` or
        /// `docker context rm` the user ran since.
        var context: HVFDockerWiring.StoredContext
        var appleShown: Bool
    }

    static func main(_ args: [String], json: Bool, cliPath: String?) async -> Int32 {
        do {
            let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "status")
            guard !parsed.has("--help") else {
                print("usage: micropod status [--json]")
                return ExitCode.ok
            }
            guard parsed.positionals.isEmpty else { throw UsageError(message: "status takes no arguments") }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            return ExitCode.usage
        }
        let environment = ProcessInfo.processInfo.environment
        let report = await gather(environment: environment)
        var apple: (status: Micropod_V1_SystemStatus?, error: String?)?
        if report.appleShown {
            let services = await Services(cliPath: cliPath)
            do {
                apple = (try await services.system.status(), nil)
            } catch {
                apple = (nil, errorMessage(error))
            }
        }
        if json {
            print(ControlPlaneJSON.prettyText(jsonObject(report, apple: apple)))
        } else {
            for (label, value) in lines(report) { print(pad(label) + value) }
            if let apple {
                if let status = apple.status {
                    print(pad("apple:") + status.status)
                    print(pad("  cli:") + status.cliVersion)
                    print(pad("  apiserver:") + status.apiServerVersion)
                    if !status.appRoot.isEmpty { print(pad("  approot:") + status.appRoot) }
                } else {
                    print(pad("apple:") + "unavailable (\(apple.error ?? "no answer"))")
                }
            }
        }
        return ExitCode.ok
    }

    static func pad(_ label: String) -> String { label.padding(toLength: 13, withPad: " ", startingAt: 0) }

    // MARK: Gathering

    static func gather(
        environment: [String: String], apiTimeoutSeconds: Int = 2,
        api: LocalAPI? = nil
    ) async -> Report {
        let registry = EngineRegistry(environment: environment)
        let client = HVFMachineClient(environment: environment)
        let api = api ?? LocalAPI.live(environment: environment)
        let where_ =
            api.socketPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? api.baseURL.absoluteString
        var source = Source.disk
        var machine: Micropod_V1_HVFMachineStatus?
        do {
            let answer = try await api.unary(
                "RigService", "GetMachineStatus", Micropod_V1_Empty(), as: Micropod_V1_HVFMachineStatus.self,
                timeout: apiTimeoutSeconds)
            if HVFMachineLayout.canonicalPath(answer.root) != HVFMachineLayout.canonicalPath(client.layout.root.path) {
                source = .otherRoot(api: where_, root: answer.root)
            } else if answer.readiness.isEmpty {
                source = .olderAPI(where_)
            } else {
                source = .api(where_)
                machine = answer
            }
        } catch {
            source = .disk
        }
        let wiring = HVFDockerWiring(layout: client.layout, docker: nil, environment: environment)
        let docker = try? wiring.loadRecord()
        let enabled = EngineRegistry.engineNames.filter { registry.isEnabled($0) }
        let facts: Micropod_V1_HVFMachineStatus
        if let machine {
            facts = machine
        } else {
            facts = await client.statusMessage(timeout: .seconds(1))
        }
        return Report(
            defaultRuntime: registry.defaultName, enabledRuntimes: enabled, machine: facts, source: source,
            docker: docker, context: wiring.storedContext(),
            appleShown: registry.defaultName == "apple" || registry.isEnabled("apple"))
    }

    // MARK: Lines

    static func lines(_ report: Report) -> [(String, String)] {
        let m = report.machine
        let others = report.enabledRuntimes.filter { $0 != report.defaultRuntime }
        var out: [(String, String)] = [
            (
                "runtime:",
                "\(report.defaultRuntime) (default)"
                    + (others.isEmpty ? "" : "; also enabled: \(others.joined(separator: ", "))")
            ),
            ("machine:", machineLine(m)),
        ]
        if m.hasEngineVersion {
            let range =
                m.hasEngineMinApiVersion ? "\(m.engineMinApiVersion)–\(m.engineApiVersion)" : m.engineApiVersion
            out.append(("engine:", "\(m.engineVersion.isEmpty ? "unknown" : m.engineVersion) (Docker API \(range))"))
        }
        if m.hasContainersTotal {
            out.append(("containers:", "\(m.containersRunning) running, \(m.containersTotal) total"))
        }
        let endpoint = m.dockerEndpoint.isEmpty ? "unix://" + m.socket : m.dockerEndpoint
        out.append(("docker:", "\(endpoint) \(dockerContext(report.context, record: report.docker))"))
        if m.installed {
            out.append(("cache disk:", cacheDiskLine(m.cacheDisk)))
            if !m.diskFlush.isEmpty { out.append(("disk flush:", m.diskFlush)) }
        }
        out.append(("update:", updateLine(m)))
        out.append(("autostart:", autostartLine(m.autostart)))
        out.append(("api:", apiLine(report.source)))
        if !report.appleShown { out.append(("apple:", "not enabled")) }
        return out
    }

    static func machineLine(_ m: Micropod_V1_HVFMachineStatus) -> String {
        let reason = m.hasFailureReason ? m.failureReason : m.summary
        switch m.readiness {
        case "running": return "running"
        case "starting": return m.summary.hasPrefix("starting (") ? m.summary : "starting"
        case "stopping": return "stopping"
        case "stopped": return m.stoppedOnRequest ? "stopped (on request)" : "stopped"
        case "failed": return "failed: \(reason)"
        case "not-installed": return "not installed: \(reason) (micropod setup)"
        case "unusable": return "unusable: \(reason)"
        case "not-ready": return "not ready: \(reason)"
        default: return m.summary
        }
    }

    /// What the docker CLI's files say now; the record only tells a context
    /// that was never made from one removed since.
    static func dockerContext(_ context: HVFDockerWiring.StoredContext, record: HVFDockerWiring.Record?) -> String {
        guard context.exists else {
            return record == nil
                ? "(no docker context: `micropod docker install`)"
                : "(docker context micropod was removed: `micropod docker install` creates it again)"
        }
        guard context.pointsHere else {
            return "(docker context micropod points at \(context.host ?? "another endpoint"), not this machine: "
                + "`micropod docker install --force`)"
        }
        return context.selected
            ? "(context micropod, selected)" : "(context micropod; current context: \(context.current))"
    }

    static func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(1 << 30))
    }

    static func cacheDiskLine(_ disk: Micropod_V1_RigCacheDisk) -> String {
        if disk.mounted, disk.hasFreeBytes, disk.hasSizeBytes {
            return "mounted, \(gib(disk.freeBytes)) free of \(gib(disk.sizeBytes))"
        }
        return disk.summary.isEmpty ? (disk.configured ? "configured" : "none") : disk.summary
    }

    static func updateLine(_ m: Micropod_V1_HVFMachineStatus) -> String {
        if m.updatePending {
            return "pending: \(m.hasStagedVersion ? m.stagedVersion : "a payload") staged (`micropod update hvf apply`)"
        }
        return "none" + (m.hasPayloadVersion ? " (payload \(m.payloadVersion))" : "")
    }

    static func autostartLine(_ a: Micropod_V1_HVFMachineAutostart) -> String {
        guard a.enabled else { return "off (`micropod machine autostart on` starts the machine at login)" }
        let state = a.loaded ? "on (loaded)" : "on (launchd loads it at the next login)"
        return a.hasProblem ? "\(state); \(a.problem)" : state
    }

    static func apiLine(_ source: Source) -> String {
        switch source {
        case .api(let where_): return "running (\(where_))"
        case .disk: return "not running (read from disk)"
        case .otherRoot(let where_, let root):
            return "running (\(where_)) for another machine (\(root)); read from disk"
        case .olderAPI(let where_): return "running (\(where_), an older version); read from disk"
        }
    }

    // MARK: JSON

    /// With Apple shown, its old top-level keys (`status`, `cliVersion`,
    /// `apiServerVersion`, `appRoot`) stay where they were.
    static func jsonObject(_ report: Report, apple: (status: Micropod_V1_SystemStatus?, error: String?)?)
        -> [String: Any]
    {
        var out: [String: Any] = [:]
        if let status = apple?.status,
            let data = try? status.jsonUTF8Data(),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            out = object
        } else if let error = apple?.error {
            out["appleError"] = error
        }
        out["runtime"] = ["default": report.defaultRuntime, "enabled": report.enabledRuntimes] as [String: Any]
        var machine = ControlPlaneJSON.machineStatus(report.machine)
        machine["line"] = machineLine(report.machine)
        out["machine"] = machine
        var docker: [String: Any] = [
            "endpoint": report.machine.dockerEndpoint.isEmpty
                ? "unix://" + report.machine.socket : report.machine.dockerEndpoint
        ]
        if report.context.exists {
            docker["context"] = HVFDockerWiring.contextName
            docker["contextHost"] = report.context.host ?? ""
        }
        docker["selected"] = report.context.selected
        docker["currentContext"] = report.context.current
        if let previous = report.docker?.previousContext { docker["previousContext"] = previous }
        out["docker"] = docker
        var api: [String: Any] = ["line": apiLine(report.source)]
        switch report.source {
        case .api(let where_):
            api["running"] = true
            api["endpoint"] = where_
        case .disk: api["running"] = false
        case .otherRoot(let where_, let root):
            api["running"] = true
            api["endpoint"] = where_
            api["machineRoot"] = root
        case .olderAPI(let where_):
            api["running"] = true
            api["endpoint"] = where_
        }
        out["api"] = api
        out["appleEnabled"] = report.appleShown
        return out
    }
}
