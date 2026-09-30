import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import MicropodCore
import Security

/// In-process ephemeral micro-VMs (`SandboxVM`) as a micropod runtime.
///
/// Sessions live in this process: VMs die with it, and records are
/// in-memory. Each session boots from a clonefile of a cached rootfs, runs
/// its command once and keeps its logs + exit code until deleted — a
/// stopped sandbox cannot be restarted (run a new one).
public struct SandboxEngine: RuntimeEngine, ContainerServing, LogStreaming {
    let store: SessionStore
    /// Processes started through `SandboxService` (the SDK surface).
    let processes = SandboxProcessTable()

    public var name: String { "sandbox" }
    public var kind: String { "microvm" }
    public var summary: String { "micropod sandbox — ephemeral in-process micro-VM per run (CI fast path)" }
    public var capabilities: [String] {
        ["run", "create", "start", "stop", "kill", "delete", "exec", "logs"]
    }
    public var containers: any ContainerServing { self }
    public var logs: any LogStreaming { self }
    public var stats: (any StatsSampling)? { nil }
    /// `micropod.network=none` boots the sandbox without a network device.
    public static let networkLabel = "micropod.network"

    public init(root: URL = SandboxVM.root.appendingPathComponent("sessions")) {
        store = SessionStore(root: root)
    }

    public func probe() async -> EngineProbe {
        let endpoint = SandboxVM.root.path
        guard Self.hasVirtualizationEntitlement else {
            return EngineProbe(
                available: false,
                reason:
                    "this process lacks com.apple.security.virtualization (sign it with signing/micropod-cli.entitlements)",
                endpoint: endpoint)
        }
        do {
            _ = try SandboxVM.kernelURL()
        } catch {
            return EngineProbe(available: false, reason: error.localizedDescription, endpoint: endpoint)
        }
        return EngineProbe(available: true, endpoint: endpoint)
    }

    static let hasVirtualizationEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.virtualization" as CFString, nil)
        return (value as? Bool) == true
    }()

    public func owns(_ id: String) async -> Bool { await store.session(id) != nil }

    public func awaitStateChange(_ id: String, timeout: Duration) async -> Bool {
        await store.awaitFinish(id, timeout: timeout)
    }

    /// The main process's exit code once the sandbox has exited.
    public func exitCode(_ id: String) async -> Int32? {
        guard let session = await store.session(id), session.state == .exited else { return nil }
        return session.exitCode
    }

    // MARK: ContainerServing

    public func list() async throws -> [Micropod_V1_Container] {
        await store.all().map { $0.container }
    }

    public func inspect(_ id: String) async throws -> Data {
        let session = try await store.require(id)
        return try JSONSerialization.data(
            withJSONObject: session.inspectJSON, options: [.prettyPrinted, .sortedKeys])
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        let options = try Self.options(from: request)
        let id = request.name ?? "sbx-" + UUID().uuidString.lowercased().prefix(12)
        guard id.count <= LinuxContainer.maxIDLength,
            id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
        else { throw MicropodError.message("invalidArgument: invalid sandbox name '\(id)'") }
        try await store.add(
            Session(
                id: id, image: request.image, options: options,
                labels: Dictionary(request.labels.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }),
                runDir: store.root.appendingPathComponent(id)))
        return id
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        let id = try await create(request)
        do {
            try await start(id)
        } catch {
            try? await delete(id, force: true)
            throw error
        }
        return id
    }

    /// ContainerRunRequest → SandboxVM.Options. Anything the sandbox can't
    /// honour fails loudly rather than being dropped.
    public static func options(from request: ContainerRunRequest) throws -> SandboxVM.Options {
        var options = SandboxVM.Options(base: .image(request.image))
        // No host address means every interface, as the API documents and
        // the apple and docker engines do (`sandbox run -p` is loopback).
        options.ports = try request.publishedPorts.map { spec in
            guard spec.transportProtocol.lowercased() == "tcp" else {
                throw MicropodError.unsupported(
                    "runtime 'sandbox' forwards tcp ports only, not \(spec.transportProtocol)")
            }
            guard let host = UInt16(exactly: spec.hostPort), let guest = UInt16(exactly: spec.containerPort),
                host > 0, guest > 0
            else {
                throw MicropodError.message("invalidArgument: port \(spec.hostPort):\(spec.containerPort)")
            }
            let address = spec.hostIP.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"
            return PortForward(hostIP: address, hostPort: host, guestPort: guest)
        }
        options.arguments = request.arguments
        options.entrypoint = request.entrypoint.map { [$0] }
        if let cpus = request.cpus { options.cpus = max(1, Int(cpus.rounded(.up))) }
        if let memory = request.memory {
            options.memoryMiB = UInt64(max(128, try DockerEngine.parseBytes(memory) >> 20))
        }
        options.env = request.env
        options.workdir = request.workdir
        // Containers get a network unless asked for none (`--network none`,
        // or the `micropod.network=none` label over the API, which has no
        // networks field) — unlike `sandbox run`, which defaults offline.
        options.network =
            request.networks != ["none"]
            && !request.labels.contains { $0.key == Self.networkLabel && $0.value == "none" }
        for volume in request.volumes {
            guard volume.hasPrefix("/") || volume.hasPrefix(".") || volume.hasPrefix("~") else {
                throw MicropodError.unsupported(
                    "runtime 'sandbox' supports bind mounts (host:/guest[:ro]) only, not named volume '\(volume)'")
            }
            options.mounts.append((volume as NSString).expandingTildeInPath)
        }
        if let user = request.user {
            throw MicropodError.unsupported("runtime 'sandbox' does not support user '\(user)' yet")
        }
        if let name = request.name { options.hostname = name }
        options.dnsResolvers = request.dns
        // API sandboxes carry the guest helper: SandboxService file
        // operations, watches and idling need nothing from the image.
        options.guestTool = SandboxGuestTool.hostDirectory
        if let sandbox = request.sandbox {
            try apply(sandbox, to: &options)
        }
        return options
    }

    /// `SandboxOptions` (and StartSandbox's extras) onto the VM options.
    static func apply(_ sandbox: SandboxRunOptions, to options: inout SandboxVM.Options) throws {
        if sandbox.idle {
            let idle = options.guestTool != nil ? [SandboxGuestTool.guestPath, "idle"] : SandboxEngine.idleCommand
            options.entrypoint = [idle[0]]
            options.arguments = Array(idle.dropFirst())
        }
        if let checkpoint = sandbox.fromCheckpoint { options.base = .checkpoint(checkpoint) }
        if let network = sandbox.network { options.network = network }
        if let mib = sandbox.diskSizeMiB { options.diskBytes = mib << 20 }
        options.exposeHost = sandbox.exposeHost
        options.dnsResolvers += sandbox.dnsResolvers
        options.egress = EgressPolicy(
            allowHosts: sandbox.allowHosts,
            secrets: try sandbox.secrets.map { spec in
                // The API never runs host commands (a request must not start
                // programs on this Mac): callers mint and push values.
                guard spec.command.isEmpty else {
                    throw MicropodError.message(
                        "invalidArgument: secret \(spec.name): the API doesn't run host commands — mint the value "
                            + "on the caller's side (the SDKs do this for command secrets) and refresh it with "
                            + "UpdateSandboxSecret")
                }
                return try SandboxSecret.from(spec)
            })
        if !options.egress.isEmpty && !options.network {
            throw MicropodError.message("invalidArgument: allow_hosts and secrets need a network")
        }
        if !options.dnsResolvers.isEmpty && options.networkMode == nil {
            throw MicropodError.message("invalidArgument: dns_resolvers need a network")
        }
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        let result = try await execDetailed(request)
        guard result.exitCode == 0 else {
            throw MicropodError.cliFailure(
                command: "sandbox exec \(request.containerID)", exitCode: result.exitCode, stderr: result.error)
        }
        return result.output
    }

    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        let prepared = try await store.running(request.containerID)
        let stdout = CollectingWriter()
        let stderr = CollectingWriter()
        let process = try await prepared.container.exec(UUID().uuidString.lowercased()) { cfg in
            cfg = prepared.processTemplate
            cfg.arguments = request.arguments
            cfg.environmentVariables = SandboxVM.mergeEnv(cfg.environmentVariables, request.env)
            if let workdir = request.workdir { cfg.workingDirectory = workdir }
            cfg.stdout = stdout
            cfg.stderr = stderr
        }
        try await process.start()
        let status = try await process.wait()
        try? await process.delete()
        return ContainerExecResult(output: stdout.text, error: stderr.text, exitCode: status.exitCode)
    }

    public func start(_ id: String) async throws { try await store.boot(id) }

    public func stop(_ id: String, timeout: Int) async throws { try await store.stop(id, signal: nil) }

    public func restart(_ id: String) async throws {
        throw MicropodError.unsupported("sandbox containers are ephemeral — run a new one instead of restarting")
    }

    public func kill(_ id: String, signal: String) async throws {
        let sig = try Signal(signal.uppercased().hasPrefix("SIG") ? signal.uppercased() : "SIG" + signal.uppercased())
        try await store.stop(id, signal: sig)
    }

    public func delete(_ id: String, force: Bool) async throws {
        try await store.remove(id, force: force)
        processes.forget(session: id)
    }

    public func stopAll() async throws {
        for session in await store.all() where session.state == .running {
            try? await store.stop(session.id, signal: nil)
        }
    }

    public func deleteAll(force: Bool) async throws {
        for session in await store.all() { try? await store.remove(session.id, force: force) }
    }

    public func prune() async throws -> String {
        var removed = 0
        for session in await store.all() where session.state == .exited {
            try? await store.remove(session.id, force: false)
            removed += 1
        }
        return "removed \(removed) sandboxes"
    }

    public func export(_ id: String, to outputPath: String) async throws {
        throw MicropodError.unsupported("runtime 'sandbox' does not support export")
    }

    public func copy(from: String, to: String) async throws {
        throw MicropodError.unsupported("runtime 'sandbox' does not support copy — use a bind mount")
    }

    // MARK: LogStreaming

    public func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        let store = self.store
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = try await store.require(id)
                    let handle = try FileHandle(forReadingFrom: session.logURL)
                    defer { try? handle.close() }
                    var carry = Data()
                    var backlog = try handle.readToEnd() ?? Data()
                    if let tail {
                        let lines = backlog.split(separator: 0x0A, omittingEmptySubsequences: false)
                        let keep = lines.suffix(tail + (backlog.last == 0x0A ? 1 : 0))
                        backlog = Data(keep.joined(separator: [0x0A]))
                    }
                    carry.append(backlog)
                    while !Task.isCancelled {
                        Self.emitLines(&carry, into: continuation)
                        let more = try handle.readToEnd() ?? Data()
                        if more.isEmpty {
                            if await store.session(id)?.state != .running { break }
                            try await Task.sleep(for: .milliseconds(150))
                        }
                        carry.append(more)
                    }
                    if !carry.isEmpty { continuation.yield(LogLine(text: String(decoding: carry, as: UTF8.self))) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func emitLines(_ carry: inout Data, into continuation: AsyncThrowingStream<LogLine, Error>.Continuation) {
        while let nl = carry.firstIndex(of: 0x0A) {
            continuation.yield(LogLine(text: String(decoding: carry[carry.startIndex..<nl], as: UTF8.self)))
            carry.removeSubrange(carry.startIndex...nl)
        }
    }

    public func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine] {
        let session = try await store.require(id)
        let data = (try? Data(contentsOf: session.logURL)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.last == "" { all.removeLast() }
        return all.suffix(lines).map { LogLine(text: $0) }
    }
}

// MARK: - Sessions

struct Session: Sendable {
    enum State: String, Sendable { case created, running, exited }

    let id: String
    let image: String
    let options: SandboxVM.Options
    let labels: [String: String]
    let runDir: URL
    var created = Date()
    var state = State.created
    var exitCode: Int32?
    var prepared: SandboxVM.Prepared?
    /// Set while a checkpoint takes the root disk: finish() must not delete it.
    var keepDisk = false

    var logURL: URL { runDir.appendingPathComponent("output.log") }

    var container: Micropod_V1_Container {
        Micropod_V1_Container.with { c in
            c.id = id
            c.image = image
            c.state = state == .exited ? "stopped" : state.rawValue
            c.createdAt = ISO8601DateFormatter().string(from: created)
            c.labels = labels
            c.resources = .with {
                $0.cpus = Double(options.cpus)
                $0.memoryBytes = options.memoryMiB << 20
            }
            c.mounts = options.mounts.compactMap { spec in
                let parts = spec.split(separator: ":").map(String.init)
                guard parts.count >= 2 else { return nil }
                return .with {
                    $0.type = "bind"
                    $0.source = parts[0]
                    $0.destination = parts[1]
                    $0.readOnly = parts.count == 3 && parts[2] == "ro"
                }
            }
            if let exitCode { c.exitCode = String(exitCode) }
            c.runtime = "sandbox"
        }
    }

    var inspectJSON: [String: Any] {
        var json: [String: Any] = [
            "id": id, "image": image, "state": state.rawValue, "runtime": "sandbox",
            "created": ISO8601DateFormatter().string(from: created), "labels": labels,
            "cpus": options.cpus, "memoryMiB": options.memoryMiB, "network": options.network,
            "mounts": options.mounts, "arguments": options.arguments, "runDir": runDir.path,
        ]
        if let exitCode { json["exitCode"] = exitCode }
        return json
    }
}

/// Session records + their VMs. Per-process run dirs
/// (`sessions/<pid>/<id>`) so a dead server's leftovers can be swept
/// without touching a live one's.
actor SessionStore {
    let root: URL
    private var sessions: [String: Session] = [:]
    /// Waiters parked in `awaitFinish`, resumed when their session exits.
    private var finishWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    init(root: URL) {
        let base = root
        self.root = base.appendingPathComponent(String(getpid()))
        Self.sweepDeadProcesses(base)
    }

    nonisolated static func sweepDeadProcesses(_ base: URL) {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            guard let pid = Int32(entry), pid != getpid(), Darwin.kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? fm.removeItem(at: base.appendingPathComponent(entry))
        }
    }

    func all() -> [Session] { sessions.values.sorted { $0.created < $1.created } }

    func session(_ id: String) -> Session? { sessions[id] }

    func require(_ id: String) throws -> Session {
        guard let session = sessions[id] else {
            throw MicropodError.message("notFound: sandbox \(id) not found")
        }
        return session
    }

    func add(_ session: Session) throws {
        guard sessions[session.id] == nil else {
            throw MicropodError.message("alreadyExists: sandbox \(session.id) already exists")
        }
        try FileManager.default.createDirectory(at: session.runDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: session.logURL.path, contents: nil)
        sessions[session.id] = session
    }

    func running(_ id: String) throws -> SandboxVM.Prepared {
        let session = try require(id)
        guard session.state == .running, let prepared = session.prepared else {
            throw MicropodError.message("failedPrecondition: sandbox \(id) is not running")
        }
        return prepared
    }

    func boot(_ id: String) async throws {
        var session = try require(id)
        guard session.state == .created else {
            throw MicropodError.message(
                "failedPrecondition: sandbox \(id) already ran — sandboxes are ephemeral, run a new one")
        }
        session.state = .running
        sessions[id] = session
        do {
            let log = try LockedFileWriter(url: session.logURL)
            let prepared = try await SandboxVM.prepareAndCreate(
                session.options, id: id, runDir: session.runDir, stdout: log, stderr: log,
                progress: { SecretSource.stderrLog("sandbox \(id): \($0)") })
            do {
                try await SandboxVM.launch(prepared)
            } catch {
                prepared.forwarding.stop()
                try? await prepared.container.stop()
                throw error
            }
            sessions[id]?.prepared = prepared
            Task { await self.reap(id, prepared) }
        } catch {
            sessions[id]?.state = .exited
            sessions[id]?.exitCode = -1
            throw error
        }
    }

    /// Wait for the workload, then tear the VM down and record the exit.
    private func reap(_ id: String, _ prepared: SandboxVM.Prepared) async {
        let code = (try? await prepared.container.wait().exitCode) ?? -1
        try? await prepared.container.stop()
        prepared.forwarding.stop()
        finish(id, code: code)
    }

    /// Parks until session `id` exits (or is gone) or `timeout` passes, so a
    /// `WaitContainer` hears of the exit at once instead of on its next
    /// poll. Always true: this engine has the signal.
    func awaitFinish(_ id: String, timeout: Duration) async -> Bool {
        guard let session = sessions[id], session.state != .exited else { return true }
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishWaiters[id, default: [:]][token] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resumeWaiter(id, token)
            }
        }
        return true
    }

    private func resumeWaiter(_ id: String, _ token: UUID) {
        finishWaiters[id]?.removeValue(forKey: token)?.resume()
        if finishWaiters[id]?.isEmpty == true { finishWaiters[id] = nil }
    }

    private func resumeAll(_ id: String) {
        for waiter in finishWaiters.removeValue(forKey: id)?.values.map({ $0 }) ?? [] { waiter.resume() }
    }

    private func finish(_ id: String, code: Int32) {
        defer { resumeAll(id) }
        guard var session = sessions[id], session.state == .running else { return }
        session.state = .exited
        if session.exitCode == nil { session.exitCode = code }
        session.prepared = nil
        // The rootfs clone is dead weight once the VM is gone (unless it is
        // becoming a checkpoint); keep logs.
        if !session.keepDisk {
            try? FileManager.default.removeItem(at: session.runDir.appendingPathComponent("rootfs.ext4"))
        }
        sessions[id] = session
    }

    /// Stop a running sandbox cleanly (its root disk unmounted in-guest) and
    /// keep that disk as checkpoint `name`.
    func checkpoint(_ id: String, name: String) async throws {
        let session = try require(id)
        guard session.state == .running, let prepared = session.prepared else {
            throw MicropodError.message("failedPrecondition: sandbox \(id) is not running")
        }
        sessions[id]?.keepDisk = true
        sessions[id]?.exitCode = 0
        defer { sessions[id]?.keepDisk = false }
        try await prepared.container.stop()
        prepared.forwarding.stop()
        finish(id, code: 0)
        try SandboxVM.saveCheckpoint(
            name: name, disk: prepared.rootfsPath, image: prepared.imageRef, diskBytes: prepared.diskBytes)
    }

    func stop(_ id: String, signal: Signal?) async throws {
        let session = try require(id)
        guard session.state == .running, let prepared = session.prepared else { return }
        if let signal {
            try await prepared.container.kill(signal)
            return
        }
        sessions[id]?.exitCode = 137
        try await prepared.container.stop()
        prepared.forwarding.stop()
        finish(id, code: 137)
    }

    func remove(_ id: String, force: Bool) async throws {
        let session = try require(id)
        if session.state == .running {
            guard force else {
                throw MicropodError.message("failedPrecondition: sandbox \(id) is running — stop it or force delete")
            }
            try? await stop(id, signal: nil)
        }
        sessions[id] = nil
        resumeAll(id)
        try? FileManager.default.removeItem(at: session.runDir)
    }
}

/// Appends guest stdout+stderr to one log file.
final class LockedFileWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    func close() throws {}
}

final class CollectingWriter: Writer, @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data.append(data)
    }

    func close() throws {}
}
