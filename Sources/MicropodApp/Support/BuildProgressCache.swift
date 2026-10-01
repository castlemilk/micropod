import Foundation
import MicropodCore

struct BuildProgressSnapshot: Equatable {
    let events: [ProgressEvent]
    let outputText: String
    static let empty = BuildProgressSnapshot(events: [], outputText: "")
}

/// The form can redraw for geometry or field edits without reparsing output.
/// Changed batches reuse validated overlapping lines; resets fall back to a
/// bounded full parse so equal metadata never hides altered intermediate text.
@MainActor
final class BuildProgressCache {
    private let parse: (String) -> ProgressEvent
    private var operationID: UUID?
    private var lines: [String] = []
    private var retainedCount = 0
    private var discardedCount = 0
    private var cached = BuildProgressSnapshot.empty

    init(parse: @escaping (String) -> ProgressEvent = { ProgressEvent.parse(line: $0) }) {
        self.parse = parse
    }

    func snapshot(for operation: ActiveOperation?) -> BuildProgressSnapshot {
        guard let operation else {
            operationID = nil
            lines = []
            retainedCount = 0
            discardedCount = 0
            cached = .empty
            return cached
        }
        let retained = operation.events
        let nextLines = Array(retained.suffix(500))
        let sameOperation = operationID == operation.id
        let appended = retained.count + operation.discardedEventCount - retainedCount - discardedCount
        let shift = max(0, lines.count + appended - nextLines.count)
        operationID = operation.id
        retainedCount = retained.count
        discardedCount = operation.discardedEventCount
        if sameOperation && lines == nextLines { return cached }

        let events: [ProgressEvent]
        if sameOperation, appended >= 0, shift <= lines.count {
            let overlap = lines.count - shift
            if overlap <= nextLines.count && lines.dropFirst(shift).elementsEqual(nextLines.prefix(overlap)) {
                events = Array(cached.events.dropFirst(shift)) + nextLines.dropFirst(overlap).map(parse)
            } else {
                events = nextLines.map(parse)
            }
        } else {
            events = nextLines.map(parse)
        }
        lines = nextLines
        cached = BuildProgressSnapshot(events: events, outputText: nextLines.joined(separator: "\n"))
        return cached
    }
}
