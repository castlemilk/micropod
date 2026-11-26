import Darwin
import Foundation

/// Let a foreground exec unwind its local raw terminal before the CLI exits
/// for a termination signal. Keystrokes generated in the guest still reach its PTY.
func withTerminalSignals(
    _ attach: @escaping @Sendable () async throws -> Int32
) async throws -> Int32 {
    let (events, received) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var registrations: [(Int32, sigaction, DispatchSourceSignal)] = []
    defer {
        for (number, previous, source) in registrations {
            source.cancel()
            var previous = previous
            sigaction(number, &previous, nil)
        }
        received.finish()
    }
    for number in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE] {
        var previous = sigaction()
        guard sigaction(number, nil, &previous) == 0, previous.__sigaction_u.__sa_handler == nil else { continue }
        var ignored = sigaction()
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { received.yield(number) }
        source.activate()
        guard sigaction(number, &ignored, nil) == 0 else {
            source.cancel()
            continue
        }
        registrations.append((number, previous, source))
    }
    return try await withThrowingTaskGroup(of: Int32.self) { tasks in
        tasks.addTask {
            do { return try await attach() } catch let error as POSIXError where error.code == .EPIPE {
                return 128 + SIGPIPE
            }
        }
        tasks.addTask {
            for await number in events { return 128 + number }
            throw CancellationError()
        }
        defer { tasks.cancelAll() }
        guard let result = try await tasks.next() else { throw CancellationError() }
        return result
    }
}

/// Runs `body` with SIGHUP, SIGINT and SIGTERM held off until it returns,
/// for a transaction that must not stop half way (an HVF payload
/// activation between booting its trial and committing or rolling back).
/// The first such signal prints `notice`; the result carries the signal so
/// the caller can exit with `128 + signal` once the work is done.
func withSignalsDeferred<T: Sendable>(
    notice: String, _ body: () async throws -> T
) async throws -> (result: T, signal: Int32?) {
    let received = DeferredSignal()
    var registrations: [(Int32, sigaction, DispatchSourceSignal)] = []
    defer {
        for (number, previous, source) in registrations {
            source.cancel()
            var previous = previous
            sigaction(number, &previous, nil)
        }
    }
    for number in [SIGHUP, SIGINT, SIGTERM] {
        var previous = sigaction()
        guard sigaction(number, nil, &previous) == 0 else { continue }
        var ignored = sigaction()
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            if received.note(number) { FileHandle.standardError.write(Data("\(notice)\n".utf8)) }
        }
        source.activate()
        guard sigaction(number, &ignored, nil) == 0 else {
            source.cancel()
            continue
        }
        registrations.append((number, previous, source))
    }
    let result = try await body()
    return (result, received.signal)
}

/// The first signal `withSignalsDeferred` held off.
private final class DeferredSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Int32?

    /// True for the first signal only.
    func note(_ number: Int32) -> Bool {
        lock.withLock {
            guard first == nil else { return false }
            first = number
            return true
        }
    }

    var signal: Int32? { lock.withLock { first } }
}
