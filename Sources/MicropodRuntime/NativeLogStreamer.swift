import Foundation
import MicropodCore

/// `LogStreaming` backed by the `containerLogs` XPC route, which returns
/// the container's log file handles directly — no `container logs -f`
/// process per stream.
///
/// The fds point at regular files (the apiserver's per-container logs),
/// not pipes: reads hit EOF rather than blocking. `stream` therefore
/// tracks file offsets and polls for growth, finishing once the container
/// leaves the running state — matching `container logs -f` behavior.
public struct NativeLogStreamer: LogStreaming {
    private let api: APIServerClient

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

    public init(api: APIServerClient) {
        self.api = api
    }

    public func tail(id: String, lines: Int = 100, boot: Bool = false) async throws -> [LogLine] {
        var sources = try await sources(id: id, boot: boot)
        var data = Data()
        for i in sources.indices {
            data.append(sources[i].drain())
        }
        let text = String(decoding: data, as: UTF8.self)
        return
            text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .suffix(lines)
            .map { LogLine(text: String($0)) }
    }

    public func stream(id: String, tail: Int? = nil, boot: Bool = false) -> AsyncThrowingStream<
        LogLine, Error
    > {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sources = try await self.sources(id: id, boot: boot)
                    var carry = Data()
                    var backlogDone = false

                    func emitLines(final: Bool = false) {
                        // Split `carry` into complete lines, keep the tail
                        // fragment for the next round.
                        var lines: [Data] = []
                        var start = carry.startIndex
                        for i in carry.startIndex..<carry.endIndex where carry[i] == 0x0A {
                            lines.append(carry[start..<i])
                            start = carry.index(after: i)
                        }
                        let remainder = carry[start...]
                        carry = final ? Data() : Data(remainder)
                        if final, !remainder.isEmpty { lines.append(Data(remainder)) }

                        if !backlogDone {
                            backlogDone = true
                            if let tail {
                                lines = Array(lines.suffix(tail))
                            }
                        }
                        for line in lines where !line.isEmpty {
                            continuation.yield(
                                LogLine(text: String(decoding: line, as: UTF8.self)))
                        }
                    }

                    // First pass: backlog (honoring tail).
                    for i in sources.indices {
                        carry.append(sources[i].drain())
                    }
                    emitLines()

                    // Follow: poll for file growth until the container is
                    // no longer running.
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(80))
                        var fresh = Data()
                        for i in sources.indices {
                            fresh.append(sources[i].drain())
                        }
                        if !fresh.isEmpty {
                            carry.append(fresh)
                            emitLines()
                            continue
                        }
                        if try await !self.isRunning(id: id) {
                            emitLines(final: true)
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `containerLogs` returns [containerLog, bootlog] — index 0 is the
    /// init process's combined stdio (what `container logs` shows),
    /// index 1 is the kernel/vminitd boot log (`container logs --boot`).
    private func sources(id: String, boot: Bool) async throws -> [Source] {
        let handles = try await api.logs(id: id)
        guard handles.indices.contains(boot ? 1 : 0) else {
            throw MicropodError.message("container \(id): missing log fd")
        }
        return [Source(handle: handles[boot ? 1 : 0])]
    }

    private func isRunning(id: String) async throws -> Bool {
        guard let managed = try? await api.managed(id: id),
            case .object(let obj) = managed,
            case .object(let status) = obj["status"],
            case .string(let state) = status["state"]
        else { return false }
        return state == "running"
    }
}
