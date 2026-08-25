import MicropodCore
import XCTest

final class StreamingTests: XCTestCase {
    func testLogStreamerYieldsLinesThenFinishes() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(name: "web")

            var lines: [String] = []
            for try await line in mock.logs.stream(id: id, tail: 5, boot: false) {
                lines.append(line.text)
            }
            XCTAssertFalse(lines.isEmpty)
            XCTAssertTrue(lines.allSatisfy { $0.contains("mock log line") })
        }
    }

    func testLogStreamerResolvesContainerByName() async throws {
        try await withMockServices { mock in
            _ = try await mock.runContainer(name: "web")
            var lines: [String] = []
            for try await line in mock.logs.stream(id: "web", tail: 3, boot: false) {
                lines.append(line.text)
            }
            // `-n 3 --follow` replays 3 buffered lines, then the mock emits one
            // more line for the live-follow tail.
            XCTAssertTrue(lines.count >= 3, "expected at least the 3 tailed lines, got \(lines)")
            XCTAssertTrue(lines.contains { $0.contains("after-follow") })
        }
    }

    func testBuildStreamsProgressAndCreatesImage() async throws {
        try await withMockServices { mock in
            let context = mock.stateDir.appendingPathComponent("build-context")
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try "FROM scratch".write(
                to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

            let request = ContainerBuildRequest(
                contextDirectory: context.path,
                tags: ["hello:latest"])
            var events: [ProgressEvent] = []
            for try await event in mock.images.build(request) { events.append(event) }

            XCTAssertTrue(events.contains { $0.stage == 1 && $0.totalStages == 2 })
            XCTAssertTrue(events.contains { $0.stage == 2 })

            let images = try await mock.images.list()
            XCTAssertTrue(images.contains { $0.names.contains("hello:latest") })
        }
    }
}
