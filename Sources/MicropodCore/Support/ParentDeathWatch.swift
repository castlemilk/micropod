import Foundation

/// Watches the process that spawned this executable and exits when it dies.
///
/// Managed helper processes (the HTTP API server, the Docker shim) are
/// "kernel agents" of the desktop app: the app supervises them while it is
/// alive and terminates them on a clean quit. If the app crashes or is
/// SIGKILLed, neither path runs — this watchdog is the last line of defense
/// against orphaned agents. It only arms when the parent opted in via the
/// `MICROPOD_PARENT_PID` environment variable, so binaries started by hand
/// (`task api`, `task shim`) keep their normal lifetime.
public enum ParentDeathWatch {
    /// Environment variable the supervising app sets to its own pid.
    public static let parentPIDEnv = "MICROPOD_PARENT_PID"

    /// The timer must stay retained for the process lifetime; guarded by
    /// `lock` because `install()` can race under strict concurrency.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Arms the watchdog if `MICROPOD_PARENT_PID` names a live pid.
    /// Cheap to call at the top of `main()`; a no-op when the variable is
    /// absent or malformed.
    public static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil,
            let raw = ProcessInfo.processInfo.environment[parentPIDEnv],
            let parentPID = Int32(raw),
            parentPID > 1
        else { return }

        // The spawn moment is the only time the parent could already be
        // gone — check once up front so we never linger after an orphan
        // spawn, then keep a slow 2s heartbeat afterwards.
        guard processAlive(parentPID) else { exit(0) }

        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        source.setEventHandler {
            if !processAlive(parentPID) {
                exit(0)
            }
        }
        source.resume()
        timer = source
    }

    /// `kill(pid, 0)` semantics: ESRCH means truly gone; EPERM means alive
    /// but owned by another user (still alive for our purposes).
    private static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
