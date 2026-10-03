import Foundation
import Observation

/// One long-running op tracked by the Operations drawer. The drawer is a
/// projection of these; completed ops also roll into the activity feed.
public struct ActiveOperation: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case pull, build, compose, container
    }

    public enum Status: Equatable, Sendable {
        case running, succeeded
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public let title: String
    public let kind: Kind
    public let startedAt: Date
    public var status: Status = .running
    /// Recent output only; the limits apply to both streaming appends and
    /// legacy direct assignments. The projection preserves the public API.
    public var events: [String] {
        get { eventBuffer.events }
        set { eventBuffer.replace(with: newValue) }
    }
    public var discardedEventCount: Int { eventBuffer.discardedEventCount }
    public var truncatedEventCount: Int { eventBuffer.truncatedEventCount }
    public var retainedEventBytes: Int { eventBuffer.byteCount }
    public var latestEvent: String? { eventBuffer.latestEvent }
    public static let maximumEventCount = 512
    public static let maximumEventBytes = 128 * 1024
    public static let maximumSingleEventBytes = 8 * 1024
    private var eventBuffer = OperationEventBuffer()

    public mutating func appendEvents<S: Sequence>(_ events: S) where S.Element == String {
        for event in events { eventBuffer.append(event) }
    }

    public init(title: String, kind: Kind, id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
    }
}

/// Bookkeeping for long-running operations: begin/update/finish/cancel with
/// task handles so cancels propagate to the underlying stream. UI- and
/// CLI-free so it is unit-testable.
@Observable
public final class OperationRegistry {
    public private(set) var operations: [ActiveOperation] = []
    @ObservationIgnored
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func begin(_ title: String, kind: ActiveOperation.Kind) -> UUID {
        pruneFinishedHistory()
        let operation = ActiveOperation(title: title, kind: kind)
        operations.append(operation)
        return operation.id
    }

    public func update(_ id: UUID, _ mutate: (inout ActiveOperation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&operations[index])
    }

    /// Hot stream path: a bounded ring handles each event without copying or
    /// remeasuring the retained history. A batch produces one UI mutation.
    public func appendEvents<S: Sequence>(_ events: S, to id: UUID) where S.Element == String {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].appendEvents(events)
    }

    public func appendEvent(_ event: String, to id: UUID) {
        appendEvents(CollectionOfOne(event), to: id)
    }

    public func finish(_ id: UUID, status: ActiveOperation.Status) {
        if let index = operations.firstIndex(where: { $0.id == id }) {
            var operation = operations.remove(at: index)
            operation.status = status
            operations.append(operation)
        }
        tasks[id] = nil
        pruneFinishedHistory()
    }

    public func registerTask(_ id: UUID, _ task: Task<Void, Never>) {
        tasks[id] = task
    }

    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    public func operation(_ id: UUID) -> ActiveOperation? {
        operations.first { $0.id == id }
    }

    public var runningCount: Int {
        operations.count { $0.status == .running }
    }

    public func clearFinished() {
        operations.removeAll { $0.status != .running }
    }

    private func pruneFinishedHistory() {
        var excess = operations.count(where: { $0.status != .running }) - 100
        guard excess > 0 else { return }

        operations.removeAll { operation in
            guard excess > 0, operation.status != .running else { return false }
            excess -= 1
            return true
        }
    }
}

/// A growing circular buffer: count and byte limits evict in O(1), and
/// strings are released immediately. Capacity never exceeds the event cap.
private struct OperationEventBuffer: Equatable, Sendable {
    private struct Event: Equatable, Sendable {
        let text: String
        let byteCount: Int
    }
    private var storage: [Event?] = []
    private var head = 0
    private var count = 0
    private(set) var byteCount = 0
    private(set) var discardedEventCount = 0
    private(set) var truncatedEventCount = 0

    var latestEvent: String? {
        guard count > 0 else { return nil }
        return storage[(head + count - 1) % storage.count]?.text
    }

    var events: [String] {
        (0..<count).map { storage[(head + $0) % storage.count]!.text }
    }

    mutating func replace(with events: [String]) {
        let discarded = discardedEventCount
        let truncated = truncatedEventCount
        self = OperationEventBuffer()
        discardedEventCount = discarded
        truncatedEventCount = truncated
        for event in events { append(event) }
    }

    mutating func append(_ original: String) {
        let text: String
        let size = original.utf8.count
        if size > ActiveOperation.maximumSingleEventBytes {
            let marker = "[Earlier output truncated] "
            let suffix = Array(original.utf8.suffix(ActiveOperation.maximumSingleEventBytes - marker.utf8.count))
            // Start on a UTF-8 scalar boundary so a split multibyte character
            // never creates replacement bytes beyond the stated byte budget.
            let boundary = suffix.firstIndex { $0 & 0xC0 != 0x80 } ?? suffix.endIndex
            text = marker + String(decoding: suffix[boundary...], as: UTF8.self)
            truncatedEventCount += 1
        } else {
            text = original
        }
        let event = Event(text: text, byteCount: text.utf8.count)
        while count >= ActiveOperation.maximumEventCount
            || byteCount + event.byteCount > ActiveOperation.maximumEventBytes
        {
            discardOldest()
        }
        growIfNeeded()
        storage[(head + count) % storage.count] = event
        count += 1
        byteCount += event.byteCount
    }

    private mutating func discardOldest() {
        guard count > 0 else { return }
        byteCount -= storage[head]!.byteCount
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        discardedEventCount += 1
    }

    private mutating func growIfNeeded() {
        guard count == storage.count else { return }
        let capacity = min(ActiveOperation.maximumEventCount, max(8, storage.count * 2))
        var expanded = [Event?](repeating: nil, count: capacity)
        for index in 0..<count { expanded[index] = storage[(head + index) % storage.count] }
        storage = expanded
        head = 0
    }

    static func == (left: Self, right: Self) -> Bool {
        guard left.count == right.count, left.byteCount == right.byteCount,
            left.discardedEventCount == right.discardedEventCount,
            left.truncatedEventCount == right.truncatedEventCount
        else { return false }
        for index in 0..<left.count {
            if left.storage[(left.head + index) % left.storage.count]
                != right.storage[(right.head + index) % right.storage.count]
            {
                return false
            }
        }
        return true
    }
}
