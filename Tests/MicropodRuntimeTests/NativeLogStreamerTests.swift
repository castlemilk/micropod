import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The native log follow loop without a live runtime: log sources are temp
/// files (the apiserver hands out regular-file fds too) and the running
/// state comes from a scripted probe.
final class NativeLogStreamerTests: XCTestCase {

    private var logURL: URL!

    override func setUpWithError() throws {
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-log-\(UUID().uuidString).log")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logURL)
    }

    /// Bytes the runtime writes between the last drain and the moment the
    /// follow loop observes the container stopped must still be delivered.
    func testFinalDrainCapturesLateBytes() async throws {
        try append("one\ntwo\n")
        let url = logURL!
        let probe = StateProbe(runningCalls: 2) {
            try? Self.append("tail\nno-newline", to: url)
        }

        let result = try await collect(streamer(probe: probe).stream(id: "job"), timeout: .seconds(5))

        XCTAssertTrue(result.finished, "the stream ends once the container is observed stopped")
        XCTAssertEqual(
            result.lines, ["one", "two", "tail", "no-newline"],
            "late bytes, including an unterminated final line, survive the stop")
        let calls = await probe.calls
        XCTAssertEqual(calls, 3)
    }

    /// Review focus: a container that stopped before the stream opened
    /// returns its full backlog and a clean end, not a hang or an error.
    func testStoppedBeforeStreamReturnsBacklogAndEnds() async throws {
        try append("first\nsecond\nthird\n")
        let probe = StateProbe(runningCalls: 0)

        let started = ContinuousClock.now
        let result = try await collect(streamer(probe: probe).stream(id: "job"), timeout: .seconds(5))

        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.lines, ["first", "second", "third"])
        XCTAssertLessThan(
            ContinuousClock.now - started, .seconds(1),
            "the first state check is due immediately after the backlog")
    }

    /// A recorded exit code is the stop signal: the stream ends even though
    /// the runtime still reports the container running.
    func testRegistryEntryEndsStream() async throws {
        try append("backlog\n")
        let url = logURL!
        let registry = ExitCodeRegistry()
        await registry.track(id: "job") {
            try await Task.sleep(for: .milliseconds(100))
            try Self.append("live\n", to: url)
            try await Task.sleep(for: .milliseconds(100))
            return 0
        }
        let probe = StateProbe(runningCalls: .max)

        let started = ContinuousClock.now
        let result = try await collect(
            streamer(probe: probe, exitCodes: registry).stream(id: "job"), timeout: .seconds(3))

        XCTAssertTrue(result.finished, "the registry entry must end the stream")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(result.lines, ["backlog", "live"])
    }

    /// The recorded exit wakes the follow loop at once rather than at its
    /// next drain tick, and the lines written just before the exit are
    /// still delivered by the final drain.
    func testRecordedExitEndsStreamPromptlyWithLateLines() async throws {
        try append("backlog\n")
        let url = logURL!
        let registry = ExitCodeRegistry()
        let exitAt = ExitMark()
        await registry.track(id: "job") {
            try await Task.sleep(for: .milliseconds(300))
            try Self.append("late-1\nlate-2\n", to: url)
            await exitAt.mark()
            return 0
        }
        let probe = StateProbe(runningCalls: .max)

        let result = try await collect(
            streamer(probe: probe, exitCodes: registry).stream(id: "job"), timeout: .seconds(3))
        let ended = ContinuousClock.now

        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.lines, ["backlog", "late-1", "late-2"])
        let recorded = await exitAt.instant
        let exited = try XCTUnwrap(recorded)
        XCTAssertLessThan(
            ended - exited, .milliseconds(40), "the exit signal, not the 80 ms tick, ends the stream")
    }

    /// An exit recorded before the stream opened ends it right after the
    /// backlog, without waiting a tick.
    func testExitRecordedBeforeStreamEndsWithoutATick() async throws {
        try append("only\n")
        let registry = ExitCodeRegistry()
        await registry.track(id: "job") { 0 }
        _ = await registry.await(id: "job", timeout: .seconds(2))
        let probe = StateProbe(runningCalls: .max)

        let started = ContinuousClock.now
        let result = try await collect(
            streamer(probe: probe, exitCodes: registry).stream(id: "job"), timeout: .seconds(3))

        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.lines, ["only"])
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(60))
        let calls = await probe.calls
        XCTAssertEqual(calls, 0, "the registry answers; the runtime is not asked")
    }

    /// An entry without an exit code (the waiter aged out or failed) says
    /// nothing about the container — the runtime state stays authoritative.
    func testUnknownExitCodeEntryDefersToRuntimeState() async throws {
        try append("line\n")
        let registry = ExitCodeRegistry(ceiling: .milliseconds(20))
        await registry.track(id: "job") {
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        let entry = await registry.await(id: "job", timeout: .seconds(2))
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.exitCode)
        let probe = StateProbe(runningCalls: 1)

        let result = try await collect(
            streamer(probe: probe, exitCodes: registry).stream(id: "job"), timeout: .seconds(5))

        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.lines, ["line"])
        let calls = await probe.calls
        XCTAssertEqual(calls, 2, "the stream ends on the runtime's answer, not the unknown entry")
    }

    /// A quiet running container is not polled on every drain tick: state
    /// checks back off 250 ms → 500 ms → 1 s.
    func testQuietStreamBacksOffStateChecks() async throws {
        let probe = StateProbe(runningCalls: .max)

        let result = try await collect(streamer(probe: probe).stream(id: "job"), timeout: .milliseconds(1200))

        XCTAssertFalse(result.finished, "a running container keeps the stream open")
        let calls = await probe.calls
        XCTAssertGreaterThanOrEqual(calls, 1)
        XCTAssertLessThanOrEqual(calls, 4, "80 ms drain ticks must not each ask the runtime (\(calls) checks)")
    }

    /// Empty lines are dropped, and `tail` counts the lines delivered.
    func testTailCountsDeliveredLinesOnly() async throws {
        try append("a\n\nb\n\nc\n\n")
        let probe = StateProbe(runningCalls: 0)

        let result = try await collect(
            streamer(probe: probe).stream(id: "job", tail: 2), timeout: .seconds(5))

        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.lines, ["b", "c"])
    }

    /// Review focus: `stopping` is still live. The runtime enters it before
    /// the graceful stop waits for the process, so ending the stream there
    /// would drop the shutdown output of a cancelled container.
    func testIsLiveTreatsRunningAndStoppingAsLive() {
        XCTAssertTrue(NativeLogStreamer.isLive(state: "running"))
        XCTAssertTrue(
            NativeLogStreamer.isLive(state: "stopping"),
            "the process may still be writing while the runtime stops it")
        XCTAssertFalse(NativeLogStreamer.isLive(state: "stopped"))
        XCTAssertFalse(NativeLogStreamer.isLive(state: "created"))
        XCTAssertFalse(NativeLogStreamer.isLive(state: "unknown"))
        XCTAssertFalse(NativeLogStreamer.isLive(state: ""))
    }

    func testStateCheckScheduleBacksOffAndResetsOnBytes() {
        let start = ContinuousClock.now
        var schedule = NativeLogStreamer.StateCheckSchedule(now: start)
        XCTAssertTrue(schedule.isDue(at: start), "a stopped container ends right after its backlog")

        schedule.stillRunning(at: start)
        XCTAssertFalse(schedule.isDue(at: start + .milliseconds(249)))
        XCTAssertTrue(schedule.isDue(at: start + .milliseconds(250)))

        var now = start + .milliseconds(250)
        for expected in [500, 1000, 1000] {
            schedule.stillRunning(at: now)
            XCTAssertFalse(schedule.isDue(at: now + .milliseconds(expected - 1)))
            XCTAssertTrue(schedule.isDue(at: now + .milliseconds(expected)))
            now += .milliseconds(expected)
        }

        schedule.sawBytes(at: now)
        XCTAssertFalse(schedule.isDue(at: now + .milliseconds(249)))
        XCTAssertTrue(schedule.isDue(at: now + .milliseconds(250)), "bytes reset the backoff")
        schedule.stillRunning(at: now + .milliseconds(250))
        XCTAssertTrue(schedule.isDue(at: now + .milliseconds(750)))
    }

    // MARK: - Helpers

    private func streamer(probe: StateProbe, exitCodes: ExitCodeRegistry? = nil) -> NativeLogStreamer {
        let url = logURL!
        return NativeLogStreamer(
            sourceProvider: { _, _ in [try FileHandle(forReadingFrom: url)] },
            isLive: { _ in await probe.isLive() },
            exitCodes: exitCodes)
    }

    private func append(_ text: String) throws {
        try Self.append(text, to: logURL)
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Consumes `stream` until it finishes on its own or `timeout` elapses;
    /// `finished` is false when the timeout cut it off.
    private func collect(
        _ stream: AsyncThrowingStream<LogLine, Error>, timeout: Duration
    ) async throws -> (lines: [String], finished: Bool) {
        let sink = LineSink()
        let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await line in stream { await sink.append(line.text) }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        return (await sink.lines, finished)
    }
}

/// Scripted runtime state: the first `runningCalls` checks answer running;
/// the next runs `beforeStop` (once), then every check answers stopped.
private actor StateProbe {
    private let runningCalls: Int
    private var beforeStop: (@Sendable () -> Void)?
    private(set) var calls = 0

    init(runningCalls: Int, beforeStop: (@Sendable () -> Void)? = nil) {
        self.runningCalls = runningCalls
        self.beforeStop = beforeStop
    }

    func isLive() -> Bool {
        calls += 1
        if calls <= runningCalls { return true }
        beforeStop?()
        beforeStop = nil
        return false
    }
}

private actor LineSink {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

private actor ExitMark {
    private(set) var instant: ContinuousClock.Instant?
    func mark() { instant = .now }
}
