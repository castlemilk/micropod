import Foundation
import MicropodCore

/// The sandbox tools over SandboxService. Sandboxes are micro-VMs that boot
/// in the API daemon's process (which carries the virtualization
/// entitlement), so a run is: StartSandbox (idle), StartProcess, its
/// StreamProcess to the exit, then DeleteContainer — or, for a checkpoint
/// that exited 0, CheckpointSandbox, which keeps the disk and stops it.
struct SandboxTools {
    static let names: Set<String> = [
        "sandbox_run", "sandbox_exec", "sandbox_files", "sandbox_status", "sandbox_checkpoint",
        "sandbox_checkpoints", "sandbox_checkpoint_create", "sandbox_checkpoint_delete",
    ]

    let api: LocalAPI
    let environment: [String: String]

    /// `micropod sandbox run`'s sizing defaults.
    static let defaultCPUs: UInt32 = 2
    static let defaultMemoryMiB: UInt64 = 2048
    /// Output kept per run: its last 64 KiB, as the CLI-backed tool kept.
    static let outputCap = 64 * 1024

    func call(_ name: String, _ args: MCPArguments) async throws -> APITools.Reply {
        switch name {
        case "sandbox_status":
            let status = try await api.unary(
                "SandboxService", "GetSandboxStatus", Micropod_V1_Empty(), as: Micropod_V1_SandboxStatus.self)
            return .init(text: ControlPlaneJSON.prettyText(ControlPlaneJSON.sandboxStatus(status)))

        case "sandbox_run":
            return try await run(args, checkpoint: nil)

        case "sandbox_checkpoint_create":
            return try await run(args, checkpoint: args.string("name"))

        case "sandbox_checkpoints":
            return .init(text: try await checkpoints())

        case "sandbox_checkpoint_delete":
            return .init(text: try await deleteCheckpoint(args.string("name")))

        case "sandbox_checkpoint":
            switch args.string("action") {
            case "create":
                guard !args.string("name").isEmpty, !args.string("command").isEmpty else {
                    throw MCPArgumentError(message: "sandbox_checkpoint create requires name and command")
                }
                return try await run(args, checkpoint: args.string("name"))
            case "delete":
                guard !args.string("name").isEmpty else {
                    throw MCPArgumentError(message: "sandbox_checkpoint delete requires name")
                }
                return .init(text: try await deleteCheckpoint(args.string("name")))
            default:
                return .init(text: try await checkpoints())
            }

        case "sandbox_exec":
            let (code, output) = try await process(
                in: args.string("id"), command: args.string("command"), workdir: args.optionalString("workdir"),
                env: args.list("env"), timeout: args.integer("timeout"))
            return .init(text: "exit \(code)\n\(output)", isError: code != 0)

        case "sandbox_files":
            return try await files(args)

        default:
            throw MicropodError.message("\(name) is not a sandbox tool")
        }
    }

    // MARK: Runs

    private func run(_ args: MCPArguments, checkpoint: String?) async throws -> APITools.Reply {
        let request = try startRequest(args)
        let sandbox = try await api.unary(
            "SandboxService", "StartSandbox", request, as: Micropod_V1_ContainerRef.self,
            timeout: api.longCallSeconds)
        var kept = false
        do {
            let (code, output) = try await process(
                in: sandbox.id, command: args.string("command"), workdir: args.optionalString("workdir"),
                env: [], timeout: args.integer("timeout"))
            if let checkpoint, code == 0 {
                try await api.call(
                    "SandboxService", "CheckpointSandbox",
                    Micropod_V1_CheckpointSandboxRequest.with {
                        $0.id = sandbox.id
                        $0.name = checkpoint
                    }, timeout: api.longCallSeconds)
                kept = true
            }
            try? await remove(sandbox.id)
            let note = checkpoint.map {
                kept ? "\ncheckpoint \($0) saved" : "\ncheckpoint \($0) not saved (exit \(code))"
            }
            return .init(text: "exit \(code)\n\(output)\(note ?? "")", isError: code != 0)
        } catch {
            try? await remove(sandbox.id)
            throw error
        }
    }

    private func remove(_ id: String) async throws {
        try await api.call(
            "ContainerService", "DeleteContainer",
            Micropod_V1_DeleteContainerRequest.with {
                $0.id = id
                $0.force = true
            }, timeout: api.longCallSeconds)
    }

    /// `/bin/sh -c command` in a running sandbox: its exit code and its
    /// stdout and stderr as they came. Past `timeout` seconds it is killed
    /// and reported as exit 124, as `micropod sandbox run --timeout` does.
    private func process(
        in id: String, command: String, workdir: String?, env: [String], timeout: Int64?
    ) async throws -> (Int32, String) {
        let started = try await api.unary(
            "SandboxService", "StartProcess",
            Micropod_V1_StartProcessRequest.with {
                $0.id = id
                $0.command = ["/bin/sh", "-c", command]
                if let workdir { $0.cwd = workdir }
                $0.env = env
            }, as: Micropod_V1_ProcessRef.self)
        let output = OutputTail(cap: Self.outputCap)
        let exit = ExitBox()
        let limit = timeout.map { Duration.seconds($0) } ?? .seconds(api.longCallSeconds)
        try await api.stream(
            "SandboxService", "StreamProcess", started, as: Micropod_V1_ProcessEvent.self, deadline: limit
        ) { event in
            switch event.event {
            case .stdout(let data)?, .stderr(let data)?: output.append(data)
            case .exitCode(let code)?:
                // Read on to the end of the stream, which follows at once,
                // so the connection is kept.
                exit.code = code
            case nil: break
            }
            return true
        }
        guard let code = exit.code else {
            // The deadline passed first.
            try? await api.call(
                "SandboxService", "SignalProcess",
                Micropod_V1_SignalProcessRequest.with {
                    $0.id = id
                    $0.processID = started.processID
                    $0.signal = "SIGKILL"
                })
            return (124, output.text + "\n(killed after \(timeout ?? Int64(api.longCallSeconds)) s)")
        }
        return (code, output.text)
    }

    /// StartSandboxRequest from the tool's options (the CLI's flags).
    func startRequest(_ args: MCPArguments) throws -> Micropod_V1_StartSandboxRequest {
        let allowHostWrites = args.flag("allow_host_writes")
        var request = Micropod_V1_StartSandboxRequest()
        if let from = args.optionalString("from") {
            request.fromCheckpoint = from
        } else {
            request.image = args.optionalString("image") ?? "alpine:latest"
        }
        request.cpus = args.integer("cpus").map { UInt32(clamping: $0) } ?? Self.defaultCPUs
        request.memoryMib = args.integer("memory").map { UInt64(clamping: $0) } ?? Self.defaultMemoryMiB
        if let workdir = args.optionalString("workdir") { request.workdir = workdir }
        request.env = args.list("env")
        request.allowNet = args.flag("allow_net")
        request.mounts = try args.list("mounts").map { try Self.mount($0, allowHostWrites: allowHostWrites) }
        request.ports = try args.list("ports").map(Self.port)
        var options = Micropod_V1_SandboxOptions()
        options.allowHosts = args.list("allow_hosts")
        options.exposeHost = try args.list("expose_host").map { raw in
            guard let port = UInt32(raw), (1...65535).contains(port) else {
                throw MCPArgumentError(message: "expose_host wants a port, got '\(raw)'")
            }
            return port
        }
        for spec in args.list("secrets") {
            let (name, secret) = try Self.secret(spec, environment: environment)
            options.secrets[name] = secret
        }
        request.options = options
        // No command: the sandbox idles until the process below runs.
        return request
    }

    /// `host:/guest[:ro|rw]`: the host copy is untouched unless `:rw` is
    /// asked for, and that needs allow_host_writes.
    static func mount(_ spec: String, allowHostWrites: Bool) throws -> Micropod_V1_SandboxMount {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else {
            throw MCPArgumentError(message: "mounts '\(spec)' — want host:/guest[:rw|ro]")
        }
        let mode: String
        switch parts.count == 3 ? parts[2] : "" {
        case "": mode = "overlay"
        case "ro": mode = "ro"
        case "rw":
            guard allowHostWrites else {
                throw MCPArgumentError(message: "mounts '\(spec)' writes to the host — add allow_host_writes")
            }
            mode = "rw"
        default:
            throw MCPArgumentError(message: "mounts '\(spec)' — mode must be rw or ro")
        }
        return .with {
            $0.hostPath = (parts[0] as NSString).expandingTildeInPath
            $0.guestPath = parts[1]
            $0.mode = mode
        }
    }

    /// `[hostIP:]hostPort:guestPort[/tcp]`.
    static func port(_ spec: String) throws -> Micropod_V1_PortMapping {
        var body = spec
        if let slash = body.firstIndex(of: "/") {
            guard body[body.index(after: slash)...] == "tcp" else {
                throw MCPArgumentError(message: "ports '\(spec)' — only tcp is forwarded")
            }
            body = String(body[..<slash])
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func number(_ text: String) throws -> UInt32 {
            guard let port = UInt32(text), (1...65535).contains(port) else {
                throw MCPArgumentError(message: "ports '\(spec)' — want [hostIP:]hostPort:guestPort")
            }
            return port
        }
        switch parts.count {
        case 2:
            let host = try number(parts[0])
            let guest = try number(parts[1])
            return .with {
                $0.hostPort = host
                $0.containerPort = guest
            }
        case 3:
            let host = try number(parts[1])
            let guest = try number(parts[2])
            return .with {
                $0.hostIp = parts[0]
                $0.hostPort = host
                $0.containerPort = guest
            }
        default:
            throw MCPArgumentError(message: "ports '\(spec)' — want [hostIP:]hostPort:guestPort")
        }
    }

    /// `NAME=HOST_ENV@host[,host]`: the guest sees a placeholder; the value
    /// comes from this server's environment.
    static func secret(_ spec: String, environment: [String: String]) throws -> (String, Micropod_V1_SandboxSecret) {
        guard let eq = spec.firstIndex(of: "="), let at = spec.lastIndex(of: "@"), eq < at else {
            throw MCPArgumentError(message: "secrets '\(spec)' — want NAME=ENV_VAR@host[,host]")
        }
        let name = String(spec[..<eq])
        let source = String(spec[spec.index(after: eq)..<at])
        let hosts = spec[spec.index(after: at)...].split(separator: ",").map(String.init)
        guard !name.isEmpty, !source.isEmpty, !hosts.isEmpty else {
            throw MCPArgumentError(message: "secrets '\(spec)' — want NAME=ENV_VAR@host[,host]")
        }
        guard let value = environment[source], !value.isEmpty else {
            throw MCPArgumentError(message: "secrets \(name): host env var \(source) is unset")
        }
        return (
            name,
            .with {
                $0.value = value
                $0.hosts = hosts
            }
        )
    }

    // MARK: Checkpoints

    private func checkpoints() async throws -> String {
        let list = try await api.unary(
            "SandboxService", "ListCheckpoints", Micropod_V1_Empty(), as: Micropod_V1_ListCheckpointsResponse.self)
        guard !list.checkpoints.isEmpty else { return "no checkpoints" }
        return list.checkpoints.map { item in
            "\(item.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                + String(format: "%7.0f MB  ", Double(item.sizeBytes) / 1_048_576) + item.image
        }.joined(separator: "\n")
    }

    private func deleteCheckpoint(_ name: String) async throws -> String {
        try await api.call("SandboxService", "DeleteCheckpoint", Micropod_V1_CheckpointRef.with { $0.name = name })
        return "removed \(name)"
    }

    // MARK: Files

    private func files(_ args: MCPArguments) async throws -> APITools.Reply {
        let id = args.string("id")
        let path = args.string("path")
        switch args.string("action") {
        case "read":
            let file = try await api.unary(
                "SandboxService", "ReadFile",
                Micropod_V1_PathRequest.with {
                    $0.id = id
                    $0.path = path
                }, as: Micropod_V1_FileContent.self)
            guard let text = String(data: file.data, encoding: .utf8) else {
                return .init(text: "\(path): \(file.data.count) bytes, not UTF-8 text", isError: true)
            }
            return .init(text: text)
        case "write":
            let content = args.string("content")
            try await api.call(
                "SandboxService", "WriteFile",
                Micropod_V1_WriteFileRequest.with {
                    $0.id = id
                    $0.path = path
                    $0.data = Data(content.utf8)
                    $0.append = args.flag("append")
                    $0.createParents = true
                })
            return .init(text: "wrote \(content.utf8.count) bytes to \(path)")
        default:
            let listing = try await api.unary(
                "SandboxService", "ListDir",
                Micropod_V1_PathRequest.with {
                    $0.id = id
                    $0.path = path
                }, as: Micropod_V1_ListDirResponse.self)
            guard !listing.entries.isEmpty else { return .init(text: "\(path): empty") }
            return .init(
                text: listing.entries.map { "\($0.name)\t\($0.type)\t\($0.size)" }.joined(separator: "\n"))
        }
    }
}

/// The last `cap` bytes of a process's output.
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > cap { data.removeFirst(data.count - cap) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// A process's exit code once its stream said it.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    var code: Int32? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
