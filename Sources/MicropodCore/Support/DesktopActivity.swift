import Foundation

/// Only the replaceable desktop opts in. Daemons and CLI clients retain their
/// own lifetime; closing this gate never stops an already running workload.
public final class DesktopActivity: @unchecked Sendable {
    public static let shared = DesktopActivity()
    private let lock = NSLock()
    private var enabled = false
    private var closed = false
    private var active = 0

    public init() {}
    public func enable(closed: Bool = false) {
        lock.withLock {
            enabled = true
            self.closed = closed
        }
    }
    public func claim() throws -> Claim? {
        try lock.withLock {
            guard enabled else { return nil }
            guard !closed else {
                throw MicropodError.message(
                    "Micropod is updating. Existing workloads are still running; try this action after it reopens.")
            }
            active += 1
            return Claim(self)
        }
    }
    public func closeIfIdle() -> Bool {
        lock.withLock {
            guard enabled, !closed, active == 0 else { return false }
            closed = true
            return true
        }
    }
    public func reopen() { lock.withLock { closed = false } }
    public var isClosed: Bool { lock.withLock { closed } }

    public final class Claim: @unchecked Sendable {
        private let owner: DesktopActivity
        fileprivate init(_ owner: DesktopActivity) { self.owner = owner }
        deinit { owner.lock.withLock { owner.active -= 1 } }
    }
}
