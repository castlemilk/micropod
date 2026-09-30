import Containerization
import Foundation
import MicropodCore

/// The programmable-sandbox surface behind `SandboxService`: processes with
/// streamed output and stdin, file operations, in-guest watches and
/// checkpoints of running sandboxes. Everything runs inside the sandbox's
/// container, so it sees the container's mounts, /tmp and working directory.
extension SandboxEngine {
    /// The main process of a sandbox started without a command when the
    /// guest helper is missing (`micropod-guest idle` otherwise): idles until
    /// the sandbox is stopped, exiting 0 on SIGTERM.
    public static let idleCommand = [
        "/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 86400 & wait $!; done",
    ]

    // MARK: Processes

    /// Start `command` in sandbox `id`; returns its process id and guest pid.
    public func startProcess(
        _ id: String, command: [String], cwd: String? = nil, env: [String] = [], stdin: Bool = false
    ) async throws -> (processID: String, pid: Int32) {
        guard !command.isEmpty else { throw MicropodError.message("invalidArgument: empty command") }
        let prepared = try await store.running(id)
        let processID = "p-" + UUID().uuidString.lowercased().prefix(12)
        let output = ProcessOutput()
        let input = stdin ? PushedInput() : nil
        let process = try await prepared.container.exec(processID) { cfg in
            cfg = prepared.processTemplate
            cfg.arguments = command
            cfg.environmentVariables = SandboxVM.mergeEnv(cfg.environmentVariables, env)
            if let cwd, !cwd.isEmpty { cfg.workingDirectory = cwd }
            cfg.stdout = output.writer(stderr: false)
            cfg.stderr = output.writer(stderr: true)
            cfg.stdin = input
        }
        do {
            try await process.start()
        } catch {
            try? await process.delete()
            throw MicropodError.message("failedPrecondition: cannot start \(command[0]): \(error)")
        }
        processes.add(
            SandboxProcess(id: processID, sessionID: id, process: process, stdin: input, output: output))
        Task {
            // wait() returns once stdout/stderr are drained, so the exit is
            // always the last event.
            let code = (try? await process.wait().exitCode) ?? -1
            output.append(.exit(code))
            try? await process.delete()
        }
        return (processID, process.pid)
    }

    /// Output so far, then live output, then the exit.
    public func streamProcess(_ id: String, processID: String) throws
        -> AsyncThrowingStream<ProcessOutput.Event, any Error>
    {
        try processes.process(id, processID).output.subscribe()
    }

    public func writeStdin(_ id: String, processID: String, data: Data, close: Bool) throws {
        let process = try processes.process(id, processID)
        guard let stdin = process.stdin else {
            throw MicropodError.message(
                "failedPrecondition: process \(processID) was started without stdin (StartProcessRequest.stdin)")
        }
        stdin.write(data)
        if close { stdin.close() }
    }

    public func signalProcess(_ id: String, processID: String, signal: String) async throws {
        let process = try processes.process(id, processID)
        let parsed: Signal
        do {
            parsed = try Signal(signal.isEmpty ? "SIGTERM" : signal)
        } catch {
            throw MicropodError.message("invalidArgument: unknown signal '\(signal)'")
        }
        guard process.output.finishedAt == nil else { return }
        try await process.process.kill(parsed)
    }

    // MARK: Files

    /// Largest file ReadFile returns / WriteFile accepts.
    public static let maxFileBytes = 32 << 20

    // Each operation runs `micropod-guest` when the sandbox has it (always,
    // for a release daemon) and the image's shell tools otherwise.

    public func readFile(_ id: String, path: String) async throws -> Data {
        try await fileOperation(
            id, path, guest: ["read", path, "--max", String(Self.maxFileBytes)],
            shell: [
                "/bin/sh", "-c",
                """
                [ -d "$1" ] && { echo "$1: Is a directory" >&2; exit 21; }
                size=$(stat -L -c %s -- "$1") || exit 2
                [ "$size" -gt \(Self.maxFileBytes) ] && { echo "$1: $size bytes, over the 32 MiB limit" >&2; exit 27; }
                exec cat -- "$1"
                """,
                "sh", path,
            ])
    }

    public func writeFile(
        _ id: String, path: String, data: Data, append: Bool, mode: UInt32?, createParents: Bool
    ) async throws {
        guard data.count <= Self.maxFileBytes else {
            throw MicropodError.message("resourceExhausted: \(data.count) bytes is over the 32 MiB limit")
        }
        var guest = ["write", path]
        if append { guest.append("--append") }
        if let mode { guest += ["--mode", String(mode, radix: 8)] }
        if createParents { guest.append("--parents") }
        var script = createParents ? #"mkdir -p -- "$(dirname -- "$1")" && "# : ""
        script += append ? #"cat >> "$1""# : #"cat > "$1""#
        if let mode { script += " && chmod \(String(mode, radix: 8)) -- \"$1\"" }
        _ = try await fileOperation(id, path, guest: guest, shell: ["/bin/sh", "-c", script, "sh", path], stdin: data)
    }

    public func stat(_ id: String, path: String) async throws -> SandboxFileStat {
        if try await usesGuestTool(id) {
            let out = try await fileOperation(id, path, guest: ["stat", path], shell: [])
            guard let stat = SandboxFileStat.parseJSONLines(out).first else {
                throw MicropodError.message("internalError: unreadable stat output for \(path)")
            }
            return stat
        }
        let out = try await fileOperation(
            id, path, guest: [], shell: ["stat", "-c", SandboxFileStat.format, "--", path])
        guard let stat = SandboxFileStat.parse(String(decoding: out, as: UTF8.self)).first else {
            throw MicropodError.message("internalError: unreadable stat output for \(path)")
        }
        return stat
    }

    public func listDir(_ id: String, path: String) async throws -> [SandboxFileStat] {
        if try await usesGuestTool(id) {
            return SandboxFileStat.parseJSONLines(try await fileOperation(id, path, guest: ["list", path], shell: []))
        }
        let out = try await fileOperation(
            id, path, guest: [],
            shell: [
                "/bin/sh", "-c",
                #"[ -d "$1" ] || { echo "$1: Not a directory" >&2; exit 20; }; "#
                    + #"cd -- "$1" && find . -mindepth 1 -maxdepth 1 -exec stat -c "$2" {} +"#,
                "sh", path, SandboxFileStat.format,
            ])
        return SandboxFileStat.parse(String(decoding: out, as: UTF8.self)).map {
            var entry = $0
            entry.path = String(entry.path.dropFirst(entry.path.hasPrefix("./") ? 2 : 0))
            return entry
        }
    }

    public func makeDir(_ id: String, path: String, recursive: Bool) async throws {
        _ = try await fileOperation(
            id, path, guest: ["mkdir", path] + (recursive ? ["--parents"] : []),
            shell: recursive ? ["mkdir", "-p", "--", path] : ["mkdir", "--", path])
    }

    public func remove(_ id: String, path: String, recursive: Bool) async throws {
        _ = try await fileOperation(
            id, path, guest: ["rm", path] + (recursive ? ["--recursive"] : []),
            shell: recursive
                ? [
                    "/bin/sh", "-c",
                    #"[ -e "$1" ] || [ -L "$1" ] || { echo "$1: No such file or directory" >&2; exit 2; }; rm -rf -- "$1""#,
                    "sh", path,
                ]
                : [
                    "/bin/sh", "-c",
                    #"if [ -d "$1" ] && [ ! -L "$1" ]; then rmdir -- "$1"; else rm -- "$1"; fi"#,
                    "sh", path,
                ])
    }

    public func rename(_ id: String, from: String, to: String) async throws {
        _ = try await fileOperation(id, from, guest: ["mv", from, to], shell: ["mv", "--", from, to])
    }

    public func copy(_ id: String, from: String, to: String, recursive: Bool) async throws {
        _ = try await fileOperation(
            id, from, guest: ["cp", from, to] + (recursive ? ["--recursive"] : []),
            shell: recursive ? ["cp", "-R", "--", from, to] : ["cp", "--", from, to])
    }

    public func chmod(_ id: String, path: String, mode: UInt32) async throws {
        let octal = String(mode, radix: 8)
        _ = try await fileOperation(id, path, guest: ["chmod", octal, path], shell: ["chmod", octal, "--", path])
    }

    func usesGuestTool(_ id: String) async throws -> Bool {
        try await store.running(id).hasGuestTool
    }

    /// Runs the guest helper with `guest` (or `shell` without it); stdout on
    /// success, a mapped error otherwise.
    private func fileOperation(
        _ id: String, _ path: String, guest: [String], shell: [String], stdin: Data? = nil
    ) async throws -> Data {
        let helper = try await usesGuestTool(id)
        let (out, err, code) = try await capture(
            id, helper ? [SandboxGuestTool.guestPath] + guest : shell, stdin: stdin)
        guard code == 0 else { throw helper ? Self.guestError(path, err) : Self.fileError(path, err) }
        return out
    }

    /// Run `argv` in the sandbox to completion, collecting its output.
    func capture(_ id: String, _ argv: [String], stdin: Data? = nil) async throws -> (Data, String, Int32) {
        let prepared = try await store.running(id)
        let out = ByteCollector(limit: Self.maxFileBytes + 1)
        let err = ByteCollector(limit: 64 << 10)
        let input = stdin.map { data in
            let pushed = PushedInput()
            pushed.write(data)
            pushed.close()
            return pushed
        }
        let process = try await prepared.container.exec("f-" + UUID().uuidString.lowercased().prefix(12)) { cfg in
            cfg = prepared.processTemplate
            cfg.arguments = argv
            cfg.stdout = out
            cfg.stderr = err
            cfg.stdin = input
        }
        do {
            try await process.start()
        } catch {
            try? await process.delete()
            throw MicropodError.message("failedPrecondition: the image can't run \(argv[0]): \(error)")
        }
        let status = try await process.wait()
        try? await process.delete()
        return (out.data, String(decoding: err.data, as: UTF8.self), status.exitCode)
    }

    /// The guest helper's "micropod-guest: <ERRNO>: <message>" → an API error.
    static func guestError(_ path: String, _ stderr: String) -> MicropodError {
        let line = stderr.split(separator: "\n").last(where: { $0.hasPrefix("micropod-guest: ") }).map(String.init)
        guard let line else {
            return .message("internalError: \(path): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let rest = line.dropFirst("micropod-guest: ".count)
        let errno = rest.prefix { $0 != ":" }
        let message = rest.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
        let code: String
        switch errno {
        case "ENOENT": code = "notFound"
        case "EACCES", "EPERM", "EROFS": code = "permissionDenied"
        case "EEXIST": code = "alreadyExists"
        case "EFBIG", "ENOSPC", "EDQUOT", "EMFILE": code = "resourceExhausted"
        case "ENOTEMPTY", "EISDIR", "ENOTDIR", "EBUSY", "ETXTBSY", "EXDEV", "ELOOP": code = "failedPrecondition"
        case "EINVAL", "ENAMETOOLONG": code = "invalidArgument"
        default: code = "internalError"
        }
        return .message("\(code): \(message.isEmpty ? path : message)")
    }

    /// A tool's stderr → the error code a caller can act on.
    static func fileError(_ path: String, _ stderr: String) -> MicropodError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let code: String
        if lower.contains("not found") && !lower.contains("no such file") {
            // `sh: stat: not found` — the image lacks the tool.
            return .message("failedPrecondition: the image lacks a tool file operations need (\(text))")
        } else if lower.contains("no such file") {
            code = "notFound"
        } else if lower.contains("permission denied") || lower.contains("operation not permitted")
            || lower.contains("read-only file system")
        {
            code = "permissionDenied"
        } else if lower.contains("file exists") {
            code = "alreadyExists"
        } else if lower.contains("over the 32 mib limit") {
            code = "resourceExhausted"
        } else if lower.contains("not empty") || lower.contains("is a directory")
            || lower.contains("not a directory")
        {
            code = "failedPrecondition"
        } else {
            code = "internalError"
        }
        return .message("\(code): \(text.isEmpty ? path : text)")
    }

    // MARK: Watch

    /// Changes under `path`, observed in the guest: the guest helper's
    /// inotify watch, or — without it — the image's inotifywait, else a
    /// 500 ms stat poll. The first change is `ready`.
    public func watch(_ id: String, path: String, recursive: Bool) async throws
        -> AsyncThrowingStream<WatchChange, any Error>
    {
        let helper = try await usesGuestTool(id)
        let command =
            helper
            ? [SandboxGuestTool.guestPath, "watch", path] + (recursive ? ["--recursive"] : [])
            : ["/bin/sh", "-c", WatchParser.script, "sh", path, recursive ? "1" : "0"]
        let (processID, _) = try await startProcess(id, command: command)
        let entry = try processes.process(id, processID)
        let events = entry.output.subscribe()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = WatchParser(jsonLines: helper)
                do {
                    for try await event in events {
                        switch event {
                        case .stdout(let data):
                            for change in parser.feed(stdout: data) { continuation.yield(change) }
                        case .stderr(let data):
                            for change in parser.feed(stderr: data) { continuation.yield(change) }
                        case .exit:
                            throw helper ? Self.guestError(path, parser.errors) : Self.fileError(path, parser.errors)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { try? await entry.process.kill(.kill) }
            }
        }
    }

    // MARK: Secrets

    /// Replace a running sandbox's secret value (a pushed refresh).
    public func updateSecret(_ id: String, name: String, value: String, expiresAt: Date?) async throws {
        let prepared = try await store.running(id)
        guard let secret = prepared.egress?.policy.secrets.first(where: { $0.name == name }) else {
            throw MicropodError.message("notFound: sandbox \(id) has no secret \(name)")
        }
        do {
            try secret.source.update(value, expiresAt: expiresAt)
        } catch let error as MicropodError {
            throw error
        } catch {
            throw MicropodError.message("invalidArgument: secret \(name): \(error)")
        }
    }

    // MARK: Checkpoints

    /// Save running sandbox `id`'s disk as checkpoint `name`, stopping it.
    public func checkpoint(_ id: String, name: String) async throws {
        try await store.checkpoint(id, name: name)
    }
}

/// `stat` output for one path.
public struct SandboxFileStat: Sendable, Equatable {
    public var path: String
    public var size: UInt64
    public var mode: UInt32
    public var mtime: Int64

    /// "file", "dir", "symlink" or "other", from the mode's type bits.
    public var type: String {
        switch mode & 0o170000 {
        case 0o100000: return "file"
        case 0o040000: return "dir"
        case 0o120000: return "symlink"
        default: return "other"
        }
    }

    /// size, raw mode (hex), mtime, name — the same in coreutils and busybox.
    static let format = "%s %f %Y %n"

    /// The guest helper's `{"name","type","size","mode","mtime"}` lines.
    static func parseJSONLines(_ data: Data) -> [SandboxFileStat] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let size = (object["size"] as? NSNumber)?.uint64Value,
                let mode = (object["mode"] as? NSNumber)?.uint32Value,
                let mtime = (object["mtime"] as? NSNumber)?.int64Value
            else { return nil }
            return SandboxFileStat(path: object["name"] as? String ?? "", size: size, mode: mode, mtime: mtime)
        }
    }

    static func parse(_ text: String) -> [SandboxFileStat] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let size = UInt64(parts[0]), let mode = UInt32(parts[1], radix: 16),
                let mtime = Int64(parts[2])
            else { return nil }
            return SandboxFileStat(path: String(parts[3]), size: size, mode: mode, mtime: mtime)
        }
    }
}

/// One change seen by a watch.
public struct WatchChange: Sendable, Equatable {
    /// "ready", "create", "modify", "delete" or "rename".
    public var event: String
    public var path: String
}

/// Turns the watcher script's output into changes. inotify mode prints
/// `EVENTS path` lines (readiness on stderr); poll mode prints `@poll`,
/// then whole snapshots each ended by `@snap`, which are diffed here.
struct WatchParser {
    /// Runs in the guest: `$1` path, `$2` 1 for recursive.
    static let script = """
        [ -e "$1" ] || { echo "$1: No such file or directory" >&2; exit 2; }
        if command -v inotifywait >/dev/null 2>&1; then
          if [ "$2" = 1 ]; then r=-r; else r=; fi
          exec inotifywait -m $r -e create,modify,attrib,delete,move,delete_self,move_self --format '%e %w%f' -- "$1"
        fi
        echo @poll
        prev=
        while :; do
          if [ "$2" = 1 ]; then cur=$(find "$1" -exec stat -c '%Y %s %i %f %n' {} + 2>/dev/null)
          else cur=$(find "$1" -maxdepth 1 -exec stat -c '%Y %s %i %f %n' {} + 2>/dev/null); fi
          [ "$cur" != "$prev" ] && { printf '%s\\n@snap\\n' "$cur"; prev=$cur; }
          sleep 0.5
        done
        """

    /// The guest helper's JSON-lines events, not the script's text.
    var jsonLines = false
    private var stdoutTail = ""
    private var stderrTail = ""
    private var polling = false
    private var snapshot: [String] = []
    private var previous: [String: (key: String, dir: Bool)]?
    private var ready = false
    /// stderr other than inotifywait's chatter — the reason if it exits.
    private(set) var errors = ""

    init(jsonLines: Bool = false) { self.jsonLines = jsonLines }

    mutating func feed(stdout data: Data) -> [WatchChange] {
        var changes: [WatchChange] = []
        for line in Self.lines(&stdoutTail, data) {
            if jsonLines {
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    let event = object["event"] as? String
                {
                    changes.append(WatchChange(event: event, path: object["path"] as? String ?? ""))
                }
            } else if line == "@poll" {
                polling = true
            } else if polling {
                if line == "@snap" {
                    changes += diff()
                } else {
                    snapshot.append(line)
                }
            } else if let space = line.firstIndex(of: " ") {
                let path = String(line[line.index(after: space)...])
                changes += Self.inotify(line[..<space]).map { WatchChange(event: $0, path: path) }
            }
        }
        return changes
    }

    mutating func feed(stderr data: Data) -> [WatchChange] {
        var changes: [WatchChange] = []
        for line in Self.lines(&stderrTail, data) {
            if jsonLines {
                errors += line + "\n"
            } else if line.hasPrefix("Watches established") {
                if !ready {
                    ready = true
                    changes.append(WatchChange(event: "ready", path: ""))
                }
            } else if !line.hasPrefix("Setting up watches") {
                errors += line + "\n"
            }
        }
        return changes
    }

    /// inotifywait's event list → at most one change.
    static func inotify(_ events: Substring) -> [String] {
        let names = Set(events.split(separator: ","))
        if names.contains("CREATE") { return ["create"] }
        if names.contains("DELETE") || names.contains("DELETE_SELF") { return ["delete"] }
        if names.contains("MOVED_FROM") || names.contains("MOVED_TO") || names.contains("MOVE_SELF") {
            return ["rename"]
        }
        if names.contains("ISDIR") { return [] }  // a directory's own attributes
        if names.contains("MODIFY") || names.contains("ATTRIB") { return ["modify"] }
        return []
    }

    /// One complete snapshot against the last: created, deleted and modified
    /// paths (a directory's own mtime change is its children's news).
    private mutating func diff() -> [WatchChange] {
        var current: [String: (key: String, dir: Bool)] = [:]
        for line in snapshot {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let mode = UInt32(parts[3], radix: 16) else { continue }
            current[String(parts[4])] = ("\(parts[0]) \(parts[1]) \(parts[2])", mode & 0o170000 == 0o040000)
        }
        snapshot = []
        defer { previous = current }
        guard let previous else {
            ready = true
            return [WatchChange(event: "ready", path: "")]
        }
        var changes: [WatchChange] = []
        for (path, entry) in current.sorted(by: { $0.key < $1.key }) {
            if let before = previous[path] {
                if before.key != entry.key && !entry.dir { changes.append(WatchChange(event: "modify", path: path)) }
            } else {
                changes.append(WatchChange(event: "create", path: path))
            }
        }
        for path in previous.keys.sorted() where current[path] == nil {
            changes.append(WatchChange(event: "delete", path: path))
        }
        return changes
    }

    /// Complete lines from `tail` + `data`; the partial last line stays.
    private static func lines(_ tail: inout String, _ data: Data) -> [String] {
        tail += String(decoding: data, as: UTF8.self)
        var lines = tail.components(separatedBy: "\n")
        tail = lines.removeLast()
        return lines
    }
}

/// Collects output up to `limit` bytes (the rest is dropped).
final class ByteCollector: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()

    init(limit: Int) { self.limit = limit }

    var data: Data { lock.withLock { buffer } }

    func write(_ data: Data) throws {
        lock.withLock {
            let room = limit - buffer.count
            if room > 0 { buffer.append(data.prefix(room)) }
        }
    }

    func close() throws {}
}
