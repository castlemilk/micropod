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
            do { return try await attach() }
            catch let error as POSIXError where error.code == .EPIPE { return 128 + SIGPIPE }
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
