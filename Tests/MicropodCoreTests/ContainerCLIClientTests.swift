import Darwin
import XCTest

@testable import MicropodCore

final class ContainerCLIClientTests: XCTestCase {
    /// Metrics labels must be low-cardinality: verb (+ grouped sub-verb)
    /// only — never container names, ids, or flag values.
    func testMetricLabelStripsArguments() {
        XCTAssertEqual(
            ContainerCommand(arguments: ["create", "--name", "web", "alpine"]).metricLabel,
            "create")
        XCTAssertEqual(
            ContainerCommand(arguments: ["list", "--all", "--format", "json"]).metricLabel,
            "list")
        XCTAssertEqual(
            ContainerCommand(arguments: ["image", "list", "--format", "json"]).metricLabel,
            "image list")
        XCTAssertEqual(
            ContainerCommand(arguments: ["system", "start", "--disable-kernel-install"])
                .metricLabel,
            "system start")
        XCTAssertEqual(
            ContainerCommand(arguments: ["inspect", "bench-abc123"]).metricLabel,
            "inspect")
        XCTAssertEqual(
            ContainerCommand(arguments: ["image"]).metricLabel, "image")
    }

    func testPreCancelledRunDoesNotSpawnProcess() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-pre-cancelled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.run(
                ContainerCommand(
                    arguments: ["-c", "touch \"$1\"", "micropod-test", markerURL.path]))
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "A pre-cancelled run must not spawn the process")
    }

    func testCancelledControllerDoesNotLaunchShellSideEffect() throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-cancelled-controller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "touch \"$1\"", "micropod-test", markerURL.path]

        let controller = ProcessCancellationController()
        controller.cancel()

        XCTAssertThrowsError(try controller.launch(process)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "Cancellation must close the spawn gate before launching the shell")
    }

    func testCompletedProcessIsNotClassifiedAsCancelled() throws {
        let controller = ProcessCancellationController()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try controller.launch(process)
        process.waitUntilExit()

        // Model cancellation arriving after the worker has already observed a
        // natural exit but before it publishes the result.
        controller.cancel()

        XCTAssertFalse(controller.shouldCancel(process))
        XCTAssertEqual(
            controller.outcome(
                exitCode: process.terminationStatus,
                cancelledWhileRunning: false,
                timedOut: false),
            .exited(0))
    }

    func testCancellingRunTerminatesProcessPromptly() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-run-ready-\(UUID().uuidString)")
        let pidURL = directoryURL.appendingPathComponent("pid")
        let readyURL = directoryURL.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let task = Task {
            try await client.run(
                ContainerCommand(
                    arguments: [
                        "-c",
                        "echo $$ > \"$1\"; touch \"$2\"; exec /bin/sleep 2",
                        "micropod-test",
                        pidURL.path,
                        readyURL.path,
                    ]))
        }
        let processIsReady = try await waitForFile(at: readyURL, timeout: .seconds(1))
        XCTAssertTrue(processIsReady)

        let fallbackKiller = Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(1_100))
            } catch {
                return
            }
            killProcess(recordedAt: pidURL)
        }
        var needsCleanup = true
        defer {
            fallbackKiller.cancel()
            if needsCleanup { killProcess(recordedAt: pidURL) }
        }

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        needsCleanup = false
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1))
    }

    func testCancellingRunForceKillsProcessThatIgnoresTermination() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-term-ignore-\(UUID().uuidString)")
        let pidURL = directoryURL.appendingPathComponent("pid")
        let readyURL = directoryURL.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let task = Task {
            try await client.run(
                ContainerCommand(
                    arguments: [
                        "-c",
                        "trap '' TERM; echo $$ > \"$1\"; touch \"$2\"; while :; do :; done",
                        "micropod-test",
                        pidURL.path,
                        readyURL.path,
                    ]),
                timeout: .seconds(5))
        }

        let processIsReady = try await waitForFile(at: readyURL, timeout: .seconds(1))
        XCTAssertTrue(processIsReady)

        // Keep regressions bounded by forcing cleanup after the prompt-cancellation
        // budget has elapsed.
        let fallbackKiller = Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(1_100))
            } catch {
                return
            }
            killProcess(recordedAt: pidURL)
        }
        defer { fallbackKiller.cancel() }

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1))
    }

    func testCancellingStreamForceKillsProcessThatIgnoresTermination() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-stream-term-ignore-\(UUID().uuidString)")
        let pidURL = directoryURL.appendingPathComponent("pid")
        let readyURL = directoryURL.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let stream = client.stream(
            ContainerCommand(
                arguments: [
                    "-c",
                    "trap '' TERM; echo $$ > \"$1\"; touch \"$2\"; while :; do :; done",
                    "micropod-test",
                    pidURL.path,
                    readyURL.path,
                ]))
        let consumer = Task {
            for try await _ in stream {}
        }

        let processIsReady = try await waitForFile(at: readyURL, timeout: .seconds(1))
        XCTAssertTrue(processIsReady)

        // Bound the RED path so the TERM-ignoring fixture never leaks.
        let fallbackKiller = Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(1_100))
            } catch {
                return
            }
            killProcess(recordedAt: pidURL)
        }
        var needsCleanup = true
        defer {
            fallbackKiller.cancel()
            if needsCleanup { killProcess(recordedAt: pidURL) }
        }

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        consumer.cancel()

        do {
            try await consumer.value
        } catch is CancellationError {
            // Expected when cancellation wins stream completion.
        } catch {
            XCTFail("Expected clean completion or CancellationError, got \(error)")
        }
        let processExited = try await waitForProcessExit(
            recordedAt: pidURL, timeout: .milliseconds(1_300))
        needsCleanup = !processExited
        XCTAssertTrue(processExited)
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1))
    }

    func testPreCancelledStreamDoesNotSpawnProcess() async {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropod-pre-cancelled-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return client.stream(
                ContainerCommand(
                    arguments: ["-c", "touch \"$1\"", "micropod-test", markerURL.path]))
        }

        let stream = await task.value
        do {
            for try await _ in stream {}
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "A pre-cancelled stream must not spawn the process")
    }

    /// Output a process writes just before it exits reaches the consumer
    /// before the stream finishes. The exit can be observed before the last
    /// pipe reads are delivered; the CLI prints its error at exit, and
    /// `ImageService.pull` reads that line to decide whether to retry.
    /// Many short processes at once make the late delivery likely.
    func testStreamYieldsOutputWrittenJustBeforeExit() async throws {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let command = ContainerCommand(arguments: ["-c", "echo first; echo 'Error: last' >&2; exit 1"])
        var incomplete: [String] = []
        for _ in 0..<3 {
            let outputs = await withTaskGroup(of: String.self) { group in
                for _ in 0..<150 {
                    group.addTask {
                        var text = ""
                        do {
                            for try await chunk in client.stream(command, reportExitCode: true) {
                                text += String(decoding: chunk, as: UTF8.self)
                            }
                        } catch MicropodError.cliFailure {
                        } catch {
                            return "unexpected error: \(error)"
                        }
                        return text
                    }
                }
                var all: [String] = []
                for await text in group { all.append(text) }
                return all
            }
            incomplete += outputs.filter { !($0.contains("first") && $0.contains("Error: last")) }
        }
        XCTAssertEqual(incomplete.count, 0, "streams that lost output: \(incomplete.prefix(5))")
    }

    /// A stream finishes promptly once its process has exited and closed
    /// its output — the drain adds no fixed delay.
    func testStreamFinishesPromptlyAfterExit() async throws {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<5 {
            for try await _ in client.stream(ContainerCommand(arguments: ["-c", "echo done"])) {}
        }
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(1_500))
    }

    private func waitForFile(at url: URL, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func waitForProcessExit(recordedAt url: URL, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !processIsRunning(recordedAt: url) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return !processIsRunning(recordedAt: url)
    }
}

private func killProcess(recordedAt url: URL) {
    guard let pid = recordedPID(at: url) else { return }
    Darwin.kill(pid, SIGKILL)
}

private func processIsRunning(recordedAt url: URL) -> Bool {
    guard let pid = recordedPID(at: url) else { return false }
    errno = 0
    return Darwin.kill(pid, 0) == 0 || errno != ESRCH
}

private func recordedPID(at url: URL) -> pid_t? {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
}
