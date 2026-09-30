import Foundation
import MicropodCore

/// Where a sandbox secret's real value comes from: a fixed value, or a host
/// command (argv, never a shell) that mints it — `gcloud auth
/// print-access-token`, a GitHub App installation-token script.
///
/// A command's stdout is the value, raw or as
/// `{"version":1,"value":"…","expires_at":"<RFC 3339>"}` (AWS
/// `credential_process`'s shape). It is minted on first use and again a
/// minute before `expires_at` — or every `ttl` when there is none — while
/// the still-valid value keeps serving, so a refresh never stalls a
/// request. One mint runs at a time; values live in memory only and never
/// reach a log. A failed refresh keeps a still-valid value; with none, the
/// caller gets an error and fails closed instead of sending the placeholder
/// upstream.
public final class SecretSource: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case fixed(String)
        case command(argv: [String], directory: URL?, ttl: Duration)
    }

    public let kind: Kind
    /// Reports refresh failures (the command's stderr, never the value).
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var cached: Minted?
    private var minting: Task<Minted, any Error>?

    struct Minted {
        var value: String
        /// When to start minting a replacement.
        var refreshAt: ContinuousClock.Instant
        /// When the value stops working; nil when the command didn't say.
        var expiresAt: ContinuousClock.Instant?
    }

    static let refreshLead: Duration = .seconds(60)
    static let defaultTTL: Duration = .seconds(300)
    static let commandTimeout: Duration = .seconds(30)

    public init(_ kind: Kind, log: @escaping @Sendable (String) -> Void = SecretSource.stderrLog) {
        self.kind = kind
        self.log = log
    }

    public static let stderrLog: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data("micropod: \(message)\n".utf8))
    }

    /// The current value, minting or refreshing it as needed.
    public func value(clock: ContinuousClock = ContinuousClock()) async throws -> String {
        guard case .command(let argv, let directory, let ttl) = kind else {
            if case .fixed(let value) = kind { return value }
            return ""
        }
        let now = clock.now
        let plan: Plan = lock.withLock {
            if let cached, now < cached.refreshAt { return .serve(cached.value) }
            let valid = cached.flatMap { c in c.expiresAt.map { now < $0 } ?? true ? c.value : nil }
            if let retryAfter, now < retryAfter {
                // A mint just failed: don't re-run the command per request.
                if let valid { return .serve(valid) }
                return .fail(lastError ?? MicropodError.message("secret unavailable"))
            }
            // Created and stored under the lock, so the mint's own
            // `minting = nil` can't land before this assignment.
            let task = minting ?? Task { try await self.mint(argv, directory, ttl, clock) }
            minting = task
            if let valid { return .serve(valid) }  // refresh in the background
            return .wait(task)
        }
        switch plan {
        case .serve(let value): return value
        case .fail(let error): throw error
        case .wait(let task): return try await task.value.value
        }
    }

    private enum Plan {
        case serve(String)
        case wait(Task<Minted, any Error>)
        case fail(any Error)
    }

    /// After a failed mint, the next attempt waits this long.
    static let retryBackoff: Duration = .seconds(10)
    private var retryAfter: ContinuousClock.Instant?
    private var lastError: (any Error)?

    private func mint(
        _ argv: [String], _ directory: URL?, _ ttl: Duration, _ clock: ContinuousClock
    ) async throws -> Minted {
        do {
            let output = try await Self.run(argv, directory: directory, timeout: Self.commandTimeout)
            let (value, expires) = try Self.parse(output)
            let now = clock.now
            let expiresAt = expires.map { now + .milliseconds(Int64($0.timeIntervalSinceNow * 1000)) }
            let refreshAt = expiresAt.map { $0 - Self.refreshLead } ?? now + ttl
            let minted = Minted(value: value, refreshAt: max(refreshAt, now + .seconds(1)), expiresAt: expiresAt)
            lock.withLock {
                cached = minted
                minting = nil
                retryAfter = nil
                lastError = nil
            }
            return minted
        } catch {
            let failure = MicropodError.message("secret command \(argv.first ?? "") failed: \(error)")
            lock.withLock {
                minting = nil
                retryAfter = clock.now + Self.retryBackoff
                lastError = failure
            }
            log("\(failure)")
            throw failure
        }
    }

    /// Command output → value (+ expiry). Values holding CR, LF or NUL are
    /// refused: they would split the request head they are spliced into.
    static func parse(_ output: Data) throws -> (String, Date?) {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var value = text
        var expires: Date?
        if text.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw MicropodError.message("secret command printed malformed JSON")
            }
            if let version = object["version"], (version as? Int) != 1 {
                throw MicropodError.message("secret command printed unsupported version \(version)")
            }
            guard let v = object["value"] as? String else {
                throw MicropodError.message("secret command JSON has no string \"value\"")
            }
            value = v
            if let stamp = object["expires_at"] as? String {
                guard let date = Self.parseDate(stamp) else {
                    throw MicropodError.message("secret command JSON has an unreadable expires_at")
                }
                expires = date
            }
        }
        try validate(value)
        return (value, expires)
    }

    static func validate(_ value: String) throws {
        guard !value.isEmpty else { throw MicropodError.message("secret value is empty") }
        guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw MicropodError.message("secret value contains a line break or NUL")
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Runs `argv` (PATH-resolved, no shell) in `directory`; stdout on
    /// success, stderr in the error otherwise.
    static func run(_ argv: [String], directory: URL?, timeout: Duration) async throws -> Data {
        guard let program = argv.first else { throw MicropodError.message("secret command is empty") }
        let process = Process()
        process.executableURL = try executable(program, relativeTo: directory)
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let collected = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { collected.append(out: $0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { collected.append(err: $0.availableData) }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
            let pid = process.processIdentifier
            Task {
                try? await Task.sleep(for: timeout)
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collected.append(out: stdout.fileHandleForReading.readDataToEndOfFile())
        collected.append(err: stderr.fileHandleForReading.readDataToEndOfFile())
        let (out, err) = collected.snapshot
        guard status == 0 else {
            let detail = String(decoding: err.suffix(512), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MicropodError.message("exit \(status)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return out
    }

    /// `path` against `directory` (a directory whatever its spelling —
    /// `URL(fileURLWithPath:relativeTo:)` drops a base without a trailing
    /// slash).
    static func resolve(_ path: String, in directory: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        let base = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent(path).standardizedFileURL
    }

    private static func executable(_ program: String, relativeTo directory: URL?) throws -> URL {
        if program.contains("/") { return resolve(program, in: directory) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw MicropodError.message("secret command \(program) not found on PATH")
    }
}

/// Collects a child's stdout/stderr from two readability handlers.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(out data: Data) { lock.withLock { out.append(data) } }
    func append(err data: Data) { lock.withLock { err.append(data) } }
    var snapshot: (Data, Data) { lock.withLock { (out, err) } }
}
