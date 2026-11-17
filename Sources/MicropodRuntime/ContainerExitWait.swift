import Foundation

/// The `WaitContainer` loop: waits until a container is terminal or the
/// timeout elapses, without a blocking runtime wait in the request path.
///
/// - **Tracked containers** (the native backend started them, so the
///   ``ExitCodeRegistry`` runs a waiter) park on the registry and wake the
///   moment the exit is recorded. The runtime state is re-read every
///   `trackedPoll` (1 s) as a safety net.
/// - **Engine-signalled containers** (the sandbox engine owns them) park on
///   `park`, which returns as soon as the engine sees the exit.
/// - **Untracked containers** (CLI backend, CLI-created, started before
///   this process, a wait that arrived before `track`, or an entry whose
///   waiter aged out) have no signal to wait on: the runtime state is polled
///   every `untrackedPoll` (150 ms, the cadence before the registry could
///   wake waits), so their exit latency is unchanged.
///
/// A registry code is authoritative (`known: true`) even if the state has
/// not flipped to `stopped` yet. `running`/`stopping`/`starting` are non-terminal; so
/// is `created` (never started — it may still be). Anything else
/// (`stopped`, or `unknown` after the container vanished mid-wait) is
/// `exited: true`, with `known: false` when no registry code can arrive. A
/// stopped tracked container with a pending waiter remains non-terminal until
/// the waiter delivers its result: the runtime snapshot can flip first. Errors
/// thrown by `state` (the runtime stopped answering) propagate.
///
/// `state(id, exitKnown)` reads the runtime state; `exitKnown` says whether
/// this iteration already holds a registry exit code, so the reader can
/// skip checks that only matter for an unexplained `unknown`.
public enum ContainerExitWait {
    public struct Outcome: Sendable, Equatable {
        public let exited: Bool
        /// Whether `exitCode` is the process's real exit code.
        public let known: Bool
        public let exitCode: Int32?
        public let state: String

        public init(exited: Bool, known: Bool, exitCode: Int32?, state: String) {
            self.exited = exited
            self.known = known
            self.exitCode = exitCode
            self.state = state
        }
    }

    /// How often the runtime state is re-read while parked on the registry.
    public static let defaultTrackedPoll: Duration = .seconds(1)
    /// How often the runtime state is read when no registry signal exists.
    public static let defaultUntrackedPoll: Duration = .milliseconds(150)

    public static func wait(
        id: String,
        timeout: Duration,
        exitCodes: ExitCodeRegistry?,
        trackedPoll: Duration = defaultTrackedPoll,
        untrackedPoll: Duration = defaultUntrackedPoll,
        park: (@Sendable (_ id: String, _ timeout: Duration) async -> Bool)? = nil,
        observationRevision: @Sendable () async -> UInt64 = { 0 },
        acceptExitCode: @Sendable (_ id: String) async -> Bool = { _ in true },
        state: @Sendable (_ id: String, _ exitKnown: Bool) async throws -> String
    ) async throws -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let revision = await observationRevision()
            let snapshot = await exitCodes?.snapshot(for: id)
            let entry = snapshot?.entry
            let eligibleBefore = await acceptExitCode(id)
            let current = try await state(id, eligibleBefore && entry?.exitCode != nil)
            let acceptsExit = await acceptExitCode(id)
            let after = await exitCodes?.snapshot(for: id)
            guard snapshot == after, eligibleBefore == acceptsExit, await observationRevision() == revision else {
                // Reading runtime state suspends. An exit recorded while that
                // read was in flight changes the snapshot and is read on the
                // next pass, never discarded. Churn is not an exit. Preserve
                // the original wait budget even when lifecycle transitions
                // repeatedly invalidate reads.
                guard clock.now < deadline, !Task.isCancelled else {
                    return Outcome(exited: false, known: false, exitCode: nil, state: current)
                }
                continue
            }
            if acceptsExit, let code = entry?.exitCode {
                return Outcome(exited: true, known: true, exitCode: code, state: current)
            }
            // A stopped snapshot can beat the XPC wait reply. Keep waiting
            // for this generation's real status instead of failing a healthy
            // startup with "exit code unavailable". An untracked container or
            // a completed waiter with an unknown code still fails closed.
            let tracked = await exitCodes?.isTracked(id: id) ?? false
            let pending = entry == nil && tracked
            switch current {
            case "running", "stopping", "starting", "created":
                break
            default:
                if !pending {
                    return Outcome(exited: true, known: false, exitCode: nil, state: current)
                }
            }
            let now = clock.now
            guard now < deadline, !Task.isCancelled else {
                return Outcome(exited: false, known: false, exitCode: nil, state: current)
            }
            let remaining = deadline - now
            // An entry without a code (the waiter aged out or failed) will
            // never be replaced by a real one: poll the state like an
            // untracked container instead of spinning on the entry.
            if pending, let exitCodes {
                _ = await exitCodes.await(id: id, timeout: min(remaining, trackedPoll))
            } else if let park, await park(id, min(remaining, trackedPoll)) {
                continue
            } else {
                try? await Task.sleep(for: min(remaining, untrackedPoll))
            }
        }
    }
}
