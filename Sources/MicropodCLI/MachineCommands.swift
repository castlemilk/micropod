import Darwin
import Foundation
import MicropodCore
import MicropodRuntime

/// `micropod machine …` for the shared hvf machine: one supervised
/// micropod-vmm Linux VM whose Docker Engine API backs `--runtime hvf`.
/// Dispatched before `Services` resolution — none of it needs the Apple
/// runtime, and `serve` runs for the machine's whole life.
///
/// `machine stop <name>` and `machine logs <name>` keep acting on Apple
/// runtime machines; without a name they act on the hvf machine.
enum MachineCommands {
    static let helpText = """
        micropod machine — the shared hvf Linux machine (Hypervisor.framework VMM)

        Usage:
          micropod machine install [--vmm <micropod-vmm>] [--kernel <Image>] [--initrd <cpio>]
                                   [--tools <dir>] [--cpus N] [--memory-mib N] [--workspace <dir>|""]
                                   [--disk-from <ext4> | --disk-image <ref>|default [--disk-size 32g]]
                                   [--replace-disk]
                                                  copy the assets into the machine root; the disk is
                                                  an APFS clone of --disk-from, or a fresh ext4
                                                  unpacked from an OCI image; flags left out keep
                                                  what is installed
          micropod machine start [--timeout S]    boot it (detached supervisor) and wait for Docker
          micropod machine stop                   power the guest off gracefully
          micropod machine restart
          micropod machine status [--json]        phase, pids, restarts, last exit, endpoints and
                                                  capabilities (BuildKit, engine API range)
          micropod machine logs [-f] [-n N] [--supervisor]
                                                  micropod-vmm console (or supervisor) log
          micropod machine docker-endpoint        unix:// socket for DOCKER_HOST
          micropod machine buildkit-endpoint      unix:// BuildKit socket for a remote buildx builder
                                                  (fails when the tool bundle ships no BuildKit)
          micropod machine serve                  run the supervisor in the foreground

        The root is MICROPOD_HVF_ROOT or ~/.micropod/hvf. `micropod run --runtime hvf …`
        starts the machine on demand (enable the engine first: `micropod runtime enable hvf`).
        Docker bind mounts resolve under the workspace, the home directory by default
        (`--workspace ""` turns host bind mounts off).
        """

    static let hvfOnly: Set<String> = [
        "install", "start", "restart", "status", "serve", "docker-endpoint", "buildkit-endpoint", "help",
    ]

    /// The hvf machine command in a whole `micropod` argv, if it is one: the
    /// arguments after `machine` (or `machines`), with the global flags
    /// (`--json`, `--no-color`, `--cli <path>`) removed wherever they sit,
    /// the way the main dispatcher removes them.
    static func route(_ argv: [String]) -> (args: [String], json: Bool)? {
        var args = argv
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" || $0 == "--no-color" }
        if let index = args.firstIndex(of: "--cli"), index + 1 < args.count {
            args.removeSubrange(index...index + 1)
        }
        guard args.first == "machine" || args.first == "machines" else { return nil }
        let machineArgs = Array(args.dropFirst())
        return handles(machineArgs) ? (machineArgs, json) : nil
    }

    /// True when `args` (after `machine`) is an hvf machine command.
    static func handles(_ args: [String]) -> Bool {
        guard let sub = args.first else { return false }
        if hvfOnly.contains(sub) { return true }
        let rest = Array(args.dropFirst())
        switch sub {
        case "stop":
            return (try? parseArgs(rest, boolFlags: [], valueFlags: ["--timeout"], commandName: "machine stop"))?
                .positionals.isEmpty ?? false
        case "logs":
            return (try? parseLogs(rest))?.positionals.isEmpty ?? false
        default:
            return false
        }
    }

    static func main(_ args: [String], json: Bool) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let client = HVFMachineClient(environment: environment)
        let rest = Array(args.dropFirst())
        do {
            switch args.first ?? "help" {
            case "install": try await install(rest, layout: client.layout)
            case "start":
                let parsed = try parseArgs(rest, boolFlags: [], valueFlags: ["--timeout"], commandName: "machine start")
                try await client.ensureRunning(timeout: .seconds(parsed.intValue("--timeout", default: 180)))
                print("hvf machine running — DOCKER_HOST=\(client.layout.dockerEndpoint)")
            case "stop":
                let parsed = try parseArgs(rest, boolFlags: [], valueFlags: ["--timeout"], commandName: "machine stop")
                let stopped = try await client.stop(
                    timeout: parsed.value("--timeout").flatMap(Int.init).map { .seconds($0) })
                print(stopped ? "hvf machine stopped" : "hvf machine was not running")
            case "restart":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "machine restart")
                try await client.restart()
                print("hvf machine running — DOCKER_HOST=\(client.layout.dockerEndpoint)")
            case "status":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "machine status")
                return try await status(client, json: json)
            case "logs": try await logs(rest, layout: client.layout)
            case "docker-endpoint":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "machine docker-endpoint")
                print(client.layout.dockerEndpoint)
            case "buildkit-endpoint":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "machine buildkit-endpoint")
                print(try client.buildkitEndpoint())
            case "serve":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "machine serve")
                return try await serve(layout: client.layout, environment: environment)
            default:
                print(helpText)
                return args.first == "help" ? ExitCode.ok : ExitCode.usage
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

    // MARK: install

    static func install(_ args: [String], layout: HVFMachineLayout) async throws {
        let parsed = try parseArgs(
            args, boolFlags: ["--replace-disk"],
            valueFlags: [
                "--vmm", "--kernel", "--initrd", "--tools", "--disk-from", "--disk-image", "--disk-size", "--cpus",
                "--memory-mib", "--workspace",
            ],
            commandName: "machine install")
        guard parsed.positionals.isEmpty else {
            throw UsageError(message: "machine install takes no positional arguments")
        }
        func url(_ flag: String) -> URL? {
            parsed.value(flag).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        }
        func int(_ flag: String) throws -> Int? {
            guard let raw = parsed.value(flag) else { return nil }
            guard let value = Int(raw) else { throw UsageError(message: "\(flag) wants an integer, got '\(raw)'") }
            return value
        }
        let image = parsed.value("--disk-image").map { $0 == "default" ? HVFMachineInstaller.defaultDiskImage : $0 }
        let request = HVFInstallRequest(
            vmm: url("--vmm"), kernel: url("--kernel"), initrd: url("--initrd"), tools: url("--tools"),
            diskFrom: url("--disk-from"), diskImage: image,
            diskBytes: try diskBytes(parsed.value("--disk-size") ?? "32g"), replaceDisk: parsed.has("--replace-disk"),
            cpus: try int("--cpus"), memoryMiB: try int("--memory-mib"),
            workspace: parsed.value("--workspace").map { $0.isEmpty ? "" : NSString(string: $0).expandingTildeInPath })
        try await HVFMachineInstaller.install(request, layout: layout) { print($0) }
        print("hvf machine installed under \(layout.root.path)")
    }

    /// "32g", "40960m" → bytes.
    static func diskBytes(_ raw: String) throws -> UInt64 {
        let lower = raw.lowercased()
        let scale: UInt64 = lower.hasSuffix("g") ? 1 << 30 : lower.hasSuffix("m") ? 1 << 20 : 0
        guard scale > 0, let count = UInt64(lower.dropLast()), count > 0 else {
            throw UsageError(message: "--disk-size wants a size such as 32g or 40960m, got '\(raw)'")
        }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: scale)
        guard !overflow else { throw UsageError(message: "--disk-size '\(raw)' is too large") }
        return bytes
    }

    // MARK: status

    struct StatusReport: Encodable {
        var root: String
        /// The Docker Engine API (kept as `endpoint` for existing readers).
        var endpoint: String
        var dockerEndpoint: String
        /// nil when the tool bundle ships no BuildKit.
        var buildkitEndpoint: String?
        var installed: Bool
        var missing: [String]
        var problem: String?
        var phase: String
        var supervisorAlive: Bool
        var summary: String
        var state: HVFMachineState?
        var stateError: String?
        var capabilities: HVFMachineCapabilities
    }

    static func status(_ client: HVFMachineClient, json: Bool) async throws -> Int32 {
        let status = client.status()
        let capabilities = await client.capabilities()
        let buildkit = capabilities.buildkit ? client.layout.buildkitEndpoint : nil
        if json {
            let report = StatusReport(
                root: status.root, endpoint: client.layout.dockerEndpoint, dockerEndpoint: client.layout.dockerEndpoint,
                buildkitEndpoint: buildkit, installed: status.installed, missing: status.missing,
                problem: status.problem, phase: status.phase.rawValue, supervisorAlive: status.supervisorAlive,
                summary: status.summary, state: status.state, stateError: status.stateError,
                capabilities: capabilities)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return ExitCode.ok
        }
        print("machine:    \(status.summary)")
        print("root:       \(status.root)")
        print("endpoint:   \(client.layout.dockerEndpoint)")
        if let buildkit {
            print("buildkit:   \(buildkit)")
        } else if status.installed {
            print("buildkit:   none (the tool bundle lacks \(capabilities.buildkitMissing.joined(separator: ", ")))")
        }
        if let engine = capabilities.engine {
            print("engine:     \(engine.version) (Docker API \(engine.minAPIVersion)–\(engine.apiVersion))")
        }
        if let state = status.state {
            print("supervisor: pid \(state.supervisorPID)\(status.supervisorAlive ? "" : " (exited)")")
            if let vmm = state.vmmPID, status.supervisorAlive { print("vmm:        pid \(vmm)") }
            if let started = state.startedAt { print("started:    \(ISO8601DateFormatter().string(from: started))") }
            if let ready = state.readyAt, status.phase == .running {
                print("ready:      \(ISO8601DateFormatter().string(from: ready))")
            }
            print("restarts:   \(state.restartCount)")
            if let reason = state.lastExitReason { print("last exit:  \(reason)") }
        }
        return ExitCode.ok
    }

    // MARK: logs

    static func parseLogs(_ args: [String]) throws -> ParsedArgs {
        try parseArgs(
            args, boolFlags: ["--follow", "--supervisor"], valueFlags: ["--tail"],
            aliases: ["-f": "--follow", "-n": "--tail"], commandName: "machine logs")
    }

    /// `--tail N`: a non-negative line count (default 100).
    static func tailLines(_ parsed: ParsedArgs) throws -> Int {
        guard let raw = parsed.value("--tail") else { return 100 }
        guard let lines = Int(raw), lines >= 0 else {
            throw UsageError(message: "machine logs: --tail wants a non-negative integer, got '\(raw)'")
        }
        return lines
    }

    static func logs(_ args: [String], layout: HVFMachineLayout) async throws {
        let parsed = try parseLogs(args)
        let url = parsed.has("--supervisor") ? layout.supervisorLog : layout.consoleLog
        let lines = try tailLines(parsed)
        var offset: UInt64 = 0
        var inode: UInt64 = 0
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let window: UInt64 = 1 << 20
            try handle.seek(toOffset: end > window ? end - window : 0)
            let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().suffix(lines) {
                print(line)
            }
            offset = end
            inode = fileID(url) ?? 0
        } else if !parsed.has("--follow") {
            throw MicropodError.message("notFound: no log at \(url.path) yet")
        }
        guard parsed.has("--follow") else { return }
        while true {
            try await Task.sleep(for: .milliseconds(250))
            guard let current = fileID(url) else { continue }
            if current != inode {  // rotated: read the new file from its start
                inode = current
                offset = 0
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end < offset { offset = 0 }
            guard end > offset else { continue }
            try handle.seek(toOffset: offset)
            if let data = try handle.read(upToCount: Int(end - offset)) {
                FileHandle.standardOutput.write(data)
                offset += UInt64(data.count)
            }
        }
    }

    private static func fileID(_ url: URL) -> UInt64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    // MARK: serve

    static func serve(layout: HVFMachineLayout, environment: [String: String]) async throws -> Int32 {
        switch try await HVFMachineSupervisor.serve(layout: layout, environment: environment) {
        case .stopped:
            return ExitCode.ok
        case .failed(let reason):
            FileHandle.standardError.write(Data("error: hvf machine failed: \(reason)\n".utf8))
            return ExitCode.failure
        case .alreadyRunning(let pid):
            FileHandle.standardError.write(
                Data("hvf machine supervisor already running\(pid.map { " (pid \($0))" } ?? "")\n".utf8))
            return ExitCode.failure
        }
    }
}
