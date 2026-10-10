import Foundation
import XCTest

@testable import MicropodCore

final class ImagePullFailureTests: XCTestCase {
    func testClassificationAndStructuredReceiptNeverPublishOpaqueValues() {
        var evidence = ImagePullEvidence()
        let events = evidence.consume(
            Data(
                "[1/2] Fetching image 42% https://user:fake-secret@example.test/?token=fake-secret\nError: HTTP status 503 https://example.test/?signature=fake-secret\nAuthorization: Bearer fake-secret\n"
                    .utf8))
        XCTAssertEqual(events.map(\.line), ["[1/2] Fetching image 42%"])
        XCTAssertEqual(evidence.failure.category, .transientRegistry)
        XCTAssertEqual(evidence.failure.httpStatus, 503)
        XCTAssertTrue(evidence.failure.retryAllowed)
        XCTAssertFalse(evidence.failure.message.contains("fake-secret"))
        XCTAssertFalse(evidence.failure.message.contains("example.test"))
        let error = MicropodError.cliFailure(
            command: "container image pull", exitCode: 29, stderr: evidence.failure.message)
        XCTAssertEqual(ImagePullFailure.from(error), evidence.failure)
        XCTAssertTrue(error.localizedDescription.contains("\"retryAllowed\":true"))
    }

    func testPermanentAndUnknownErrorsDominateTransientMarkersInEitherOrder() {
        for first in [
            "Error: unauthorized", "Error: no space left on device", "Error: opaque failure",
            "Error: HTTP status 503 credential rejected", "Error: HTTP status 503 errno=28",
        ] {
            for lines in [
                first + "\nError: connection reset by peer\n", "Error: connection reset by peer\n" + first + "\n",
            ] {
                var evidence = ImagePullEvidence()
                _ = evidence.consume(Data(lines.utf8))
                XCTAssertFalse(evidence.failure.retryAllowed)
            }
        }
    }

    func testUnpackAndOversizedLinesCannotAuthorizeRetry() {
        for input in [
            "[2/2] Unpacking image 20%\nError: connection reset by peer\n",
            String(repeating: "x", count: 16384) + "\nError: HTTP status 503\n",
        ] {
            var evidence = ImagePullEvidence()
            _ = evidence.consume(Data(input.utf8))
            XCTAssertFalse(evidence.failure.retryAllowed)
        }
    }

    func testOpaqueTransientWordsAndBareHTTPNumbersAreNotEvidence() {
        for line in [
            "Error: token=connection reset by peer", "Error: payload=http status 503", "HTTP status 503",
            "Error: request id 503",
        ] {
            var evidence = ImagePullEvidence()
            _ = evidence.consume(Data((line + "\n").utf8))
            XCTAssertEqual(evidence.failure.category, .unknown)
            XCTAssertFalse(evidence.failure.retryAllowed)
        }
    }

    func testSplitBytesAndFinalUnterminatedErrorAreObserved() {
        var evidence = ImagePullEvidence()
        _ = evidence.consume(Data("Error: connection ".utf8))
        _ = evidence.consume(Data("reset by peer".utf8))
        _ = evidence.finish()
        XCTAssertEqual(evidence.failure.category, .transientNetwork)
        XCTAssertTrue(evidence.failure.retryAllowed)
    }

    func testNumericProgressSurvivesRedactionWithoutTickerOrRateNoise() {
        var evidence = ImagePullEvidence()
        let inputs = [
            "[1/2] Fetching image 48% (13 of 21 blobs, 17.0/34.9 MB, 12.8 MB/s) [7s]",
            "[1/2] Fetching image 48% (13 of 21 blobs, 18.0/34.9 MB, 9.1 MB/s) [8s]",
            "[1/2] Fetching image 48% (13 of 21 blobs, 18.0/34.9 MB, Zero KB/s) [9s]",
            "[2/2] Unpacking image 48% (13 of 21 entries, 18.0 MB) [10s]",
        ]
        let events = inputs.flatMap { evidence.consume(Data(($0 + "\n").utf8)) }
        XCTAssertNotEqual(ImageService.stallMarker(events[0].line), ImageService.stallMarker(events[1].line))
        XCTAssertEqual(ImageService.stallMarker(events[1].line), ImageService.stallMarker(events[2].line))
        XCTAssertTrue(events[3].line.contains("13 of 21 entries, 18.0 MB"))
        XCTAssertFalse(events.contains { $0.line.contains("MB/s") || $0.line.contains("[7s]") })
    }

    func testPlatformMixedWithPermanentOrUnknownFailureNeverWidens() async throws {
        let platform = "Error: invalidArgument: \"unsupported platform linux/arm64\""
        for other in [
            "Error: unauthorized", "Error: no space left on device", "Error: opaque failure",
            "Error: connection reset by peer",
        ] {
            for lines in [platform + "\n" + other, other + "\n" + platform] {
                let fixture = try makeFixture(lines, failures: 100)
                defer { try? FileManager.default.removeItem(at: fixture.directory) }
                let service = ImageService(client: fixture.client, retrySleep: { _ in XCTFail("Must not retry") })
                do {
                    for try await _ in service.pull("fixture/image:1") {}
                    XCTFail("Expected mixed failure")
                } catch { XCTAssertNotEqual(ImagePullFailure.from(error)?.category, .platform) }
                XCTAssertEqual(try calls(fixture), ["image pull"])
            }
        }
    }

    func testOpaqueCounterSuffixIsNotRepublished() {
        var evidence = ImagePullEvidence()
        let events = evidence.consume(
            Data("[1/2] Fetching image 42% https://private.example/?token=(123 of 456 blobs, 7 MB)\n".utf8))
        XCTAssertEqual(events.map(\.line), ["[1/2] Fetching image 42%"])
    }

    func testOpaquePlatformPhraseCannotAuthorizeWidening() async throws {
        let fixture = try makeFixture(
            "Error: invalidArgument: \"invalid reference: unsupported platform\"", failures: 100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ImageService(client: fixture.client, retrySleep: { _ in XCTFail("Must not retry") })
        do {
            for try await _ in service.pull("fixture/image:1") {}
            XCTFail("Expected invalid reference failure")
        } catch { XCTAssertEqual(ImagePullFailure.from(error)?.category, .unknown) }
        XCTAssertEqual(try calls(fixture), ["image pull"])
    }

    func testTransientFetchRetriesWithBoundedBackoffBeforeAnyOtherCommand() async throws {
        let sleeps = PullRetrySleeps()
        let fixture = try makeFixture("Error: connection reset by peer", failures: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ImageService(client: fixture.client, retrySleep: { await sleeps.note($0) })
        var lines: [String] = []
        for try await event in service.pull("fixture/image:1", platform: "linux/arm64") { lines.append(event.line) }
        XCTAssertEqual(try calls(fixture), ["image pull", "image pull", "image pull"])
        let delays = await sleeps.values
        XCTAssertEqual(delays, [.seconds(1), .seconds(2)])
        XCTAssertEqual(lines.filter { $0.hasPrefix("Retrying") }.count, 2)
        XCTAssertEqual(lines.last, "[2/2] Unpacking image 100%")
    }

    func testExhaustedTransientFailurePreservesActualExitAndStopsAtThreeAttempts() async throws {
        let fixture = try makeFixture("Error: HTTP status 503", failures: 100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ImageService(client: fixture.client, retrySleep: { _ in })
        do {
            for try await _ in service.pull("fixture/image:1", platform: "linux/arm64") {}
            XCTFail("Expected bounded pull failure")
        } catch MicropodError.cliFailure(let command, let code, let detail) {
            XCTAssertEqual(command, "container image pull")
            XCTAssertEqual(code, 29)
            XCTAssertEqual(
                ImagePullFailure.from(MicropodError.cliFailure(command: command, exitCode: code, stderr: detail))?
                    .httpStatus, 503)
        }
        XCTAssertEqual(try calls(fixture).count, 3)
    }

    func testAuthenticationStorageTLSUnknownAndRateLimitsStopWithoutRegistryCommands() async throws {
        for line in [
            "Error: unauthorized token=fake-secret", "Error: no space left on device",
            "Error: certificate verification failed", "Error: opaque failure", "Error: HTTP status 429",
        ] {
            let fixture = try makeFixture(line, failures: 100)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let service = ImageService(client: fixture.client, retrySleep: { _ in XCTFail("Must not retry") })
            do {
                for try await _ in service.pull("fixture/image:1", platform: "linux/arm64") {}
                XCTFail("Expected permanent or unknown failure")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("fake-secret"))
                XCTAssertFalse(ImagePullFailure.from(error)?.retryAllowed ?? true)
            }
            XCTAssertEqual(try calls(fixture), ["image pull"])
        }
    }

    func testCancellationDuringBackoffPreventsAnotherPull() async throws {
        let fixture = try makeFixture("Error: connection timed out", failures: 100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ImageService(client: fixture.client, retrySleep: { _ in throw CancellationError() })
        do {
            for try await _ in service.pull("fixture/image:1", platform: "linux/arm64") {}
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try calls(fixture), ["image pull"])
    }

    func testPreCancelledPullDoesNotInvokeCLI() async throws {
        let fixture = try makeFixture("Error: connection timed out", failures: 100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ImageService(client: fixture.client, retrySleep: { _ in XCTFail("Must not retry") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                for try await _ in service.pull("fixture/image:1", platform: "linux/arm64") {}
            } catch is CancellationError {}
        }
        try await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("calls").path))
    }

    private struct Fixture {
        let directory: URL
        let client: ContainerCLIClient
    }

    private func makeFixture(_ errorLine: String, failures: Int) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pull-diagnostic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let trace = directory.appendingPathComponent("calls").path
        let literal = errorLine.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = """
            #!/bin/bash
            echo "$1 $2" >> "\(trace)"
            count=$(wc -l < "\(trace)")
            if [ "$count" -le \(failures) ]; then
              printf '%s\\n' '\(literal)'
              exit 29
            fi
            echo '[2/2] Unpacking image 100%'
            """
        let executable = directory.appendingPathComponent("mock-container")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return Fixture(directory: directory, client: ContainerCLIClient(executableURL: executable))
    }

    private func calls(_ fixture: Fixture) throws -> [String] {
        try String(contentsOf: fixture.directory.appendingPathComponent("calls"), encoding: .utf8).split(
            separator: "\n"
        ).map(String.init)
    }
}

private actor PullRetrySleeps {
    var values: [Duration] = []
    func note(_ duration: Duration) { values.append(duration) }
}
