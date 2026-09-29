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
        guard request.publishedPorts.isEmpty else {
            throw MicropodError.unsupported("runtime 'sandbox' does not publish ports — use apple or docker")
        }
        var options = SandboxVM.Options(base: .image(request.image))
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
        return options
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
        let container = try await store.running(request.containerID)
        let stdout = CollectingWriter()
        let stderr = CollectingWriter()
        let process = try await container.exec(UUID().uuidString.lowercased()) { cfg in
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

    public func delete(_ id: String, force: Bool) async throws { try await store.remove(id, force: force) }

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

    func running(_ id: String) throws -> LinuxContainer {
        let session = try require(id)
        guard session.state == .running, let prepared = session.prepared else {
            throw MicropodError.message("failedPrecondition: sandbox \(id) is not running")
        }
        return prepared.container
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
            let prepared = try await SandboxVM.prepare(
                session.options, id: id, runDir: session.runDir, stdout: log, stderr: log, progress: { _ in })
            try await SandboxVM.boot(prepared, timeout: session.options.bootTimeout)
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
        finish(id, code: code)
    }

    private func finish(_ id: String, code: Int32) {
        guard var session = sessions[id], session.state == .running else { return }
        session.state = .exited
        if session.exitCode == nil { session.exitCode = code }
        session.prepared = nil
        // The rootfs clone is dead weight once the VM is gone; keep logs.
        try? FileManager.default.removeItem(at: session.runDir.appendingPathComponent("rootfs.ext4"))
        sessions[id] = session
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
