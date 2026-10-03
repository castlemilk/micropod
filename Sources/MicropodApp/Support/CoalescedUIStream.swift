import Foundation
import MicropodCore

/// A stream publishes its latest bounded snapshot at most once per frame
/// interval. Parsing and retention run away from the main actor; an idle source
/// has no polling timer. Replacing queued snapshots cannot lose retained data.
enum CoalescedUIStream {
    static func snapshots<Element: Sendable, State: Sendable, Output: Sendable>(
        from source: AsyncThrowingStream<Element, Error>,
        initial: State,
        interval: Duration = .milliseconds(33),
        append: @escaping @Sendable (inout State, Element) -> Void,
        finish: @escaping @Sendable (inout State) -> Void = { _ in },
        snapshot: @escaping @Sendable (State) -> Output
    ) -> AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let batcher = SnapshotBatcher(
                state: initial, interval: interval, continuation: continuation,
                append: append, finish: finish, snapshot: snapshot)
            let producer = Task.detached {
                do {
                    for try await element in source {
                        try Task.checkCancellation()
                        batcher.append(element)
                    }
                    batcher.finish(error: nil)
                } catch {
                    batcher.finish(error: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
                batcher.cancel()
            }
        }
    }
}

/// All state and pending-publication accesses are protected by `lock`.
private final class SnapshotBatcher<Element: Sendable, State: Sendable, Output: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var state: State
    private let interval: Duration
    private let continuation: AsyncThrowingStream<Output, Error>.Continuation
    private let appendElement: @Sendable (inout State, Element) -> Void
    private let finishState: @Sendable (inout State) -> Void
    private let makeSnapshot: @Sendable (State) -> Output
    private var pending: Task<Void, Never>?
    private var stopped = false
    private var dirty = false

    init(
        state: State, interval: Duration,
        continuation: AsyncThrowingStream<Output, Error>.Continuation,
        append: @escaping @Sendable (inout State, Element) -> Void,
        finish: @escaping @Sendable (inout State) -> Void,
        snapshot: @escaping @Sendable (State) -> Output
    ) {
        self.state = state
        self.interval = interval
        self.continuation = continuation
        self.appendElement = append
        self.finishState = finish
        self.makeSnapshot = snapshot
    }

    func append(_ element: Element) {
        lock.withLock {
            guard !stopped else { return }
            appendElement(&state, element)
            dirty = true
            guard pending == nil else { return }
            pending = Task.detached { [weak self, interval] in
                do {
                    try await Task.sleep(for: interval)
                    self?.publish()
                } catch {}
            }
        }
    }

    private func publish() {
        lock.withLock {
            pending = nil
            guard !stopped, dirty else { return }
            dirty = false
            continuation.yield(makeSnapshot(state))
        }
    }

    func finish(error: Error?) {
        let output: Output? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            pending?.cancel()
            pending = nil
            finishState(&state)
            return makeSnapshot(state)
        }
        if let output { continuation.yield(output) }
        continuation.finish(throwing: error)
    }

    func cancel() {
        lock.withLock {
            stopped = true
            pending?.cancel()
            pending = nil
        }
    }
}

struct LogStreamSnapshot: Sendable {
    let lines: [LogLine]
    let discardedLines: Int
    let retainedBytes: Int
    let truncatedLines: Int
}

/// A fixed-size ring avoids shifting a thousand retained rows per incoming line.
struct BoundedLogRenderBuffer: Sendable {
    static let defaultLineLimit = 1000
    static let defaultByteLimit = 1024 * 1024
    static let maximumRenderedLineBytes = 16 * 1024
    private var storage: [LogLine?]
    private var byteSizes: [Int]
    private var head = 0
    private var count = 0
    private let byteLimit: Int
    private(set) var retainedBytes = 0
    private(set) var discardedLines = 0
    private var upstreamDiscardedLines = 0
    private(set) var truncatedLines = 0

    init(lineLimit: Int = defaultLineLimit, byteLimit: Int = defaultByteLimit) {
        storage = Array(repeating: nil, count: max(1, lineLimit))
        byteSizes = Array(repeating: 0, count: max(1, lineLimit))
        self.byteLimit = max(1, byteLimit)
    }

    mutating func append(_ line: LogLine) {
        upstreamDiscardedLines = max(upstreamDiscardedLines, line.upstreamDiscardedLines)
        let rendered: LogLine
        if line.text.utf8.count > Self.maximumRenderedLineBytes {
            let marker = " … [display truncated at 16 KiB]"
            var decoder = StreamingUTF8Decoder()
            let prefix = decoder.decode(
                Data(line.text.utf8.prefix(Self.maximumRenderedLineBytes - marker.utf8.count)))
            rendered = LogLine(
                id: line.id, text: prefix + marker, timestamp: line.timestamp,
                upstreamDiscardedLines: line.upstreamDiscardedLines)
            truncatedLines += 1
        } else {
            rendered = line
        }
        let bytes = rendered.text.utf8.count
        if count == storage.count { evictOldest() }
        let index = (head + count) % storage.count
        storage[index] = rendered
        byteSizes[index] = bytes
        retainedBytes += bytes
        count += 1
        while retainedBytes > byteLimit, count > 0 { evictOldest() }
    }

    private mutating func evictOldest() {
        retainedBytes -= byteSizes[head]
        storage[head] = nil
        byteSizes[head] = 0
        head = (head + 1) % storage.count
        count -= 1
        discardedLines += 1
    }

    var snapshot: LogStreamSnapshot {
        let lines = (0..<count).compactMap { storage[(head + $0) % storage.count] }
        return LogStreamSnapshot(
            lines: lines, discardedLines: discardedLines + upstreamDiscardedLines,
            retainedBytes: retainedBytes, truncatedLines: truncatedLines)
    }
}

struct TerminalStreamSnapshot: Sendable {
    let text: String
    let discardedBytes: Int
}

/// Retains bounded text chunks rather than copying and counting the entire
/// terminal transcript every PTY read. Joining occurs only for a UI publication.
struct BoundedTerminalRenderBuffer: Sendable {
    static let defaultByteLimit = 256 * 1024
    private let byteLimit: Int
    private var pieces: [String] = []
    private var decoder = StreamingUTF8Decoder()
    private var ansi = StreamingANSITextFilter()
    private(set) var retainedBytes = 0
    private(set) var discardedBytes = 0

    init(byteLimit: Int = defaultByteLimit) { self.byteLimit = max(1, byteLimit) }

    mutating func append(_ data: Data) { appendText(ansi.filter(decoder.decode(data))) }

    mutating func finish() { appendText(ansi.filter(decoder.finish())) }

    private mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        let byteCount = text.utf8.count
        if let last = pieces.last, last.utf8.count + byteCount <= 4096 {
            pieces[pieces.count - 1].append(text)
        } else {
            pieces.append(text)
        }
        retainedBytes += byteCount
        while retainedBytes > byteLimit, pieces.count > 1 {
            let removed = pieces.removeFirst().utf8.count
            retainedBytes -= removed
            discardedBytes += removed
        }
        if retainedBytes > byteLimit, let only = pieces.first {
            // String character boundaries preserve even multi-scalar graphemes
            // when a single exceptionally large read exceeds the byte budget.
            var suffixBytes = 0
            var start = only.endIndex
            while start > only.startIndex {
                let previous = only.index(before: start)
                let size = only[previous..<start].utf8.count
                guard suffixBytes + size <= byteLimit else { break }
                suffixBytes += size
                start = previous
            }
            pieces[0] = String(only[start...])
            discardedBytes += retainedBytes - suffixBytes
            retainedBytes = suffixBytes
        }
    }

    var snapshot: TerminalStreamSnapshot {
        TerminalStreamSnapshot(text: pieces.joined(), discardedBytes: discardedBytes)
    }
}
