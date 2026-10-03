import Foundation

/// A single log line for a container.
public struct LogLine: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let timestamp: Date
    /// Cumulative complete lines discarded by a saturated source queue.
    public let upstreamDiscardedLines: Int

    public init(id: UUID = UUID(), text: String, timestamp: Date = Date(), upstreamDiscardedLines: Int = 0) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.upstreamDiscardedLines = upstreamDiscardedLines
    }
}

public protocol LogStreaming: Sendable {
    /// Live-follow stream of a container's stdio logs (`container logs -f`).
    func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error>
    /// Bounded fetch of the last N lines (`container logs -n N`, no follow).
    func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine]
}

public struct LogStreamer: LogStreaming {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func tail(id: String, lines: Int = 100, boot: Bool = false) async throws -> [LogLine] {
        let command = ContainerCommandFactory.logs(id, tail: lines, follow: false, boot: boot)
        let output = try await client.run(command, timeout: .seconds(30))
        return
            output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .suffix(lines)
            .map { LogLine(text: String($0)) }
    }
    public func stream(id: String, tail: Int? = nil, boot: Bool = false) -> AsyncThrowingStream<
        LogLine, Error
    > {
        let command = ContainerCommandFactory.logs(id, tail: tail, follow: true, boot: boot)
        return Self.lines(client.stream(command))
    }

    /// Re-chunks raw CLI output into complete lines (partial trailing lines
    /// are held until their newline arrives, flushed at EOF).
    public static func lines(_ chunks: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<LogLine, Error> {
        // Shared CLI/API consumers require every complete line. Backpressure
        // bounds queued text near 1 MiB without silently dropping log output.
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task.detached {
                var decoder = StreamingUTF8Decoder()
                var buffer = BoundedLogLineAccumulator()
                var iterator = chunks.makeAsyncIterator()
                func yield(_ text: String) async throws {
                    let line = LogLine(text: text)
                    var yieldedOnce = false
                    while true {
                        try Task.checkCancellation()
                        switch continuation.yield(line) {
                        case .enqueued:
                            return
                        case .dropped:
                            if !yieldedOnce {
                                yieldedOnce = true
                                await Task.yield()
                            } else {
                                try await Task.sleep(for: .milliseconds(1))
                            }
                        case .terminated:
                            throw CancellationError()
                        @unknown default:
                            throw CancellationError()
                        }
                    }
                }
                do {
                    while let chunk = try await iterator.next() {
                        try Task.checkCancellation()
                        for line in buffer.append(decoder.decode(chunk)) { try await yield(line) }
                    }
                    for line in buffer.append(decoder.finish()) { try await yield(line) }
                    if let trailing = buffer.finish() { try await yield(trailing) }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        // Cancellation can arrive while a saturated delivery
                        // queue is waiting rather than inside the raw next().
                        // Re-enter next in the cancelled task so the upstream
                        // stream runs its termination handler immediately.
                        withUnsafeCurrentTask { $0?.cancel() }
                        _ = try? await iterator.next()
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A newline-free source cannot grow an unbounded partial line. The retained
/// prefix has a visible truncation marker; the next newline resets the budget.
struct BoundedLogLineAccumulator: Sendable {
    static let maximumBytes = 16 * 1024
    private var partial = ""
    private var partialBytes = 0
    private var truncated = false

    mutating func append(_ text: String) -> [String] {
        let fragments = text.split(separator: "\n", omittingEmptySubsequences: false)
        var complete: [String] = []
        for (index, fragment) in fragments.enumerated() {
            if !truncated {
                let remaining = Self.maximumBytes - partialBytes
                let fragmentBytes = fragment.utf8.count
                if fragmentBytes <= remaining {
                    partial.append(contentsOf: fragment)
                    partialBytes += fragmentBytes
                } else {
                    var decoder = StreamingUTF8Decoder()
                    let prefix = decoder.decode(Data(fragment.utf8.prefix(remaining)))
                    partial.append(prefix)
                    partialBytes += prefix.utf8.count
                    truncated = true
                }
            }
            if index < fragments.count - 1, let line = finish() { complete.append(line) }
        }
        return complete
    }

    mutating func finish() -> String? {
        defer {
            partial = ""
            partialBytes = 0
            truncated = false
        }
        guard !partial.isEmpty || truncated else { return nil }
        return partial + (truncated ? " … [line truncated at 16 KiB]" : "")
    }
}
