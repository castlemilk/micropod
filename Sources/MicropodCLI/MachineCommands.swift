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
                                   [--disk-from <ext4> | --disk-image <ref>|default [--disk-size 64g]]
                                   [--cache-disk-size 32g] [--replace-disk]
                                                  copy the assets into the machine root; the disk is
                                                  an APFS clone of --disk-from, or a fresh sparse ext4
                                                  unpacked from an OCI image; flags left out keep
                                                  what is installed. Missing runtime files come
                                                  from the app bundle or the extracted CLI package.
          micropod machine start [--timeout S]    boot it (detached supervisor) and wait for Docker
          micropod machine stop                   power the guest off gracefully
          micropod machine restart
          micropod machine status [--json]        phase, pids, restarts, last exit, endpoints and
                                                  capabilities (caches, docker build, BuildKit,
                                                  engine API range)
          micropod machine logs [-f] [-n N] [--supervisor]
                                                  micropod-vmm console (or supervisor) log
          micropod machine docker-endpoint        unix:// socket for DOCKER_HOST
          micropod machine buildkit-endpoint      unix:// BuildKit socket for a remote buildx builder
                                                  (fails when the tool bundle ships no BuildKit)
          micropod machine link-socket [--force]  link ~/.micropod/docker.sock -> HVF docker.sock
                                                  (`start` and `restart` link it themselves only for
                                                  ~/.micropod/hvf, or when MICROPOD_DOCKER_SOCK names
                                                  the link or MICROPOD_LINK_DOCKER_SOCK=1; never over
                                                  another machine's live socket without --force)
          micropod machine cache policy [show] [--mode auto|off] [--default-scope S|none]
                                   [--allow-scopes a,b*] [--tools go,npm,…|all] [--go-trimpath on|off]
                                   [--default-trust trusted|untrusted] [--proxy-untrusted on|off]
                                   [--pnpm-legacy-env on|off] [--register-buildx on|off]
                                                  the dependency-cache policy every container on the
                                                  machine's Docker socket gets (machine.json `cache`);
                                                  applied at once while running
          micropod machine builder install|status|rm
                                                  the fallback `docker build` path for an engine that
                                                  cannot build on its Docker socket: docker context
                                                  `micropod` and remote buildx builder
                                                  `micropod-buildkit` (then `BUILDX_BUILDER=
                                                  micropod-buildkit docker --context micropod build
                                                  …`); never changes the current context or any
                                                  other builder
          micropod machine serve                  run the supervisor in the foreground

        The root is MICROPOD_HVF_ROOT or ~/.micropod/hvf. `micropod run --runtime hvf …`
        starts the machine on demand (enable the engine first: `micropod runtime enable hvf`).
        Docker bind mounts resolve under the workspace, the home directory by default
        (`--workspace ""` turns host bind mounts off).

        Dependency caches (Go, npm, pnpm, yarn, pip, uv, cargo, corepack, Maven, Gradle, Bun,
        sccache, Playwright) attach to every container by default, shared per scope ("default");
        per container, the labels io.micropod.cache=auto|off|<tools> and
        io.micropod.cache.scope=<scope> (or `micropod run --cache … --cache-scope …`) refine the
        policy. Tools: go (= gomod,gobuild), gomod, gobuild, npm, pnpm, yarn, yarnberry, pip, uv,
        cargo, corepack, maven, gradle, bun, sccache, playwright.
        """

    static let hvfOnly: Set<String> = [
        "install", "start", "restart", "status", "serve", "docker-endpoint", "buildkit-endpoint", "link-socket",
        "help", "cache", "builder",
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
                autoLink(client)
                print("hvf machine running — DOCKER_HOST=\(client.layout.dockerEndpoint)")
                await afterStart(client, environment: environment)
            case "stop":
                let parsed = try parseArgs(rest, boolFlags: [], valueFlags: ["--timeout"], commandName: "machine stop")
                let stopped = try await client.stop(
                    timeout: parsed.value("--timeout").flatMap(Int.init).map { .seconds($0) })
                print(stopped ? "hvf machine stopped" : "hvf machine was not running")
            case "restart":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "machine restart")
                try await client.restart()
                autoLink(client)
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
            case "link-socket":
                let parsed = try parseArgs(
                    rest, boolFlags: ["--force"], valueFlags: [], commandName: "machine link-socket")
                let linkURL = try client.linkCanonicalDockerSocket(force: parsed.has("--force"))
                if json {
                    let payload = [
                        "link": linkURL.path,
                        "target": client.layout.dockerSocket.path,
                        "dockerEndpoint": "unix://" + linkURL.path,
                    ]
                    let data = try JSONSerialization.data(
                        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print("linked \(linkURL.path) -> \(client.layout.dockerSocket.path)")
                }
            case "serve":
                _ = try parseArgs(rest, boolFlags: [], valueFlags: [], commandName: "machine serve")
                return try await serve(layout: client.layout, environment: environment)
            case "cache": try cache(rest, client: client, json: json)
            case "builder": try builder(rest, layout: client.layout, environment: environment, json: json)
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

    /// After `machine start` or `machine restart`: points the canonical
    /// Docker socket at the machine when it is the standard one or the caller
    /// asked (`HVFMachineClient.autoLinksCanonicalDockerSocket`), and says so
    /// on stderr when it did not. Never fails the command.
    static func autoLink(_ client: HVFMachineClient) {
        switch client.autoLinkCanonicalDockerSocket() {
        case .linked: break
        case .skipped(let note), .refused(let note):
            FileHandle.standardError.write(Data("note: \(note)\n".utf8))
        }
    }

    // MARK: install

    static func install(_ args: [String], layout: HVFMachineLayout) async throws {
        let parsed = try parseArgs(
            args, boolFlags: ["--replace-disk"],
            valueFlags: [
                "--vmm", "--kernel", "--initrd", "--tools", "--disk-from", "--disk-image", "--disk-size",
                "--cache-disk-size", "--cpus", "--memory-mib", "--workspace",
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
        let cacheDiskBytes = try parsed.value("--cache-disk-size").map { try diskBytes($0) }
        let request = HVFInstallRequest(
            vmm: url("--vmm"), kernel: url("--kernel"), initrd: url("--initrd"), tools: url("--tools"),
            diskFrom: url("--disk-from"), diskImage: image,
            diskBytes: try diskBytes(parsed.value("--disk-size") ?? defaultDiskSize),
            cacheDiskBytes: cacheDiskBytes,
            replaceDisk: parsed.has("--replace-disk"),
            cpus: try int("--cpus"), memoryMiB: try int("--memory-mib"),
            workspace: parsed.value("--workspace").map { $0.isEmpty ? "" : NSString(string: $0).expandingTildeInPath })
        try await HVFMachineInstaller.install(
            request, layout: layout, packagedExecutable: CLIInstall.currentExecutable()
        ) {
            print($0)
        }
        if let note = try HVFMachineCachePolicy.applyRigDefaultTrust(layout: layout) { print(note) }
        print("hvf machine installed under \(layout.root.path)")
    }

    /// A fresh disk's size: sparse, so only what the guest writes is allocated.
    static let defaultDiskSize = "64g"

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
        /// The effective cache policy (machine.json `cache`, else the defaults).
        var cachePolicy: HVFMachineCachePolicy
        /// The `caches:` line.
        var caches: String
        /// The `docker build:` line.
        var dockerBuild: String
        /// Host loopback ports open to the guest now and at the next start.
        var hostPorts: HVFHostPortStatus
        /// The guest's account of its cache disk and whether shared caches
        /// are on this boot (`unknown` while the machine is not running).
        var cacheDisk: HVFCacheDiskObservation
    }

    static func status(_ client: HVFMachineClient, json: Bool) async throws -> Int32 {
        let status = client.status()
        let capabilities = await client.capabilities()
        let buildkit = capabilities.buildkit ? client.layout.buildkitEndpoint : nil
        let config = (try? HVFMachineConfig.load(from: client.layout.config)) ?? HVFMachineConfig()
        let policy = config.effectiveCachePolicy
        let fallbackInstalled =
            capabilities.dockerBuild == .fallback
            ? fallbackContextInstalled(client.layout, environment: ProcessInfo.processInfo.environment) : nil
        let cachesLine = cachesLine(capabilities, policy: policy)
        let buildLine = dockerBuildLine(capabilities, fallbackInstalled: fallbackInstalled)
        let hostPorts = HVFHostPortStatus(config: config, state: status.state, supervisorAlive: status.supervisorAlive)
        let cacheDisk = await client.cacheDiskObservation()
        if json {
            let report = StatusReport(
                root: status.root, endpoint: client.layout.dockerEndpoint, dockerEndpoint: client.layout.dockerEndpoint,
                buildkitEndpoint: buildkit, installed: status.installed, missing: status.missing,
                problem: status.problem, phase: status.phase.rawValue, supervisorAlive: status.supervisorAlive,
                summary: status.summary, state: status.state, stateError: status.stateError,
                capabilities: capabilities, cachePolicy: policy, caches: cachesLine, dockerBuild: buildLine,
                hostPorts: hostPorts, cacheDisk: cacheDisk)
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
        if status.installed {
            print("caches:     \(cachesLine)")
            print("cache disk: \(cacheDisk.summary)")
            print("docker build: \(buildLine)")
            print("host ports: \(hostPorts.summary)")
            for refusal in hostPorts.refused { print("            \(refusal.message)") }
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

    /// `auto, scope default (engine 1a2b3c4d5e6f)`, or why there are none.
    static func cachesLine(_ capabilities: HVFMachineCapabilities, policy: HVFMachineCachePolicy) -> String {
        guard capabilities.caches else { return "unavailable (tool bundle has no cache support)" }
        let short = { (commit: String) in String(commit.prefix(12)) }
        var engine = capabilities.engineCommit.map { "engine \(short($0))" } ?? "engine commit unknown"
        if let live = capabilities.engine?.gitCommit, capabilities.engineCommitMatches == false {
            engine += "; the running engine reports \(short(live))"
        }
        return "\(policy.summary) (\(engine))"
    }

    /// How stock `docker build` reaches BuildKit.
    static func dockerBuildLine(_ capabilities: HVFMachineCapabilities, fallbackInstalled: Bool?) -> String {
        switch capabilities.dockerBuild {
        case .ready: return "ready (docker socket)"
        case .unavailable: return "unavailable (bundle lacks buildkitd)"
        case .fallback:
            let probe = capabilities.grpcProbeStatus.map { "; the engine answers /grpc with \($0)" } ?? ""
            return fallbackInstalled == true
                ? "fallback builder only (`\(HVFBuilderSetup.buildCommand)`\(probe))"
                : "fallback builder only (run `micropod machine builder install`\(probe))"
        }
    }

    /// Whether docker context `micropod` points at this machine; nil
    /// without a docker CLI. Cheap: it never contacts BuildKit.
    static func fallbackContextInstalled(_ layout: HVFMachineLayout, environment: [String: String]) -> Bool? {
        guard
            let setup = try? HVFBuilderSetup(
                layout: layout, environment: environment, runner: HVFProcessRunner(timeout: .seconds(10))),
            let (piece, _) = try? setup.contextState()
        else { return nil }
        return piece == .ok
    }

    /// After `machine start`: an engine that cannot build on its Docker
    /// socket gets the fallback builder (policy `buildkit.registerBuildx`)
    /// or a one-line hint. Never fails the start.
    static func afterStart(_ client: HVFMachineClient, environment: [String: String]) async {
        let capabilities = await client.capabilities()
        guard capabilities.buildkit, !capabilities.grpcBuild else { return }
        let config = (try? HVFMachineConfig.load(from: client.layout.config)) ?? HVFMachineConfig()
        if config.effectiveCachePolicy.buildkit.registerBuildx {
            do {
                let setup = try HVFBuilderSetup(layout: client.layout, environment: environment)
                for line in try setup.install() { print("builder: \(line)") }
            } catch {
                FileHandle.standardError.write(
                    Data("warning: could not install the fallback builder: \(errorMessage(error))\n".utf8))
            }
            return
        }
        if fallbackContextInstalled(client.layout, environment: environment) == true { return }
        print(
            "hint: this engine cannot serve `docker build` on its socket; "
                + "`micropod machine builder install` adds a fallback builder (`\(HVFBuilderSetup.buildCommand)`)")
    }

    // MARK: cache policy

    static let policyValueFlags: Set<String> = [
        "--mode", "--default-scope", "--allow-scopes", "--tools", "--go-trimpath", "--pnpm-legacy-env",
        "--register-buildx", "--share-l0", "--go-proxy", "--npm-registry", "--max-bytes", "--max-age-days",
        "--min-free-bytes", "--default-trust", "--proxy-untrusted",
    ]

    static func cache(_ args: [String], client: HVFMachineClient, json: Bool) throws {
        guard args.first == "policy" else {
            throw UsageError(
                message: "machine cache policy [show] [--mode auto|off] [--default-scope S|none] "
                    + "[--allow-scopes a,b*] [--tools go,npm,…|all] [--share-l0 on|off] "
                    + "[--go-proxy URL|off] [--npm-registry URL|off] [--max-bytes SIZE|off] "
                    + "[--max-age-days N|off] [--min-free-bytes SIZE|off] "
                    + "[--default-trust trusted|untrusted] [--proxy-untrusted on|off] "
                    + "[--go-trimpath on|off] [--pnpm-legacy-env on|off] [--register-buildx on|off]")
        }
        let parsed = try parseArgs(
            Array(args.dropFirst()), boolFlags: [], valueFlags: policyValueFlags, commandName: "machine cache policy")
        guard parsed.positionals.isEmpty || parsed.positionals == ["show"] else {
            throw UsageError(message: "machine cache policy: unexpected \(parsed.positionals.joined(separator: " "))")
        }
        let layout = client.layout
        let editing = policyValueFlags.contains { parsed.value($0) != nil }
        guard editing else {
            let config = try HVFMachineConfig.load(from: layout.config)
            showPolicy(config.effectiveCachePolicy, layout: layout, json: json, applied: nil)
            return
        }
        guard parsed.positionals.isEmpty else {
            throw UsageError(message: "machine cache policy: `show` takes no flags")
        }
        if layout.installInProgress { throw layout.installInProgressError() }
        var config = try HVFMachineConfig.load(from: layout.config)
        let policy = try applyPolicyFlags(parsed, to: config.effectiveCachePolicy)
        config.cache = policy
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try config.save(to: layout.config)
        // A live supervisor (booting or running) launched its VMM with the
        // old file: replace it. Otherwise the next launch renders it.
        var applied = false
        if client.status().supervisorAlive {
            try HVFMachineSupervisor.rewritePolicy(layout: layout)
            applied = true
        }
        showPolicy(policy, layout: layout, json: json, applied: applied)
    }

    /// The policy with the flags in `parsed` applied and validated.
    static func applyPolicyFlags(_ parsed: ParsedArgs, to original: HVFMachineCachePolicy) throws
        -> HVFMachineCachePolicy
    {
        var policy = original
        func list(_ raw: String) -> [String] {
            raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func toggle(_ flag: String) throws -> Bool? {
            guard let raw = parsed.value(flag) else { return nil }
            switch raw.lowercased() {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            default: throw UsageError(message: "machine cache policy: \(flag) wants on or off, got '\(raw)'")
            }
        }
        if let raw = parsed.value("--mode") {
            guard let mode = HVFMachineCachePolicy.Mode(rawValue: raw.lowercased()) else {
                throw UsageError(message: "machine cache policy: --mode wants auto or off, got '\(raw)'")
            }
            policy.mode = mode
        }
        if let raw = parsed.value("--allow-scopes") {
            let scopes = list(raw)
            for scope in scopes where !HVFMachineCachePolicy.isValidScopePattern(scope) {
                throw UsageError(
                    message: "machine cache policy: --allow-scopes entry '\(scope)' must be '*', a scope name "
                        + "(^[a-z0-9][a-z0-9_-]{0,62}$) or a scope-name prefix ending in '*'")
            }
            policy.allowedScopes = scopes
        }
        if let raw = parsed.value("--default-scope") {
            let scope = raw == "none" ? "" : raw
            guard scope.isEmpty || HVFMachineCachePolicy.isValidScope(scope) else {
                throw UsageError(
                    message: "machine cache policy: --default-scope '\(raw)' must match ^[a-z0-9][a-z0-9_-]{0,62}$ "
                        + "(or be `none`: caches only for containers that name a scope)")
            }
            policy.defaultScope = scope
        }
        if let raw = parsed.value("--tools") {
            let names = raw.lowercased() == "all" ? HVFMachineCachePolicy.toolKinds : list(raw)
            do {
                policy.tools = try HVFMachineCachePolicy.normalizedTools(names)
            } catch {
                throw UsageError(message: "machine cache policy: \(withoutCode(errorMessage(error)))")
            }
        }
        if let value = try toggle("--go-trimpath") { policy.goTrimpath = value }
        if let value = try toggle("--pnpm-legacy-env") { policy.pnpmLegacyEnv = value }
        if let value = try toggle("--register-buildx") { policy.buildkit.registerBuildx = value }
        if let value = try toggle("--share-l0") { policy.sharedL0 = value }
        if let raw = parsed.value("--default-trust") {
            guard let trust = HVFMachineCachePolicy.Trust(rawValue: raw.lowercased()) else {
                throw UsageError(
                    message: "machine cache policy: --default-trust wants trusted or untrusted, got '\(raw)'")
            }
            policy.defaultTrust = trust
        }
        if let value = try toggle("--proxy-untrusted") { policy.proxyUntrusted = value }
        if let raw = parsed.value("--go-proxy") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            policy.goProxy = ["off", "none", ""].contains(trimmed.lowercased()) ? nil : trimmed
        }
        if let raw = parsed.value("--npm-registry") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            policy.npmRegistry = ["off", "none", ""].contains(trimmed.lowercased()) ? nil : trimmed
        }
        if let raw = parsed.value("--max-bytes") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if ["off", "none", "0", ""].contains(trimmed.lowercased()) {
                policy.maxBytes = nil
            } else {
                policy.maxBytes = try parseCacheSizeBytes(trimmed, flag: "--max-bytes")
            }
        }
        if let raw = parsed.value("--min-free-bytes") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if ["off", "none", "0", ""].contains(trimmed.lowercased()) {
                policy.minFreeBytes = nil
            } else {
                policy.minFreeBytes = try parseCacheSizeBytes(trimmed, flag: "--min-free-bytes")
            }
        }
        if let raw = parsed.value("--max-age-days") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if ["off", "none", "0", ""].contains(trimmed.lowercased()) {
                policy.maxAgeDays = nil
            } else {
                guard let days = Int(trimmed), days > 0 else {
                    throw UsageError(
                        message: "machine cache policy: --max-age-days wants a positive integer or off, got '\(raw)'")
                }
                policy.maxAgeDays = days
            }
        }
        do {
            try policy.validate()
        } catch {
            throw UsageError(message: "machine cache policy: \(withoutCode(errorMessage(error)))")
        }
        return policy
    }

    /// Parses human byte sizes like "20g", "512m", "1024k", or raw byte count.
    static func parseCacheSizeBytes(_ raw: String, flag: String) throws -> UInt64 {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let scale: UInt64
        let numPart: Substring
        if lower.hasSuffix("gib") {
            scale = 1 << 30
            numPart = lower.dropLast(3)
        } else if lower.hasSuffix("gb") {
            scale = 1 << 30
            numPart = lower.dropLast(2)
        } else if lower.hasSuffix("g") {
            scale = 1 << 30
            numPart = lower.dropLast(1)
        } else if lower.hasSuffix("mib") {
            scale = 1 << 20
            numPart = lower.dropLast(3)
        } else if lower.hasSuffix("mb") {
            scale = 1 << 20
            numPart = lower.dropLast(2)
        } else if lower.hasSuffix("m") {
            scale = 1 << 20
            numPart = lower.dropLast(1)
        } else if lower.hasSuffix("kib") {
            scale = 1 << 10
            numPart = lower.dropLast(3)
        } else if lower.hasSuffix("kb") {
            scale = 1 << 10
            numPart = lower.dropLast(2)
        } else if lower.hasSuffix("k") {
            scale = 1 << 10
            numPart = lower.dropLast(1)
        } else if lower.hasSuffix("b") {
            scale = 1
            numPart = lower.dropLast(1)
        } else {
            scale = 1
            numPart = lower[...]
        }
        guard let count = UInt64(numPart), count > 0 else {
            throw UsageError(message: "\(flag) wants a size such as 20g, 512m, or bytes, got '\(raw)'")
        }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: scale)
        guard !overflow else { throw UsageError(message: "\(flag) '\(raw)' is too large") }
        return bytes
    }

    /// "invalidArgument: hvf cache policy: …" → "hvf cache policy: …".
    static func withoutCode(_ message: String) -> String {
        guard let colon = message.firstIndex(of: ":"),
            message[..<colon].allSatisfy({ $0.isLetter }), message[message.index(after: colon)...].hasPrefix(" ")
        else { return message }
        return String(message[message.index(colon, offsetBy: 2)...])
    }

    struct PolicyReport: Encodable {
        var policy: HVFMachineCachePolicy
        var file: String
        /// nil for `show`; true when the running machine's file was replaced.
        var applied: Bool?
    }

    static func showPolicy(_ policy: HVFMachineCachePolicy, layout: HVFMachineLayout, json: Bool, applied: Bool?) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let report = PolicyReport(policy: policy, file: layout.cachePolicyFile.path, applied: applied)
            if let data = try? encoder.encode(report) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        let kinds = (try? HVFMachineCachePolicy.normalizedTools(policy.tools)) ?? policy.tools
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        print("mode:            \(policy.mode.rawValue)")
        print(
            "default scope:   \(policy.defaultScope.isEmpty ? "none (only containers naming a scope)" : policy.defaultScope)"
        )
        print(
            "allowed scopes:  \(policy.allowedScopes.isEmpty ? "none" : policy.allowedScopes.joined(separator: ", "))")
        print("tools:           \(kinds.joined(separator: ", "))")
        print("go -trimpath:    \(onOff(policy.goTrimpath))")
        print("pnpm legacy env: \(onOff(policy.pnpmLegacyEnv)) (npm_config_store_dir for pnpm 9 and 10)")
        print(
            "shared L0 tier:  \(onOff(policy.sharedL0)) "
                + "(\(HVFMachineCachePolicy.globalKinds.joined(separator: ", ")) shared in scope 'global'; "
                + "every other store stays per scope)")
        print(
            "default trust:   \(policy.effectiveDefaultTrust.rawValue)"
                + (policy.defaultTrust == nil ? " (not set)" : "")
                + " (containers naming no io.micropod.cache.trust)")
        print("proxy untrusted: \(onOff(policy.proxyUntrusted)) (goProxy/npmRegistry for untrusted containers)")
        if let gp = policy.goProxy { print("go proxy (L0):   \(gp)") }
        if let nr = policy.npmRegistry { print("npm proxy (L0):  \(nr)") }
        if let maxB = policy.maxBytes { print("budget ceiling:  \(CacheCommands.formatBytes(maxB))") }
        if let minF = policy.minFreeBytes { print("min free floor:  \(CacheCommands.formatBytes(minF))") }
        if let age = policy.maxAgeDays { print("max idle age:    \(age)d") }
        print("register buildx: \(onOff(policy.buildkit.registerBuildx))")
        if !policy.extra.isEmpty { print("other keys:      \(policy.extra.keys.sorted().joined(separator: ", "))") }
        switch applied {
        case true?: print("applied (\(layout.cachePolicyFile.path))")
        case false?: print("applies at next start")
        case nil: break
        }
    }

    // MARK: builder

    static func builder(_ args: [String], layout: HVFMachineLayout, environment: [String: String], json: Bool) throws {
        let sub = args.first ?? "status"
        _ = try parseArgs(Array(args.dropFirst()), boolFlags: [], valueFlags: [], commandName: "machine builder \(sub)")
        let setup = try HVFBuilderSetup(layout: layout, environment: environment)
        switch sub {
        case "install":
            for line in try setup.install() { print(line) }
            print("build with `\(HVFBuilderSetup.buildCommand) …`")
        case "status":
            let status = try setup.status()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(status), as: UTF8.self))
                return
            }
            func describe(_ piece: HVFBuilderSetup.Piece, _ target: String?) -> String {
                switch piece {
                case .ok: return "ok (\(target ?? "?"))"
                case .absent: return "absent"
                case .mismatch: return "not this machine's (\(target ?? "?"))"
                }
            }
            print("context '\(HVFBuilderSetup.contextName)': \(describe(status.context, status.contextHost))")
            print("builder '\(HVFBuilderSetup.builderName)': \(describe(status.builder, status.builderEndpoint))")
            print("default of the context: \(status.contextDefault ? "yes" : "no")")
            print(status.installed ? "installed" : "not installed (`micropod machine builder install`)")
        case "rm", "remove", "uninstall":
            for line in try setup.remove() { print(line) }
        default:
            throw UsageError(message: "machine builder install|status|rm")
        }
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
