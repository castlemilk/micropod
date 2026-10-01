import Foundation
import XCTest

@testable import MicropodCore

final class StreamingTextDecoderTests: XCTestCase {
    func testEveryUTF8ChunkBoundaryPreservesUnicodeAndGraphemes() {
        let expected = "hello 👩🏽‍💻 café e\u{301} 中文\n"
        let data = Data(expected.utf8)
        for boundary in 0...data.count {
            var decoder = StreamingUTF8Decoder()
            let actual =
                decoder.decode(data.prefix(boundary)) + decoder.decode(data.dropFirst(boundary))
                + decoder.finish()
            XCTAssertEqual(actual, expected, "boundary \(boundary)")
        }
        var decoder = StreamingUTF8Decoder()
        let oneByteReads = data.map { decoder.decode(Data([$0])) }.joined() + decoder.finish()
        XCTAssertEqual(oneByteReads, expected)
    }

    func testIncompleteInvalidUTF8IsReplacedOnlyAtEOF() {
        var decoder = StreamingUTF8Decoder()
        XCTAssertEqual(decoder.decode(Data([0xF0, 0x9F])), "")
        XCTAssertEqual(decoder.finish(), "�")
        XCTAssertEqual(decoder.decode(Data("next".utf8)), "next")
    }

    func testANSIControlsAcrossEveryReadBoundary() {
        let source =
            "\u{1B}[31mred\u{1B}[0m café\u{1B}]0;window title\u{7} 👩🏽‍💻\u{1B}]8;;url\u{1B}\\link\u{1B}]8;;\u{1B}\\"
        let expected = "red café 👩🏽‍💻link"
        let bytes = Data(source.utf8)
        for boundary in 0...bytes.count {
            var decoder = StreamingUTF8Decoder()
            var filter = StreamingANSITextFilter()
            let first = filter.filter(decoder.decode(bytes.prefix(boundary)))
            let second = filter.filter(decoder.decode(bytes.dropFirst(boundary)))
            XCTAssertEqual(first + second + filter.filter(decoder.finish()), expected)
        }
    }

    func testPartialLogLineHasABoundedVisiblePrefixAndResetsAtNewline() {
        var buffer = BoundedLogLineAccumulator()
        for _ in 0..<10_000 { XCTAssertTrue(buffer.append("abcdefgh").isEmpty) }
        let lines = buffer.append("\nnext\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" … [line truncated at 16 KiB]"))
        XCTAssertLessThanOrEqual(lines[0].utf8.count, 16 * 1024 + 64)
        XCTAssertEqual(lines[1], "next")
        XCTAssertNil(buffer.finish())
    }

    func testLogStreamReassemblesSplitUTF8AndFlushesPartialEOF() async throws {
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            for byte in "one 👩🏽‍💻\ntwo café".utf8 { continuation.yield(Data([byte])) }
            continuation.finish()
        }
        var lines: [String] = []
        for try await line in LogStreamer.lines(chunks) { lines.append(line.text) }
        XCTAssertEqual(lines, ["one 👩🏽‍💻", "two café"])
    }

    func testSaturatedLogQueuePreservesEveryLineInOrderUnderBackpressure() async throws {
        let expected = (0..<20_000).map { "line \($0)" }
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data((expected.joined(separator: "\n") + "\n").utf8))
            continuation.finish()
        }
        let lines = LogStreamer.lines(chunks)
        // Deliberately withhold consumption while the bounded queue fills.
        try await Task.sleep(for: .milliseconds(50))
        var retained: [LogLine] = []
        for try await line in lines { retained.append(line) }
        XCTAssertEqual(retained.map(\.text), expected)
        XCTAssertTrue(retained.allSatisfy { $0.upstreamDiscardedLines == 0 })
    }

    func testCancellingLogConsumerAwaitingNextCancelsRawSource() async throws {
        let terminated = expectation(description: "raw log source cancelled")
        let backlogDrained = expectation(description: "backpressured backlog delivered")
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { _ in terminated.fulfill() }
            continuation.yield(Data(String(repeating: "log line\n", count: 20_000).utf8))
        }
        let lines = LogStreamer.lines(chunks)
        let consumer = Task {
            var count = 0
            for try await _ in lines {
                count += 1
                if count == 20_000 { backlogDrained.fulfill() }
            }
        }
        // Cancellation while awaiting the next line is the stream's supported
        // consumer cancellation boundary, including after bounded backlog flow.
        await fulfillment(of: [backlogDrained], timeout: 5)
        consumer.cancel()
        _ = try? await consumer.value
        await fulfillment(of: [terminated], timeout: 2)
    }
}
