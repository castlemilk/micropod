import Darwin
import Foundation
import MicropodCore
import MicropodRuntime

enum CICommands {
    static let help = """
        micropod ci — Dedicated Apple Silicon Linux CI worker (HVF + containerd + BuildKit)

        Worker Lifecycle:
          micropod ci runner-start | runner-status | runner-health | runner-stop
                                            manage and inspect the dedicated containerd CI worker
          micropod ci runner-endpoint | runner-docker-endpoint | runner-buildkit-endpoint
                                            print native OCI, Docker-compatible, or BuildKit socket URI
          micropod ci start | status | health | endpoint | stop
                                            manage the default CI worker (Docker or containerd)
          micropod ci cpu-plan [--topology] show next boot's vCPU plan and host CPU tiers
          micropod ci set-cpus COUNT|auto   change a stopped worker's CPU policy (retains disk)
          micropod ci repair-network        reconnect the private network while containers run

        Workloads, Builds & Caching:
          micropod ci docker [arguments]    run Docker CLI / Buildx / Compose against this worker
          micropod ci run [--scratch-mib N] [--cache npm|go|python] [--cache-scope NAME] [docker opts] IMAGE [cmd...]
                                            run a job with persistent, optionally scoped package caches
          micropod ci create [options]      prepare a job with the same cache & Docker create options
          micropod ci snapshot BASE_IMAGE [DIRECTORY]
                                            bake a checkout into a reusable BuildKit job image ID
          micropod ci warm-go --cache-scope NAME [--offline] [--trace-tools] SOURCE_IMAGE_ID [PKG ...]
                                            warm shared Go compile and vet caches before fan-out
          micropod ci job TRUST IMAGE COMMAND [ARG ...]
                                            submit a trusted crun or VM-isolated native OCI job
          micropod ci runner-prime COUNT    pre-warm up to 32 single-use pods for trusted OCI jobs

        Observability & Service:
          micropod ci metrics [--usage|--kernel|--prometheus|--otlp]
          micropod ci runner-metrics [--prometheus|--otlp]
                                            live cache, kernel, Prometheus, or OTLP metrics (see `micropod telemetry`)
          micropod ci serve                 supervise the worker in the foreground
          micropod ci install-service | uninstall-service | launch-agent [--process-type Standard|Interactive]
                                            manage the launchd background service
        """

    static func main(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(help)
            return 2
        }
        let runnerCommands = [
            "job", "runner-prime", "runner-start", "runner-status", "runner-health", "runner-metrics", "runner-stop",
            "runner-endpoint", "runner-docker-endpoint", "runner-buildkit-endpoint",
        ]
        var environment = ProcessInfo.processInfo.environment
        if runnerCommands.contains(command) { environment["MICROPOD_CI_ENGINE"] = "containerd" }
        let worker = CIWorker(environment: environment)
        if ["--help", "-h", "help"].contains(command) {
            print(help)
            return 0
        }
        let processType =
            command == "launch-agent" && args.count == 3 && args[1] == "--process-type"
            ? CIWorker.LaunchProcessType(rawValue: args[2]) : nil
        guard
            ["run", "create", "docker", "snapshot", "warm-go", "job", "runner-prime"].contains(command)
                || args == ["cpu-plan", "--topology"]
                || args == ["metrics", "--usage"]
                || args == ["metrics", "--kernel"]
                || args == ["metrics", "--prometheus"]
                || args == ["metrics", "--otlp"]
                || args == ["runner-metrics", "--prometheus"]
                || args == ["runner-metrics", "--otlp"]
                || processType != nil
                || (command == "set-cpus" && args.count == 2)
                || args.count == 1
        else {
            print(help)
            return 2
        }
        do {
            switch command {
            case "cpu-plan" where args.count == 2: try printStatus(worker.cpuTopologyPlan())
            case "cpu-plan": try printStatus(worker.cpuPlan())
            case "set-cpus":
                guard args.count == 2 else {
                    print(help)
                    return 2
                }
                try printStatus(worker.setCPUs(args[1]))
            case "runner-status": try printStatus(await worker.status())
            case "runner-health", "health":
                try printStatus(
                    await OTLPTracer.withSpan(name: "ci.worker.health", environment: environment) {
                        try await worker.health()
                    })
            case "runner-stop":
                try await OTLPTracer.withSpan(name: "ci.worker.stop", environment: environment) {
                    try await worker.stop()
                }
            case "job", "runner-prime", "runner-start", "runner-endpoint", "runner-docker-endpoint",
                "runner-buildkit-endpoint":
                guard let executable = Bundle.main.executableURL else {
                    throw MicropodError.message("Missing CLI executable")
                }
                guard command != "job" || args.count >= 4 && ["trusted", "untrusted"].contains(args[1]) else {
                    print(help)
                    return 2
                }
                if command == "runner-start" {
                    let st = try await OTLPTracer.withSpan(
                        name: "ci.worker.start",
                        attributes: [
                            "micropod.vmm": environment["MICROPOD_CI_VMM"] ?? "vz",
                            "micropod.restore": environment["MICROPOD_CI_HVF_RESTORE_FROM"] != nil ? "true" : "false",
                        ],
                        environment: environment
                    ) {
                        try await worker.start(executable: executable)
                    }
                    try printStatus(st)
                    return 0
                }
                if command == "runner-buildkit-endpoint" {
                    print(try await worker.nativeBuildKitEndpoint(executable: executable))
                    return 0
                }
                if command == "runner-docker-endpoint" {
                    print(try await worker.nativeDockerEndpoint(executable: executable))
                    return 0
                }
                if command == "runner-endpoint" {
                    print(try await worker.runEndpoint(executable: executable))
                    return 0
                }
                if command == "runner-prime" {
                    guard args.count == 2, let count = Int(args[1]), (1...32).contains(count) else {
                        print(help)
                        return 2
                    }
                }
                if command == "job" && args[1] == "untrusted" {
                    guard environment["MICROPOD_CI_CACHE_SCOPE", default: ""].isEmpty else {
                        throw MicropodError.message("Untrusted jobs cannot open a shared writable cache")
                    }
                    guard args[2].wholeMatch(of: #/[^\s@]+@sha256:[0-9a-f]{64}/#) != nil else {
                        throw MicropodError.message("An untrusted job needs a scheduler-approved image digest")
                    }
                    switch environment["MICROPOD_CI_UNTRUSTED_RUNTIME"] ?? "apple-vm" {
                    case "apple-vm":
                        return try await SandboxVM.isolatedCIJob(image: args[2], arguments: Array(args.dropFirst(3)))
                    case "kata": break
                    default: throw MicropodError.message("MICROPOD_CI_UNTRUSTED_RUNTIME must select apple-vm or kata")
                    }
                }
                _ = try await worker.runEndpoint(executable: executable)
                let bin = executable.resolvingSymlinksInPath().deletingLastPathComponent()
                let clients = [
                    environment["MICROPOD_OCI_CLIENT"], bin.appendingPathComponent("micropod-oci").path,
                    bin.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                        "oci-tools/client"
                    ).path,
                ]
                guard
                    let client = clients.compactMap({ $0 }).first(where: {
                        FileManager.default.isExecutableFile(atPath: $0)
                    })
                else { throw MicropodError.message("Install the native client or set MICROPOD_OCI_CLIENT") }
                let argv = ([client, worker.socket.path] + args).map { strdup($0) } + [nil]
                defer { argv.forEach { free($0) } }
                _ = argv.withUnsafeBufferPointer { execv(client, $0.baseAddress!) }
                throw MicropodError.message("Could not start the native client")
            case "serve": return try await worker.serve()
            case "uninstall-service": try await worker.uninstallService()
            case "install-service", "launch-agent":
                guard let executable = Bundle.main.executableURL else {
                    throw MicropodError.message("Cannot locate micropod executable")
                }
                if command == "launch-agent" {
                    FileHandle.standardOutput.write(
                        try worker.launchAgent(executable: executable, processType: processType))
                } else {
                    try printStatus(await worker.installService(executable: executable))
                }
            case "metrics" where args.last == "--kernel": try printStatus(await worker.kernelMetrics())
            case "metrics" where args.last == "--prometheus", "runner-metrics" where args.last == "--prometheus":
                print(try await worker.prometheusMetrics(), terminator: "")
            case "metrics" where args.last == "--otlp", "runner-metrics" where args.last == "--otlp":
                FileHandle.standardOutput.write(try await worker.otlpMetricsJSON())
                FileHandle.standardOutput.write(Data("\n".utf8))
            case "metrics", "runner-metrics": try printStatus(await worker.metrics(includeUsage: args.count == 2))
            case "repair-network": try printStatus(await worker.repairNetwork())
            case "stop": try await worker.stop()
            case "status": try printStatus(await worker.status())
            case "start", "endpoint", "run", "create", "docker", "snapshot", "warm-go":
                guard let executable = Bundle.main.executableURL else {
                    throw MicropodError.message("Cannot locate micropod executable")
                }
                if ["run", "create", "docker", "snapshot", "warm-go"].contains(command) {
                    var options: [String]
                    switch command {
                    case "run", "create": options = try [command, "--rm"] + runArguments(args.dropFirst())
                    case "snapshot": options = try snapshotArguments(args.dropFirst())
                    case "warm-go": options = try warmGoArguments(args.dropFirst())
                    default: options = Array(args.dropFirst())
                    }
                    let endpoint =
                        try await worker.isNativeRunner
                        ? worker.nativeDockerEndpoint(executable: executable)
                        : worker.runEndpoint(executable: executable)
                    if worker.isNativeRunner
                        && (command == "snapshot" || options.first == "build"
                            || options.starts(with: ["buildx", "build"]))
                    {
                        if command == "snapshot"
                            || !(options.contains("--builder")
                                || options.contains(where: { $0.hasPrefix("--builder=") }))
                        {
                            let address = try await worker.nativeBuildKitEndpoint(executable: executable)
                            let instance = try await worker.status().worker
                            let buildxConfig =
                                environment["BUILDX_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
                                ?? worker.directory.appendingPathComponent("buildx").path
                            let name = try nativeBuilder(
                                worker: instance, endpoint: endpoint, buildkit: address, buildxConfig: buildxConfig)
                            setenv("BUILDX_CONFIG", buildxConfig, 1)
                            if command == "snapshot" { options[3] = name } else { setenv("BUILDX_BUILDER", name, 1) }
                        }
                    }
                    let recipe = command == "snapshot" ? Pipe() : nil
                    if let recipe {
                        try recipe.fileHandleForWriting.write(contentsOf: Data(snapshotDockerfile.utf8))
                        try recipe.fileHandleForWriting.close()
                        guard dup2(recipe.fileHandleForReading.fileDescriptor, STDIN_FILENO) != -1,
                            fcntl(STDIN_FILENO, F_SETFD, 0) != -1
                        else {
                            throw POSIXError(.init(rawValue: errno) ?? .EIO)
                        }
                        // The Mac's selected Buildx builder can point to another engine.
                        unsetenv("BUILDX_BUILDER")
                    }
                    // Replace the CLI so job streams, signals and exit status belong to Docker.
                    let arguments = ["docker", "--host", endpoint] + options
                    for key in ["DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"] { unsetenv(key) }
                    setenv("DOCKER_HOST", endpoint, 1)
                    let argv = arguments.map { strdup($0) } + [nil]
                    defer { argv.forEach { free($0) } }
                    _ = withExtendedLifetime(recipe) { execvp("docker", argv) }
                    throw MicropodError.message("Cannot execute docker: \(String(cString: strerror(errno)))")
                }
                let current = try await worker.start(executable: executable)
                if command == "endpoint" && worker.isNativeRunner {
                    print(try await worker.nativeDockerEndpoint(executable: executable))
                } else if command == "endpoint" {
                    print(current.endpoint)
                } else {
                    try printStatus(current)
                }
            default:
                print(help)
                return 2
            }
            return 0
        } catch let error as UsageError {
            FileHandle.standardError.write(Data(("micropod ci: " + error.message + "\n").utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data(("micropod ci: " + error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    // Buildx keeps named builders in BUILDX_CONFIG. Scoping this to the worker's
    // private directory avoids polluting ~/.docker/buildx/instances and prevents
    // Docker Desktop's com.docker.build from holding persistent gRPC connections
    // to this worker's buildkit.sock.
    static func nativeBuilder(
        worker: UUID, endpoint: String, buildkit: String, buildxConfig: String
    ) throws -> String {
        try FileManager.default.createDirectory(
            atPath: buildxConfig, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let name = "micropod-" + worker.uuidString.lowercased()
        func buildx(_ args: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["docker", "--host", endpoint, "buildx"] + args
            var env = ProcessInfo.processInfo.environment
            for key in ["DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "BUILDX_BUILDER"] {
                env.removeValue(forKey: key)
            }
            env["DOCKER_HOST"] = endpoint
            env["BUILDX_CONFIG"] = buildxConfig
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        func matches() throws -> Bool {
            let (status, text) = try buildx(["inspect", name])
            guard status == 0 else { return false }
            let fields = text.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (
                    String(parts[0]).trimmingCharacters(in: .whitespaces),
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
                )
            }
            return fields.filter { $0.0 == "Driver" }.map { $0.1 } == ["remote"]
                && fields.filter { $0.0 == "Endpoint" }.map { $0.1 } == [buildkit]
        }
        if try matches() { return name }
        let created = try buildx(["create", "--name", name, "--driver", "remote", buildkit])
        // A concurrent client can win registration. Verify the identity in both cases.
        guard try matches() else {
            throw MicropodError.message("Cannot verify the Buildx builder for this worker. " + created.1)
        }
        return name
    }

    // BuildKit applies the checkout's .dockerignore and shares the immutable layer among jobs.
    static let snapshotDockerfile = """
        ARG BASE_IMAGE
        FROM ${BASE_IMAGE}
        COPY . /workspace/
        WORKDIR /workspace

        """

    static func snapshotArguments(_ arguments: ArraySlice<String>) throws -> [String] {
        guard (1...2).contains(arguments.count), let base = arguments.first, !base.isEmpty,
            !base.hasPrefix("-"), !base.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw UsageError(message: "ci snapshot requires BASE_IMAGE [DIRECTORY]") }
        let directory = URL(fileURLWithPath: arguments.dropFirst().first ?? ".", isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw UsageError(message: "ci snapshot requires an existing checkout directory") }
        return [
            "buildx", "build", "--builder", "default", "--load", "--quiet", "--provenance=false",
            "--build-arg", "BASE_IMAGE=" + base, "--file", "-", directory.path,
        ]
    }

    // Consume only the Micropod prefix. Leave Docker options and the image's argv intact.
    static func runArguments(_ arguments: ArraySlice<String>) throws -> [String] {
        var job = arguments
        var caches = Set<String>()
        var scope: String?
        var scratchMiB: Int?
        while let option = job.first, ["--cache", "--cache-scope", "--scratch-mib"].contains(option) {
            let value = job.dropFirst().first
            if option == "--scratch-mib" {
                guard scratchMiB == nil, let value, let size = Int(value), (1...262144).contains(size) else {
                    throw UsageError(message: "--scratch-mib needs one size from 1 to 262144 MiB")
                }
                scratchMiB = size
            } else if option == "--cache" {
                guard let value, ["npm", "go", "python"].contains(value) else {
                    throw UsageError(message: "--cache accepts npm, go or python")
                }
                caches.insert(value)
            } else {
                guard scope == nil, let value, value.wholeMatch(of: #/[a-z0-9][a-z0-9_-]{0,62}/#) != nil else {
                    throw UsageError(message: "--cache-scope needs one 1–63 character name using a-z, 0-9, _ or -")
                }
                scope = value
            }
            job = job.dropFirst(2)
        }
        guard !job.isEmpty else { throw UsageError(message: "a CI job requires an image") }
        guard scope == nil || !caches.isEmpty else { throw UsageError(message: "--cache-scope requires --cache") }

        if caches.contains("python"), scope == nil {
            throw UsageError(
                message: "--cache python requires --cache-scope for the trusted source and pinned toolchain")
        }
        let prefix = scope.map { "micropod-ci-scoped-" + $0 } ?? "micropod-ci"
        func mount(_ store: String, _ variable: String) -> [String] {
            let path = "/cache/" + store
            // Existing worker-wide volumes preserve Docker's image copy-up on first attach.
            let copyOption = scope == nil ? "" : ",volume-nocopy"
            return [
                "--mount", "type=volume,src=\(prefix)-\(store),dst=\(path)\(copyOption)", "-e", "\(variable)=\(path)",
            ]
        }
        var options: [String] = []
        if let scratchMiB {
            options += ["--tmpfs", "/tmp:rw,exec,nosuid,nodev,size=\(scratchMiB)m,mode=1777"]
        }
        if caches.contains("npm") { options += mount("npm", "npm_config_cache") }
        if caches.contains("python") { options += mount("pycache", "PYTHONPYCACHEPREFIX") }
        if caches.contains("go") {
            options += mount("gomod", "GOMODCACHE") + mount("gobuild", "GOCACHE")
        }
        return options + job
    }

    private static func printStatus(_ status: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(status), as: UTF8.self))
    }
}
