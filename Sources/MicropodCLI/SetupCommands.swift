import Foundation
import MicropodCore
import MicropodRuntime

/// `micropod setup`: the hvf machine's first run (`HVFMachineBootstrap`),
/// with `--docker`, `--use` and `--autostart` as optional extra steps (the
/// `micropod docker install` and `micropod machine autostart on` commands).
/// Dispatched before `Services`: none of it needs the Apple runtime.
enum SetupCommands {
    static let helpText = """
        micropod setup — set up the hvf Linux machine (first run)

        Usage:
          micropod setup [--payload <Micropod.app|dir>] [--disk-from <ext4> | --disk-image <ref>|default]
                         [--disk-size 64g] [--cache-disk-size 32g | --no-cache-disk]
                         [--cpus N] [--memory-mib N] [--no-start] [--timeout S]
                         [--docker] [--use] [--autostart] [--dry-run] [--json]

        Steps, each reported done, kept, skipped or failed:
          1 runtime files   micropod-vmm, Image, mp-hvf-init.cpio and tools/ from the app bundle
                            or CLI package (or --payload: an app bundle, or a directory holding
                            micropod-vmm, vmlinux-hvf, mp-hvf-init.cpio and micropod-oci-tools)
          2 disk            cloned from --disk-from, else from the package's base disk
                            (hvf-base-disk.ext4); --disk-image unpacks an OCI image instead, the
                            only step that downloads anything
          3 cache disk      a sparse ext4 for dependency caches (32 GiB for a new machine)
          4 start           boots the machine and waits for its Docker API (--no-start skips it)
          5 default runtime hvf on a fresh install; an existing install keeps its default
        --autostart starts the machine at login (`micropod machine autostart on`; launchd then
        starts it now too, instead of step 4), --docker adds the docker context `micropod`
        (`micropod docker install`), --use also selects it. Nothing is selected or loaded
        without them. Re-running keeps what is there.
        --dry-run prints the steps without changing anything (exit 1 when one would fail).
        --cpus and --memory-mib size a new machine (`micropod machine install` resizes one).
        """

    /// The setup command in a whole `micropod` argv, if it is one, with the
    /// global flags removed wherever they sit.
    static func route(_ argv: [String]) -> (args: [String], json: Bool)? {
        var args = argv
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" || $0 == "--no-color" }
        if let index = args.firstIndex(of: "--cli"), index + 1 < args.count {
            args.removeSubrange(index...index + 1)
        }
        guard args.first == "setup" else { return nil }
        return (Array(args.dropFirst()), json)
    }

    struct Parsed: Equatable {
        var options: HVFMachineBootstrap.Options
        var docker: Bool
        var use: Bool
        var autostart: Bool
        var dryRun: Bool
    }

    static func parse(_ args: [String]) throws -> Parsed {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--no-cache-disk", "--no-start", "--docker", "--use", "--autostart", "--dry-run", "--help"],
            valueFlags: [
                "--payload", "--disk-from", "--disk-image", "--disk-size", "--cache-disk-size", "--cpus",
                "--memory-mib", "--timeout",
            ],
            aliases: ["-h": "--help"], commandName: "setup")
        if parsed.has("--help") { throw Help() }
        guard parsed.positionals.isEmpty else { throw UsageError(message: "setup takes no positional arguments") }
        func url(_ flag: String) -> URL? {
            parsed.value(flag).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        }
        func int(_ flag: String) throws -> Int? {
            guard let raw = parsed.value(flag) else { return nil }
            guard let value = Int(raw), value > 0 else {
                throw UsageError(message: "setup: \(flag) wants a positive integer, got '\(raw)'")
            }
            return value
        }
        if parsed.value("--disk-from") != nil, parsed.value("--disk-image") != nil {
            throw UsageError(message: "setup: pass either --disk-from or --disk-image, not both")
        }
        if parsed.value("--cache-disk-size") != nil, parsed.has("--no-cache-disk") {
            throw UsageError(message: "setup: --no-cache-disk and --cache-disk-size contradict each other")
        }
        let image = parsed.value("--disk-image").map { $0 == "default" ? HVFMachineInstaller.defaultDiskImage : $0 }
        var options = HVFMachineBootstrap.Options(
            payload: url("--payload"), diskFrom: url("--disk-from"), diskImage: image,
            diskBytes: try MachineCommands.diskBytes(parsed.value("--disk-size") ?? MachineCommands.defaultDiskSize),
            cacheDiskBytes: try parsed.value("--cache-disk-size").map { try MachineCommands.diskBytes($0) },
            noCacheDisk: parsed.has("--no-cache-disk"), cpus: try int("--cpus"), memoryMiB: try int("--memory-mib"),
            start: !parsed.has("--no-start"), startTimeout: .seconds(try int("--timeout") ?? 180))
        let autostart = parsed.has("--autostart")
        if autostart, options.start {
            // launchd starts it when the LaunchAgent loads (RunAtLoad): a
            // machine started here first would only be restarted under it.
            options.start = false
            options.startedBy = "launchd starts it (--autostart, below)"
        }
        return Parsed(
            options: options, docker: parsed.has("--docker") || parsed.has("--use"), use: parsed.has("--use"),
            autostart: autostart, dryRun: parsed.has("--dry-run"))
    }

    struct Help: Error {}

    /// What `--json` prints.
    struct Report: Encodable {
        var ok: Bool
        var root: String
        var steps: [HVFMachineBootstrap.Step]
        var extra: [Extra]
        var next: [String]
    }

    struct Extra: Encodable, Equatable {
        var id: String
        var state: HVFMachineBootstrap.StepState
        var detail: String
        var lines: [String]
    }

    static func main(_ args: [String], json: Bool) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let parsed: Parsed
        do {
            parsed = try parse(args)
        } catch is Help {
            print(helpText)
            return ExitCode.ok
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data("error: \(errorMessage(error))\n".utf8))
            return ExitCode.failure
        }
        let layout = HVFMachineLayout(environment: environment)
        let bootstrap = HVFMachineBootstrap(layout: layout, options: parsed.options, environment: environment)
        return await run(bootstrap, parsed: parsed, environment: environment, json: json)
    }

    static func run(
        _ bootstrap: HVFMachineBootstrap, parsed: Parsed, environment: [String: String], json: Bool,
        out: @escaping @Sendable (String) -> Void = { print($0) },
        err: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        // Autostart first: launchd starts the machine, and the docker
        // context's builder is chosen from the running engine.
        let extras = (parsed.autostart ? ["autostart"] : []) + (parsed.docker ? ["docker"] : [])
        let total = HVFMachineBootstrap.StepID.allCases.count + extras.count
        if parsed.dryRun {
            let steps = bootstrap.plan()
            if json {
                emit(Report(ok: true, root: bootstrap.layout.root.path, steps: steps, extra: [], next: []), out: out)
            } else {
                out("setup would, under \(bootstrap.layout.root.path):")
                for step in steps { out(line(step, total: total)) }
                for (offset, extra) in extras.enumerated() {
                    out(extraLine(index: steps.count + offset + 1, total: total, id: extra, state: .pending, ""))
                }
            }
            return steps.contains { $0.state == .failed } ? ExitCode.failure : ExitCode.ok
        }
        if !json { out("setting up the hvf machine under \(bootstrap.layout.root.path)") }
        let steps = await bootstrap.run { event in
            guard !json else { return }
            switch event {
            case .started(_, let text): out("      \(text)…")
            case .detail(_, let text): out("      \(text)")
            case .finished(let step): out(line(step, total: total))
            }
        }
        if steps.contains(where: { $0.id == .start && $0.state == .done }) {
            // An explicit start, as `machine start`: the canonical socket
            // follows it under the same rules (a note says when it does not).
            MachineCommands.autoLink(HVFMachineClient(layout: bootstrap.layout, environment: environment))
        }
        let failedStep = steps.first { $0.state == .failed }
        var extra: [Extra] = []
        if failedStep == nil {
            if parsed.autostart {
                let item = await autostartStep(
                    bootstrap.layout, environment: environment,
                    waitFor: parsed.options.startedBy != nil ? parsed.options.startTimeout : nil)
                extra.append(item)
                if !json { report(item, index: steps.count + extra.count, total: total, out: out, err: err) }
            }
            if parsed.docker, extra.allSatisfy({ $0.state != .failed }) {
                let item = await dockerStep(bootstrap.layout, use: parsed.use, environment: environment)
                extra.append(item)
                if !json { report(item, index: steps.count + extra.count, total: total, out: out, err: err) }
            }
        }
        let stopped = steps.contains { $0.id == .start && $0.state == .skipped } && parsed.options.startedBy == nil
        // Where setup stopped, and why: a step, else an extra step.
        let failure =
            failedStep.map { "\($0.id.title): \($0.detail)" }
            ?? extra.first { $0.state == .failed }.map { "\($0.id): \($0.detail)" }
        let next =
            failure == nil
            ? nextSteps(bootstrap.layout, parsed: parsed, environment: environment, stopped: stopped) : []
        if json {
            emit(
                Report(ok: failure == nil, root: bootstrap.layout.root.path, steps: steps, extra: extra, next: next),
                out: out)
        } else if let failure {
            err("error: setup stopped at \(failure)")
        } else if !next.isEmpty {
            out("next: " + next.joined(separator: "    "))
        }
        return failure == nil ? ExitCode.ok : ExitCode.failure
    }

    static func line(_ step: HVFMachineBootstrap.Step, total: Int) -> String {
        let index = (HVFMachineBootstrap.StepID.allCases.firstIndex(of: step.id) ?? 0) + 1
        return extraLine(index: index, total: total, id: step.id.title, state: step.state, step.detail)
    }

    static func extraLine(
        index: Int, total: Int, id: String, state: HVFMachineBootstrap.StepState, _ detail: String
    ) -> String {
        let title = id.padding(toLength: 16, withPad: " ", startingAt: 0)
        let prefix =
            switch state {
            case .failed: "failed: "
            case .pending: detail.isEmpty ? "pending" : "pending: "
            default: ""
            }
        return "[\(index)/\(total)] \(title)\(prefix)\(detail)"
    }

    static func report(
        _ item: Extra, index: Int, total: Int, out: @Sendable (String) -> Void, err: @Sendable (String) -> Void
    ) {
        out(extraLine(index: index, total: total, id: item.id, state: item.state, item.detail))
        for line in item.lines {
            if line.hasPrefix("note: ") { err(line) } else { out("      \(line)") }
        }
    }

    /// `micropod docker install [--use]` as a step.
    static func dockerStep(_ layout: HVFMachineLayout, use: Bool, environment: [String: String]) async -> Extra {
        let wiring = HVFDockerWiring(layout: layout, environment: environment)
        let client = HVFMachineClient(layout: layout, environment: environment)
        do {
            let outcome = try wiring.install(
                use: use, builder: .auto, force: false, machine: await DockerCommands.machine(client))
            let actions = outcome.actions
            return Extra(
                id: "docker", state: .done, detail: actions.first ?? "docker context micropod",
                lines: Array(actions.dropFirst()) + outcome.notes.map { "note: \($0)" })
        } catch {
            return Extra(id: "docker", state: .failed, detail: HVFMachineBootstrap.errorText(error), lines: [])
        }
    }

    /// `micropod machine autostart on` as a step; with `waitFor`, then waits
    /// for the machine launchd starts (a start kickstarts the job).
    static func autostartStep(_ layout: HVFMachineLayout, environment: [String: String], waitFor: Duration?) async
        -> Extra
    {
        let agent = HVFMachineAutostartAgent(layout: layout, environment: environment)
        let program = HVFMachineAutostartAgent.resolveProgram(
            explicit: nil, environment: environment, current: CLIInstall.currentExecutable())
        do {
            var lines = try await agent.enable(load: true, program: program, force: false)
            let summary = await agent.status().summary
            if let waitFor {
                try await HVFMachineClient(layout: layout, environment: environment).ensureRunning(timeout: waitFor)
                lines.append("machine: running under launchd")
            }
            return Extra(
                id: "autostart", state: .done, detail: lines.first ?? summary, lines: Array(lines.dropFirst()))
        } catch {
            return Extra(id: "autostart", state: .failed, detail: HVFMachineBootstrap.errorText(error), lines: [])
        }
    }

    /// The commands a finished setup suggests: the docker context and
    /// autostart, unless they are in place or were just done.
    static func nextSteps(_ layout: HVFMachineLayout, parsed: Parsed, environment: [String: String], stopped: Bool)
        -> [String]
    {
        var next: [String] = []
        let wiring = HVFDockerWiring(layout: layout, environment: environment)
        if !parsed.docker, (try? wiring.loadRecord()) == nil { next.append("micropod docker install --use") }
        let autostartRecord = layout.root.appendingPathComponent("autostart.json")
        if !parsed.autostart, !FileManager.default.fileExists(atPath: autostartRecord.path) {
            next.append("micropod machine autostart on")
        }
        if stopped { next.insert("micropod machine start", at: 0) }
        return next
    }

    static func emit(_ report: Report, out: @Sendable (String) -> Void) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        out(String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self))
    }
}
