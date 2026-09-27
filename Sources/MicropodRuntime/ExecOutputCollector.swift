import Dispatch
import Foundation
import os

/// Collects a non-TTY exec's stdout and stderr from the read ends of the
/// pipes whose write ends went to the apiserver.
///
/// Reads are event-driven (a `DispatchSourceRead` per pipe) from creation
/// on, so a large output can't fill a pipe and stall the guest. After the
/// process exit, `finish` ends collection on EOF of both pipes — the normal
/// case, milliseconds after the exit. EOF is not guaranteed (a process that
/// inherited a write end keeps the pipe open), so a pipe that stays silent
/// for `quiet` after the exit, or the overall `cap`, also ends it.
final class ExecOutputCollector: Sendable {
    struct Output: Sendable {
        var stdout: Data
        var stderr: Data
    }

    private struct State {
        var output = Output(stdout: Data(), stderr: Data())
        var eof = [false, false]
        var lastEvent = ContinuousClock.now
        /// Bumped on every read event, so a waiter can't miss one that lands
        /// between its check and its suspension.
        var events: UInt64 = 0
        var waiter: CheckedContinuation<Void, Never>?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sources: [any DispatchSourceRead]

    init(stdout: FileHandle, stderr: FileHandle) {
        let queue = DispatchQueue(label: "micropod.exec-output")
        var sources: [any DispatchSourceRead] = []
        for handle in [stdout, stderr] {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            sources.append(DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue))
        }
        self.sources = sources
        for (index, (source, handle)) in zip(sources, [stdout, stderr]).enumerated() {
            // The handler keeps the handle (and so its fd) alive until the
            // source is cancelled and releases it.
            source.setEventHandler { [weak self, unowned source] in
                guard let self else {
                    source.cancel()
                    return
                }
                if self.drain(handle, index: index) { source.cancel() }
            }
            source.activate()
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }

    /// Reads everything ready on the fd; true once it hit EOF (or failed).
    private func drain(_ handle: FileHandle, index: Int) -> Bool {
        let (chunk, ended) = Self.readReady(handle.fileDescriptor)
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.finished else { return nil }
            if index == 0 {
                state.output.stdout.append(chunk)
            } else {
                state.output.stderr.append(chunk)
            }
            if ended { state.eof[index] = true }
            guard !chunk.isEmpty || ended else { return nil }
            state.lastEvent = .now
            state.events &+= 1
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
        return ended
    }

    /// Reads a nonblocking fd until EAGAIN or EOF: the bytes read, and
    /// whether the pipe ended (EOF, or a read error other than EAGAIN).
    private static func readReady(_ fd: Int32) -> (Data, Bool) {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var chunk = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                chunk.append(contentsOf: buffer[0..<n])
                continue
            }
            if n < 0, errno == EINTR { continue }
            return (chunk, n == 0 || errno != EAGAIN)
        }
    }

    /// Call once the process has exited: waits for EOF on both pipes, or
    /// `quiet` without any data after the exit, or `cap` — whichever comes
    /// first — then stops reading and returns everything collected.
    func finish(quiet: Duration, cap: Duration) async -> Output {
        let exited = ContinuousClock.now
        let deadline = exited + cap
        while true {
            let next: (wake: ContinuousClock.Instant, seen: UInt64)? = state.withLock { state in
                if state.eof[0] && state.eof[1] { return nil }
                let wake = min(max(state.lastEvent, exited) + quiet, deadline)
                return ContinuousClock.now >= wake ? nil : (wake, state.events)
            }
            guard let next else { break }
            await waitForEvent(after: next.seen, until: next.wake)
        }
        for source in sources { source.cancel() }
        return state.withLock { state in
            state.finished = true
            return state.output
        }
    }

    /// Suspends until a read event after the `seen`th, or `wake`, whichever
    /// is first.
    private func waitForEvent(after seen: UInt64, until wake: ContinuousClock.Instant) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(until: wake, clock: .continuous)
            guard let self else { return }
            let waiter = self.state.withLock { state in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                // An event already landed, or the timer already fired.
                if state.events != seen || ContinuousClock.now >= wake { return true }
                state.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        timer.cancel()
    }
}
