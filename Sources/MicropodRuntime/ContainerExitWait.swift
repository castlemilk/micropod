import Foundation

/// The `WaitContainer` loop: waits until a container is terminal or the
/// timeout elapses, without a blocking runtime wait in the request path.
///
/// - **Tracked containers** (the native backend started them, so the
///   ``ExitCodeRegistry`` runs a waiter) park on the registry and wake the
///   moment the exit is recorded. The runtime state is re-read every
///   `trackedPoll` (1 s) as a safety net.
/// - **Untracked containers** (CLI backend, CLI-created, started before
///   this process, a wait that arrived before `track`, or an entry whose
///   waiter aged out) have no signal to wait on: the runtime state is polled
///   every `untrackedPoll` (150 ms, the cadence before the registry could
///   wake waits), so their exit latency is unchanged.
///
/// A registry code is authoritative (`known: true`) even if the state has
/// not flipped to `stopped` yet. `running`/`stopping` are non-terminal; so
/// is `created` (never started — it may still be). Anything else
/// (`stopped`, or `unknown` after the container vanished mid-wait) is
/// `exited: true`, with `known: false` when no registry code exists. Errors
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
        state: @Sendable (_ id: String, _ exitKnown: Bool) async throws -> String
    ) async throws -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let entry = await exitCodes?.entry(for: id)
            let current = try await state(id, entry?.exitCode != nil)
            if let code = entry?.exitCode {
                return Outcome(exited: true, known: true, exitCode: code, state: current)
            }
            switch current {
            case "running", "stopping", "created":
                break
            default:
                return Outcome(exited: true, known: false, exitCode: nil, state: current)
            }
            let now = clock.now
            guard now < deadline, !Task.isCancelled else {
                return Outcome(exited: false, known: false, exitCode: nil, state: current)
            }
            let remaining = deadline - now
            // An entry without a code (the waiter aged out or failed) will
            // never be replaced by a real one: poll the state like an
            // untracked container instead of spinning on the entry.
            if entry == nil, let exitCodes, await exitCodes.isTracked(id: id) {
                _ = await exitCodes.await(id: id, timeout: min(remaining, trackedPoll))
            } else {
                try? await Task.sleep(for: min(remaining, untrackedPoll))
            }
        }
    }
}
