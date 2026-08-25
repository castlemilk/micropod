import Foundation
import Observation

/// One long-running op tracked by the Operations drawer. The drawer is a
/// projection of these; completed ops also roll into the activity feed.
public struct ActiveOperation: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        case pull, build, compose, container
    }

    public enum Status: Equatable {
        case running, succeeded
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public let title: String
    public let kind: Kind
    public let startedAt: Date
    public var status: Status = .running
    public var events: [String] = []

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
        operations.filter { $0.status == .running }.count
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
