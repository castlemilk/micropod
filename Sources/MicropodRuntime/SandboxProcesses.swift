import Containerization
import ContainerizationOS
import Foundation
import MicropodCore
import Synchronization

/// Processes started in running sandboxes through `SandboxService` — the
/// SDK's `spawn`/`exec`. Each keeps its output for streams that open late
/// and fans it out to live ones, then reports its exit.
final class SandboxProcessTable: Sendable {
    private let processes = Mutex<[String: SandboxProcess]>([:])

    /// Exited processes stay this long so a late stream still gets the output
    /// and the exit code.
    static let retention: Duration = .seconds(600)

    func add(_ process: SandboxProcess) {
        processes.withLock {
            let now = ContinuousClock.now
            $0 = $0.filter { $0.value.output.finishedAt.map { now - $0 < Self.retention } ?? true }
            $0[process.id] = process
        }
    }

    func process(_ sessionID: String, _ processID: String) throws -> SandboxProcess {
        guard let process = processes.withLock({ $0[processID] }), process.sessionID == sessionID else {
            throw MicropodError.message("notFound: no process \(processID) in sandbox \(sessionID)")
        }
        return process
    }

    /// Drop a removed sandbox's processes.
    func forget(session sessionID: String) {
        processes.withLock { $0 = $0.filter { $0.value.sessionID != sessionID } }
    }
}

struct SandboxProcess: Sendable {
    let id: String
    let sessionID: String
    let process: LinuxProcess
    let stdin: PushedInput?
    let output: ProcessOutput
}

/// Output of one process, in order: stdout/stderr chunks, then the exit.
public final class ProcessOutput: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case stdout(Data)
        case stderr(Data)
        case exit(Int32)
    }

    /// Output bytes replayed to a stream that opens late; the oldest go
    /// first past this.
    static let backlogLimit = 8 << 20
    /// Chunks a live stream may fall behind before it fails
    /// (`resource_exhausted`) rather than silently skipping output.
    static let lagLimit = 8192

    private let lock = NSLock()
    private var backlog: [Event] = []
    private var backlogBytes = 0
    private var subscribers: [AsyncThrowingStream<Event, any Error>.Continuation] = []
    private(set) var finishedAt: ContinuousClock.Instant?

    func writer(stderr: Bool) -> any Writer {
        EventWriter(output: self, stderr: stderr)
    }

    func append(_ event: Event) {
        lock.withLock {
            guard finishedAt == nil else { return }
            backlog.append(event)
            backlogBytes += Self.size(event)
            while backlogBytes > Self.backlogLimit, let first = backlog.first {
                backlog.removeFirst()
                backlogBytes -= Self.size(first)
            }
            subscribers = subscribers.filter { continuation in
                switch continuation.yield(event) {
                case .enqueued: return true
                case .dropped:
                    continuation.finish(
                        throwing: MicropodError.message(
                            "resourceExhausted: the stream fell too far behind the process's output"))
                    return false
                case .terminated: return false
                @unknown default: return true
                }
            }
            if case .exit = event {
                finishedAt = .now
                for continuation in subscribers { continuation.finish() }
                subscribers = []
            }
        }
    }

    /// Everything kept so far, then live events until the exit.
    func subscribe() -> AsyncThrowingStream<Event, any Error> {
        lock.withLock {
            let (stream, continuation) = AsyncThrowingStream<Event, any Error>.makeStream(
                bufferingPolicy: .bufferingOldest(backlog.count + Self.lagLimit))
            for event in backlog { continuation.yield(event) }
            if finishedAt != nil {
                continuation.finish()
            } else {
                subscribers.append(continuation)
            }
            return stream
        }
    }

    private static func size(_ event: Event) -> Int {
        switch event {
        case .stdout(let data), .stderr(let data): return data.count
        case .exit: return 0
        }
    }

    private struct EventWriter: Writer {
        let output: ProcessOutput
        let stderr: Bool

        func write(_ data: Data) throws {
            guard !data.isEmpty else { return }
            output.append(stderr ? .stderr(data) : .stdout(data))
        }

        func close() throws {}
    }
}

/// A process's stdin fed from `WriteProcessStdin`; finishing it sends EOF.
final class PushedInput: ReaderStream, @unchecked Sendable {
    private let pair = AsyncStream<Data>.makeStream()

    func stream() -> AsyncStream<Data> { pair.stream }

    func write(_ data: Data) {
        if !data.isEmpty { pair.continuation.yield(data) }
    }

    func close() { pair.continuation.finish() }
}
