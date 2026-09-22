import Foundation

/// A single log line for a container.
public struct LogLine: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let timestamp: Date

    public init(id: UUID = UUID(), text: String, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                do {
                    for try await chunk in client.stream(command) {
                        guard let text = String(data: chunk, encoding: .utf8) else { continue }
                        buffer += text
                        var lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
                        if buffer.last == "\n" {
                            buffer = ""
                        } else if let incomplete = lines.popLast() {
                            buffer = String(incomplete)
                        }
                        for line in lines where !line.isEmpty {
                            continuation.yield(LogLine(text: String(line)))
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(LogLine(text: buffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
