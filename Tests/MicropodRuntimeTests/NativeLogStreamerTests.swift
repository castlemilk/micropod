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
    ///
    /// The exit lands at four phases 20 ms apart across one 80 ms tick, so
    /// a plain-sleep tick ends at least one of these streams 60 ms or more
    /// after its exit, whatever the tick alignment.
    func testRecordedExitEndsStreamPromptlyWithLateLines() async throws {
        for delay in [250, 270, 290, 310] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("native-log-\(UUID().uuidString).log")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            defer { try? FileManager.default.removeItem(at: url) }
            try Self.append("backlog\n", to: url)
            let registry = ExitCodeRegistry()
            let exitAt = ExitMark()
            await registry.track(id: "job") {
                try await Task.sleep(for: .milliseconds(delay))
                try Self.append("late-1\nlate-2\n", to: url)
                await exitAt.mark()
                return 0
            }
            let probe = StateProbe(runningCalls: .max)

            let result = try await collect(
                streamer(probe: probe, exitCodes: registry, url: url).stream(id: "job"),
                timeout: .seconds(3))
            let ended = ContinuousClock.now

            XCTAssertTrue(result.finished, "exit after \(delay) ms")
            XCTAssertEqual(result.lines, ["backlog", "late-1", "late-2"], "exit after \(delay) ms")
            let recorded = await exitAt.instant
            let exited = try XCTUnwrap(recorded)
            XCTAssertLessThan(
                ended - exited, .milliseconds(40),
                "exit after \(delay) ms: the exit signal, not the 80 ms tick, ends the stream")
        }
    }

    /// A registry entry without a code never wakes a parked tick, so the
    /// follow loop must fall back to the plain 80 ms tick for it rather than
    /// return from the registry at once and spin until the next state check.
    func testUnknownExitCodeEntryKeepsTheTickCadence() async throws {
        let registry = ExitCodeRegistry(ceiling: .milliseconds(20))
        await registry.track(id: "job") {
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        _ = await registry.await(id: "job", timeout: .seconds(2))
        let probe = StateProbe(runningCalls: .max)
        let ticks = TickCounter()

        let result = try await collect(
            streamer(probe: probe, exitCodes: registry, onTick: { ticks.increment() }).stream(id: "job"),
            timeout: .milliseconds(480))

        XCTAssertFalse(result.finished, "the runtime still reports the container running")
        let count = ticks.value
        XCTAssertGreaterThanOrEqual(count, 3)
        XCTAssertLessThanOrEqual(count, 8, "480 ms at 80 ms ticks, not a spin (\(count) ticks)")
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

    /// A runtime that fails to answer (a busy apiserver) is not a stop
    /// signal: the stream keeps following through unknown answers and
    /// still delivers what the container writes after them.
    func testUnknownLivenessKeepsFollowing() async throws {
        let url = logURL!
        try append("before\n")
        let answers = LivenessScript([.unknown, .unknown, .unknown, .live], then: .stopped) {
            try? Self.append("after\n", to: url)
        }
        let streamer = NativeLogStreamer(
            sourceProvider: { _, _ in [try FileHandle(forReadingFrom: url)] },
            liveness: { _ in await answers.next() })
        let result = try await collect(streamer.stream(id: "job"), timeout: .seconds(10))
        XCTAssertTrue(result.finished, "the stream must end once the runtime says stopped")
        XCTAssertEqual(result.lines, ["before", "after"])
    }

    /// A runtime that stays silent fails the stream: a clean end would
    /// claim every line was sent while the container may still be writing.
    func testPersistentUnknownLivenessFailsTheStream() async throws {
        try append("only\n")
        let url = logURL!
        let streamer = NativeLogStreamer(
            sourceProvider: { _, _ in [try FileHandle(forReadingFrom: url)] },
            liveness: { _ in .unknown },
            unknownLivenessLimit: .milliseconds(300))
        var lines: [String] = []
        do {
            for try await line in streamer.stream(id: "job") { lines.append(line.text) }
            XCTFail("a stream whose liveness is never known must not end cleanly")
        } catch {
            XCTAssertTrue("\(error)".contains("has not answered"), "error = \(error)")
        }
        XCTAssertEqual(lines, ["only"])
    }

    // MARK: - Helpers

    private func streamer(
        probe: StateProbe, exitCodes: ExitCodeRegistry? = nil, url: URL? = nil,
        onTick: @escaping @Sendable () -> Void = {}
    ) -> NativeLogStreamer {
        let url = url ?? logURL!
        return NativeLogStreamer(
            sourceProvider: { _, _ in [try FileHandle(forReadingFrom: url)] },
            isLive: { _ in await probe.isLive() },
            exitCodes: exitCodes,
            onTick: onTick)
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

/// Scripted liveness answers; `beforeStop` runs once before the first
/// `then` answer, so bytes it writes land before the final drain.
private actor LivenessScript {
    private var answers: [NativeLogStreamer.Liveness]
    private let then: NativeLogStreamer.Liveness
    private var beforeStop: (@Sendable () -> Void)?

    init(
        _ answers: [NativeLogStreamer.Liveness], then: NativeLogStreamer.Liveness,
        beforeStop: (@Sendable () -> Void)? = nil
    ) {
        self.answers = answers
        self.then = then
        self.beforeStop = beforeStop
    }

    func next() -> NativeLogStreamer.Liveness {
        if !answers.isEmpty { return answers.removeFirst() }
        beforeStop?()
        beforeStop = nil
        return then
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

/// Counts follow-loop ticks from the streamer's synchronous tick hook.
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
