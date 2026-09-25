import Foundation
import MicropodCore

/// `LogStreaming` backed by the `containerLogs` XPC route, which returns
/// the container's log file handles directly — no `container logs -f`
/// process per stream.
///
/// The fds point at regular files (the apiserver's per-container logs),
/// not pipes: reads hit EOF rather than blocking. `stream` therefore
/// tracks file offsets and drains new bytes on 80 ms ticks, finishing once
/// the container has stopped — matching `container logs -f` behavior:
///
/// - **Stop signal.** A recorded exit code in the ``ExitCodeRegistry`` ends
///   the stream without asking the runtime. Otherwise the runtime state is
///   checked right after the backlog, then 250 ms after the latest bytes,
///   backing off ×2 to 1 s while the stream stays quiet.
/// - **Final drain.** After the stop signal the sources are drained once
///   more before the final emit, so bytes written between the last tick and
///   the stop are delivered. Containerization reports an exit only after the
///   process's stdio has been relayed (it waits up to 3 s), so that drain
///   sees the tail.
/// - **Lines.** Output is split on `\n`; empty lines are dropped, and stdout
///   and stderr arrive merged (the log file does not separate them). `tail`
///   counts delivered lines; a final fragment without a newline is emitted
///   when the stream ends.
public struct NativeLogStreamer: LogStreaming {
    /// How often a following stream reads the log files for new bytes.
    private static let drainTick: Duration = .milliseconds(80)

    private let sourceProvider: @Sendable (String, Bool) async throws -> [FileHandle]
    private let isRunning: @Sendable (String) async -> Bool
    private let exitCodes: ExitCodeRegistry?

    /// A log fd plus the read cursor, reopened once per stream.
    private struct Source {
        let handle: FileHandle
        var offset: UInt64 = 0

        /// Reads everything appended since the last call.
        mutating func drain() -> Data {
            do {
                try handle.seek(toOffset: offset)
            } catch {
                return Data()
            }
            var out = Data()
            while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                out.append(chunk)
            }
            offset += UInt64(out.count)
            return out
        }
    }

    public init(api: APIServerClient, exitCodes: ExitCodeRegistry? = nil) {
        self.init(
            sourceProvider: { id, boot in
                // `containerLogs` returns [containerLog, bootlog] — index 0
                // is the init process's combined stdio (what `container
                // logs` shows), index 1 is the kernel/vminitd boot log
                // (`container logs --boot`).
                let handles = try await api.logs(id: id)
                let index = boot ? 1 : 0
                guard handles.indices.contains(index) else {
                    throw MicropodError.message("container \(id): missing log fd")
                }
                return [handles[index]]
            },
            isRunning: { id in
                guard let managed = try? await api.managed(id: id),
                    case .object(let obj) = managed,
                    case .object(let status) = obj["status"],
                    case .string(let state) = status["state"]
                else { return false }
                return state == "running"
            },
            exitCodes: exitCodes)
    }

    /// Test seam: sources + running-state provider instead of XPC.
    /// `sourceProvider(id, boot)` returns the log files to follow.
    init(
        sourceProvider: @escaping @Sendable (String, Bool) async throws -> [FileHandle],
        isRunning: @escaping @Sendable (String) async -> Bool,
        exitCodes: ExitCodeRegistry? = nil
    ) {
        self.sourceProvider = sourceProvider
        self.isRunning = isRunning
        self.exitCodes = exitCodes
    }

    public func tail(id: String, lines: Int = 100, boot: Bool = false) async throws -> [LogLine] {
        var sources = try await sources(id: id, boot: boot)
        var splitter = LineSplitter()
        let all = splitter.feed(Self.drain(&sources)) + splitter.finish()
        return all.suffix(lines).map { LogLine(text: $0) }
    }

    public func stream(id: String, tail: Int? = nil, boot: Bool = false) -> AsyncThrowingStream<
        LogLine, Error
    > {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sources = try await self.sources(id: id, boot: boot)
                    var splitter = LineSplitter()
                    func emit(_ lines: some Sequence<String>) {
                        for line in lines { continuation.yield(LogLine(text: line)) }
                    }

                    // Backlog, honoring `tail`.
                    let backlog = splitter.feed(Self.drain(&sources))
                    emit(tail.map { backlog.suffix($0) } ?? backlog[...])

                    // Follow until the stop signal.
                    let clock = ContinuousClock()
                    var schedule = StateCheckSchedule(now: clock.now)
                    while true {
                        try await Task.sleep(for: Self.drainTick)
                        let fresh = Self.drain(&sources)
                        if !fresh.isEmpty {
                            emit(splitter.feed(fresh))
                            schedule.sawBytes(at: clock.now)
                            continue
                        }
                        if await self.exitRecorded(id: id) { break }
                        guard schedule.isDue(at: clock.now) else { continue }
                        if await !self.isRunning(id) { break }
                        schedule.stillRunning(at: clock.now)
                    }

                    // Final drain: bytes that landed after the last tick.
                    emit(splitter.feed(Self.drain(&sources)) + splitter.finish())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func sources(id: String, boot: Bool) async throws -> [Source] {
        try await sourceProvider(id, boot).map { Source(handle: $0) }
    }

    /// True once the registry holds this container's exit code. An entry
    /// without one (the waiter aged out or failed) proves nothing about the
    /// container, so the runtime state stays authoritative.
    private func exitRecorded(id: String) async -> Bool {
        guard let exitCodes else { return false }
        return await exitCodes.entry(for: id)?.exitCode != nil
    }

    private static func drain(_ sources: inout [Source]) -> Data {
        var data = Data()
        for i in sources.indices {
            data.append(sources[i].drain())
        }
        return data
    }

    /// When the follow loop next asks the runtime whether the container is
    /// still running: at once after the backlog, then 250 ms after the
    /// latest bytes, doubling up to 1 s while the stream stays quiet.
    struct StateCheckSchedule {
        static let initialInterval: Duration = .milliseconds(250)
        static let maxInterval: Duration = .seconds(1)

        private var interval: Duration
        private var due: ContinuousClock.Instant

        init(now: ContinuousClock.Instant) {
            interval = Self.initialInterval
            due = now
        }

        func isDue(at now: ContinuousClock.Instant) -> Bool {
            now >= due
        }

        /// The runtime answered "running": wait longer before asking again.
        mutating func stillRunning(at now: ContinuousClock.Instant) {
            scheduleNext(after: now)
        }

        /// New bytes show the container is alive: restart the backoff.
        mutating func sawBytes(at now: ContinuousClock.Instant) {
            interval = Self.initialInterval
            scheduleNext(after: now)
        }

        private mutating func scheduleNext(after now: ContinuousClock.Instant) {
            due = now + interval
            interval = min(interval * 2, Self.maxInterval)
        }
    }

    /// Splits drained bytes into lines, carrying an unterminated fragment
    /// into the next feed. Empty lines are dropped.
    private struct LineSplitter {
        private var carry = Data()

        /// The complete, non-empty lines once `data` is appended.
        mutating func feed(_ data: Data) -> [String] {
            carry.append(data)
            var lines: [String] = []
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 0x0A) {
                if newline > start {
                    lines.append(String(decoding: carry[start..<newline], as: UTF8.self))
                }
                start = carry.index(after: newline)
            }
            carry.removeSubrange(carry.startIndex..<start)
            return lines
        }

        /// The pending fragment as a last line (the stream is ending).
        mutating func finish() -> [String] {
            defer { carry.removeAll() }
            return carry.isEmpty ? [] : [String(decoding: carry, as: UTF8.self)]
        }
    }
}
