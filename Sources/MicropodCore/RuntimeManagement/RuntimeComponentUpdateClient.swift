import Foundation

/// The owner's side of a runtime component update: one operation ID per
/// request, kept on disk until the update is terminal, so a lost reply, a
/// closed terminal or a helper that restarts mid-request resumes the same
/// update instead of starting another. The root helper refuses a replayed ID
/// and answers a repeated one with its status.
public struct RuntimeComponentUpdateClient: Sendable {
    public struct Pending: Codable, Equatable, Sendable {
        public let operation: UUID
        public let rollback: Bool
        public let requestedAt: Date
    }

    /// The helper predates component updates: it needs the one-time
    /// administrator bootstrap (docs/runtime-component-update.md).
    public struct LegacyHelper: LocalizedError, Sendable {
        public let version: String?
        public var errorDescription: String? {
            "The installed runtime helper cannot update itself. Run `micropod runtime update --bootstrap` "
                + "once; it needs one administrator command"
        }
    }

    public var call: @Sendable (IsolatedRuntimeRequest) async throws -> IsolatedRuntimeStatus
    public var ledger: URL
    public var sleep: @Sendable (Duration) async throws -> Void
    public var log: @Sendable (String) -> Void
    /// How long the helper may be unreachable while launchd restarts it.
    public var relaunchGrace: Duration

    public init(
        call: @escaping @Sendable (IsolatedRuntimeRequest) async throws -> IsolatedRuntimeStatus = {
            try await IsolatedRuntimeClient().call($0)
        },
        ledger: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".micropod/runtime-component-update.json"),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: @escaping @Sendable (String) -> Void = { _ in },
        relaunchGrace: Duration = .seconds(120)
    ) {
        self.call = call
        self.ledger = ledger
        self.sleep = sleep
        self.log = log
        self.relaunchGrace = relaunchGrace
    }

    public func pending() -> Pending? {
        guard let data = try? RuntimeDurableFile.read(ledger, maximumBytes: 4096) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    /// Sends the update (or rollback) and returns its operation. A request
    /// still pending from an earlier run is resumed, not repeated.
    public func request(rollback: Bool) async throws -> UUID {
        let status = try await call(.init(action: .status))
        guard status.componentProtocol != nil else { throw LegacyHelper(version: nil) }
        if let existing = pending(), existing.rollback == rollback {
            if let summary = status.componentUpdate, summary.operation == existing.operation, summary.isTerminal {
                try? RuntimeDurableFile.remove(ledger)
            } else {
                return try await send(existing)
            }
        }
        let pending = Pending(operation: UUID(), rollback: rollback, requestedAt: Date())
        try RuntimeDurableFile.write(pending, to: ledger)
        return try await send(pending)
    }

    private func send(_ pending: Pending) async throws -> UUID {
        let request = IsolatedRuntimeRequest(
            operation: pending.operation, action: pending.rollback ? .rollback : .update)
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 { try await sleep(.seconds(2)) }
            let reply: IsolatedRuntimeStatus
            do { reply = try await call(request) } catch {
                // No reply: the request may or may not have been recorded.
                // The same ID is sent again; it cannot start a second update.
                lastError = error
                continue
            }
            if reply.componentUpdate?.operation == pending.operation { return pending.operation }
            if let summary = try? await call(.init(action: .status)).componentUpdate,
                summary.operation == pending.operation
            {
                return pending.operation
            }
            try? RuntimeDurableFile.remove(ledger)
            throw MicropodError.message(reply.error ?? reply.message)
        }
        throw lastError ?? MicropodError.message("The runtime helper did not answer")
    }

    /// Follows `operation` to a terminal outcome, through the helper's own
    /// relaunch and the coordinated restart that follows it.
    public func follow(_ operation: UUID, timeout: Duration = .seconds(1800)) async throws
        -> RuntimeComponentUpdateSummary
    {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var unreachableSince: ContinuousClock.Instant?
        var last = ""
        while clock.now < deadline {
            do {
                let status = try await call(.init(action: .status))
                unreachableSince = nil
                if let summary = status.componentUpdate, summary.operation == operation {
                    var line = summary.phase
                    if summary.phase == "restarting", status.operation == summary.runtimeOperation {
                        line += " (runtime: \(status.phase))"
                    }
                    if line != last {
                        log("  \(line)…")
                        last = line
                    }
                    if summary.isTerminal {
                        try? RuntimeDurableFile.remove(ledger)
                        return summary
                    }
                }
            } catch {
                let since = unreachableSince ?? clock.now
                unreachableSince = since
                if clock.now - since > relaunchGrace {
                    throw MicropodError.message(
                        "The runtime helper has not answered for \(relaunchGrace.components.seconds) s: "
                            + error.localizedDescription)
                }
            }
            try await sleep(.seconds(1))
        }
        throw MicropodError.message(
            "The runtime component update is still running; `micropod runtime update` follows it")
    }
}
