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
/// - **Stop signal.** A recorded exit code in the ``ExitCodeRegistry``, or a
///   runtime state that is no longer `running` or `stopping` (see
///   ``isLive(state:)``), or the container no longer listed. A lookup that
///   fails is not a stop signal: the stream keeps following, and fails
///   (rather than ending cleanly) if the runtime stays silent for
///   ``defaultUnknownLivenessLimit``. The registry is checked before every tick and each
///   tick parks on it, so a recorded exit ends the wait at once instead of
///   at the next tick; the state is checked right after the
///   backlog, then 250 ms after the latest bytes, backing off ×2 to 1 s
///   while the stream stays quiet.
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
    private let liveness: @Sendable (String) async -> Liveness
    /// How long the runtime may fail to answer whether the container is
    /// live before a following stream gives up with an error.
    private let unknownLivenessLimit: Duration
    /// Called after every follow-loop pause, before its drain.
    private let onTick: @Sendable () -> Void
    private let exitCodes: ExitCodeRegistry?

    /// A log fd plus the read cursor, reopened once per stream.
    private struct Source: Sendable {
        let handle: FileHandle
        var offset: UInt64 = 0

        func endOffset() throws -> UInt64 { try handle.seekToEnd() }

        /// One bounded read from the bytes present when this drain began.
        mutating func read(upTo end: UInt64) throws -> Data {
            guard offset < end else { return Data() }
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: Int(min(1 << 16, end - offset))) ?? Data()
            offset += UInt64(chunk.count)
            return chunk
        }

        /// Find a line boundary near the end without materializing the whole
        /// file. One extra line accommodates an unterminated trailing fragment.
        mutating func seekForTail(_ lines: Int) throws {
            var cursor = try endOffset()
            var found = 0
            var hasContent = false
            while cursor > 0 {
                try Task.checkCancellation()
                let start = cursor > 1 << 16 ? cursor - (1 << 16) : 0
                try handle.seek(toOffset: start)
                let chunk = try handle.read(upToCount: Int(cursor - start)) ?? Data()
                for index in chunk.indices.reversed() {
                    if chunk[index] == 0x0A {
                        if hasContent {
                            found += 1
                            hasContent = false
                        }
                        if found > max(0, lines) {
                            offset = start + UInt64(index - chunk.startIndex) + 1
                            return
                        }
                    } else {
                        hasContent = true
                    }
                }
                cursor = start
            }
            offset = 0
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
            liveness: { id in
                // A lookup that fails says nothing about the container: an
                // apiserver busy behind its request lock answers late. Only
                // a container the runtime no longer lists, or one in a
                // finished state, has stopped writing. Every follow shares
                // the polled list (`get` confirms an absent id directly).
                let data: Data?
                do {
                    data = try await api.get(id: id, policy: .polling)
                } catch {
                    return .unknown
                }
                guard let data else { return .stopped }
                guard
                    let entries = try? MicropodJSON.decodeArray(JSONValue.self, from: data, context: "container get"),
                    case .object(let obj)? = entries.first,
                    case .object(let status) = obj["status"],
                    case .string(let state) = status["state"]
                else { return .unknown }
                return Self.isLive(state: state) ? .live : .stopped
            },
            exitCodes: exitCodes)
    }

    /// What the runtime says about whether a container may still write.
    enum Liveness: Equatable, Sendable {
        case live
        case stopped
        /// The runtime did not answer: keep following.
        case unknown
    }

    /// Default for ``unknownLivenessLimit``.
    static let defaultUnknownLivenessLimit: Duration = .seconds(30)

    /// Test seam with a yes/no liveness provider (never unknown).
    init(
        sourceProvider: @escaping @Sendable (String, Bool) async throws -> [FileHandle],
        isLive: @escaping @Sendable (String) async -> Bool,
        exitCodes: ExitCodeRegistry? = nil,
        onTick: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            sourceProvider: sourceProvider,
            liveness: { await isLive($0) ? .live : .stopped },
            exitCodes: exitCodes,
            onTick: onTick)
    }

    /// Test seam: sources + liveness provider instead of XPC.
    /// `sourceProvider(id, boot)` returns the log files to follow;
    /// `isLive(id)` answers whether the container may still write to them;
    /// `onTick` observes the follow loop's cadence.
    init(
        sourceProvider: @escaping @Sendable (String, Bool) async throws -> [FileHandle],
        liveness: @escaping @Sendable (String) async -> Liveness,
        exitCodes: ExitCodeRegistry? = nil,
        unknownLivenessLimit: Duration = NativeLogStreamer.defaultUnknownLivenessLimit,
        onTick: @escaping @Sendable () -> Void = {}
    ) {
        self.sourceProvider = sourceProvider
        self.liveness = liveness
        self.exitCodes = exitCodes
        self.unknownLivenessLimit = unknownLivenessLimit
        self.onTick = onTick
    }

    /// Whether a container in runtime `state` may still write output.
    /// `stopping` counts: the runtime enters it before the graceful stop
    /// waits for the process, which can keep writing until it exits.
    static func isLive(state: String) -> Bool {
        state == "running" || state == "stopping"
    }

    public func tail(id: String, lines: Int = 100, boot: Bool = false) async throws -> [LogLine] {
        let sources = try await sources(id: id, boot: boot)
        let worker = Task.detached {
            var sources = sources
            defer { Self.close(sources) }
            if sources.count == 1 { try sources[0].seekForTail(lines) }
            var splitter = LineSplitter()
            var retained = TailBuffer(limit: max(0, lines))
            for index in sources.indices {
                let end = try sources[index].endOffset()
                while true {
                    try Task.checkCancellation()
                    let chunk = try sources[index].read(upTo: end)
                    if chunk.isEmpty { break }
                    retained.append(contentsOf: try splitter.feed(chunk))
                }
            }
            retained.append(contentsOf: splitter.finish())
            return retained.lines.map { LogLine(text: $0) }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func stream(id: String, tail: Int? = nil, boot: Bool = false) -> AsyncThrowingStream<
        LogLine, Error
    > {
        // Eight queued lines cap even pathological 1 MiB lines at 8 MiB.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let task = Task.detached {
                do {
                    var sources = try await self.sources(id: id, boot: boot)
                    defer { Self.close(sources) }
                    var splitter = LineSplitter()
                    func emit(_ lines: [String]) async throws {
                        for text in lines {
                            let line = LogLine(text: text)
                            var yieldedOnce = false
                            while true {
                                try Task.checkCancellation()
                                switch continuation.yield(line) {
                                case .enqueued: break
                                case .dropped:
                                    // Preserve full CLI/MCP output under slow
                                    // consumers without an unbounded queue.
                                    if !yieldedOnce {
                                        yieldedOnce = true
                                        await Task.yield()
                                    } else {
                                        try await Task.sleep(for: .milliseconds(1))
                                    }
                                    continue
                                case .terminated: throw CancellationError()
                                @unknown default: throw CancellationError()
                                }
                                break
                            }
                        }
                    }

                    // Backlog, honoring `tail`.
                    if let tail, sources.count == 1 { try sources[0].seekForTail(tail) }
                    var backlog = tail.map { TailBuffer(limit: max(0, $0)) }
                    for index in sources.indices {
                        let end = try sources[index].endOffset()
                        while true {
                            try Task.checkCancellation()
                            let chunk = try sources[index].read(upTo: end)
                            if chunk.isEmpty { break }
                            let lines = try splitter.feed(chunk)
                            if backlog != nil { backlog?.append(contentsOf: lines) } else { try await emit(lines) }
                        }
                    }
                    if let backlog { try await emit(backlog.lines) }

                    // Follow until the stop signal.
                    let clock = ContinuousClock()
                    var schedule = StateCheckSchedule(now: clock.now)
                    var unknownSince: ContinuousClock.Instant?
                    follow: while true {
                        if await self.exitRecorded(id: id) { break }
                        try await self.pause(id: id)
                        self.onTick()
                        var sawBytes = false
                        for index in sources.indices {
                            let end = try sources[index].endOffset()
                            while true {
                                try Task.checkCancellation()
                                let chunk = try sources[index].read(upTo: end)
                                if chunk.isEmpty { break }
                                sawBytes = true
                                try await emit(try splitter.feed(chunk))
                            }
                        }
                        if sawBytes {
                            schedule.sawBytes(at: clock.now)
                            continue
                        }
                        guard schedule.isDue(at: clock.now) else { continue }
                        switch await self.liveness(id) {
                        case .stopped:
                            break follow
                        case .live:
                            unknownSince = nil
                        case .unknown:
                            // Ending here would read as "the container
                            // stopped and every line was sent" while it may
                            // still be writing. Keep following; if the
                            // runtime stays silent, fail the stream so the
                            // client re-opens it rather than trusting a
                            // clean end.
                            let since = unknownSince ?? clock.now
                            unknownSince = since
                            if clock.now - since >= self.unknownLivenessLimit {
                                throw MicropodError.message(
                                    "container \(id): runtime has not answered whether it is running for "
                                        + "\(self.unknownLivenessLimit); log follow stopped")
                            }
                        }
                        schedule.stillRunning(at: clock.now)
                    }

                    // Final drain: bytes that landed after the last tick.
                    for index in sources.indices {
                        let end = try sources[index].endOffset()
                        while true {
                            try Task.checkCancellation()
                            let chunk = try sources[index].read(upTo: end)
                            if chunk.isEmpty { break }
                            try await emit(try splitter.feed(chunk))
                        }
                    }
                    try await emit(splitter.finish())
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

    /// One drain tick, cut short when the registry records the exit — the
    /// loop then stops following and drains the tail at once. A registry
    /// entry without a code will never wake anyone, so it gets the plain
    /// tick. Throws `CancellationError` when the stream is torn down.
    private func pause(id: String) async throws {
        if let exitCodes, await exitCodes.entry(for: id) == nil {
            _ = await exitCodes.await(id: id, timeout: Self.drainTick)
            try Task.checkCancellation()
        } else {
            try await Task.sleep(for: Self.drainTick)
        }
    }

    /// True once the registry holds this container's exit code. An entry
    /// without one (the waiter aged out or failed) proves nothing about the
    /// container, so the runtime state stays authoritative.
    private func exitRecorded(id: String) async -> Bool {
        guard let exitCodes else { return false }
        return await exitCodes.entry(for: id)?.exitCode != nil
    }

    private static func close(_ sources: [Source]) {
        for source in sources { try? source.handle.close() }
    }

    /// When the follow loop next asks the runtime whether the container is
    /// still live: at once after the backlog, then 250 ms after the
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

        /// The container is still live: wait longer before asking again.
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
        mutating func feed(_ data: Data) throws -> [String] {
            carry.append(data)
            var lines: [String] = []
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 0x0A) {
                if newline > start {
                    guard newline - start <= 1024 * 1024 else { throw Self.oversizedLine() }
                    lines.append(String(decoding: carry[start..<newline], as: UTF8.self))
                }
                start = carry.index(after: newline)
            }
            carry.removeSubrange(carry.startIndex..<start)
            guard carry.count <= 1024 * 1024 else { throw Self.oversizedLine() }
            return lines
        }

        /// The pending fragment as a last line (the stream is ending).
        mutating func finish() -> [String] {
            defer { carry.removeAll() }
            return carry.isEmpty ? [] : [String(decoding: carry, as: UTF8.self)]
        }

        private static func oversizedLine() -> MicropodError {
            .message("Log line exceeded the 1 MiB delivery limit; insert line breaks to continue streaming.")
        }
    }

    /// A fixed-size ring for a requested backlog, rather than retaining every
    /// decoded line before selecting its suffix.
    private struct TailBuffer {
        private var storage: [String?]
        private var head = 0
        private var count = 0
        init(limit: Int) { storage = Array(repeating: nil, count: limit) }

        mutating func append(contentsOf lines: [String]) {
            guard !storage.isEmpty else { return }
            for line in lines {
                if count == storage.count {
                    storage[head] = line
                    head = (head + 1) % storage.count
                } else {
                    storage[(head + count) % storage.count] = line
                    count += 1
                }
            }
        }

        var lines: [String] { (0..<count).compactMap { storage[(head + $0) % storage.count] } }
    }
}
