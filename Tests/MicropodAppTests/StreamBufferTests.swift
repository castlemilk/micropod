import Foundation
import MicropodCore
import XCTest

@testable import MicropodApp

final class StreamBufferTests: XCTestCase {
    func testLogRingRetainsLatestRowsWithinBothBudgets() {
        var buffer = BoundedLogRenderBuffer(lineLimit: 1000, byteLimit: 4096)
        for index in 0..<100_000 {
            buffer.append(LogLine(text: "line \(index): " + String(repeating: "x", count: 100)))
        }
        let snapshot = buffer.snapshot
        XCTAssertLessThanOrEqual(snapshot.retainedBytes, 4096)
        XCTAssertLessThanOrEqual(snapshot.lines.count, 1000)
        XCTAssertEqual(snapshot.lines.last?.text, "line 99999: " + String(repeating: "x", count: 100))
        XCTAssertEqual(snapshot.discardedLines + snapshot.lines.count, 100_000)
    }

    func testLogRingOrderingAcrossWrapAndUpstreamDiscardCounter() {
        var buffer = BoundedLogRenderBuffer(lineLimit: 3)
        for index in 0..<10 { buffer.append(LogLine(text: "\(index)", upstreamDiscardedLines: 5)) }
        XCTAssertEqual(buffer.snapshot.lines.map(\.text), ["7", "8", "9"])
        XCTAssertEqual(buffer.snapshot.discardedLines, 12)
    }

    func testGiantNativeLogRowsAreVisiblyCappedWithoutChangingIdentity() {
        let original = LogLine(text: String(repeating: "👩🏽‍💻 café ", count: 100_000))
        var buffer = BoundedLogRenderBuffer()
        buffer.append(original)
        let snapshot = buffer.snapshot
        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(snapshot.lines.first?.id, original.id)
        XCTAssertEqual(snapshot.lines.first?.timestamp, original.timestamp)
        XCTAssertLessThanOrEqual(snapshot.retainedBytes, 16 * 1024)
        XCTAssertTrue(snapshot.lines.first?.text.hasSuffix("[display truncated at 16 KiB]") == true)
        XCTAssertFalse(snapshot.lines.first?.text.contains("�") == true)
        XCTAssertEqual(snapshot.truncatedLines, 1)
        XCTAssertGreaterThan(original.text.utf8.count, snapshot.retainedBytes)
    }

    func testTerminalRetentionRemainsBoundedUnderManySmallChunks() {
        var buffer = BoundedTerminalRenderBuffer(byteLimit: 8192)
        for index in 0..<100_000 { buffer.append(Data("\(index)\n".utf8)) }
        buffer.finish()
        let snapshot = buffer.snapshot
        XCTAssertLessThanOrEqual(snapshot.text.utf8.count, 8192)
        XCTAssertEqual(buffer.retainedBytes, snapshot.text.utf8.count)
        XCTAssertGreaterThan(snapshot.discardedBytes, 0)
        XCTAssertTrue(snapshot.text.hasSuffix("99999\n"))
    }

    func testTerminalGiantChunkTrimKeepsWholeGraphemes() {
        var buffer = BoundedTerminalRenderBuffer(byteLimit: 256)
        let grapheme = "👩🏽‍💻"
        buffer.append(Data(String(repeating: grapheme, count: 1000).utf8))
        buffer.finish()
        XCTAssertLessThanOrEqual(buffer.snapshot.text.utf8.count, 256)
        XCTAssertEqual(buffer.snapshot.text, String(repeating: grapheme, count: buffer.snapshot.text.count))
        XCTAssertFalse(buffer.snapshot.text.contains("�"))
    }

    func testTerminalANSIAndUTF8SplitReadsRemainCorrect() {
        var buffer = BoundedTerminalRenderBuffer()
        for byte in "\u{1B}[31m👩🏽‍💻 café\u{1B}[0m\n".utf8 { buffer.append(Data([byte])) }
        buffer.finish()
        XCTAssertEqual(buffer.snapshot.text, "👩🏽‍💻 café\n")
    }

    func testBurstCoalescesToOneBoundedFinalSnapshotWithoutWaitingForTimer() async throws {
        let source = AsyncThrowingStream<LogLine, Error> { continuation in
            for index in 0..<20_000 { continuation.yield(LogLine(text: "line \(index)")) }
            continuation.finish()
        }
        let clock = ContinuousClock()
        let start = clock.now
        var snapshots: [LogStreamSnapshot] = []
        for try await snapshot in CoalescedUIStream.snapshots(
            from: source, initial: BoundedLogRenderBuffer(lineLimit: 10), interval: .seconds(30),
            append: { $0.append($1) }, snapshot: { $0.snapshot })
        {
            snapshots.append(snapshot)
        }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.last?.lines.map(\.text), (19_990..<20_000).map { "line \($0)" })
        XCTAssertEqual(snapshots.last?.discardedLines, 19_990)
        XCTAssertLessThan(clock.now - start, .seconds(5))
    }

    func testQuietSourcePublishesWithinOneIntervalWhileSourceRemainsOpen() async throws {
        let (source, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        var iterator = CoalescedUIStream.snapshots(
            from: source, initial: BoundedTerminalRenderBuffer(), interval: .milliseconds(10),
            append: { $0.append($1) }, finish: { $0.finish() }, snapshot: { $0.snapshot }
        ).makeAsyncIterator()
        continuation.yield(Data("first".utf8))
        let first = try await iterator.next()
        XCTAssertEqual(first?.text, "first")
        continuation.yield(Data(" second".utf8))
        let second = try await iterator.next()
        XCTAssertEqual(second?.text, "first second")
        continuation.finish()
        let final = try await iterator.next()
        XCTAssertEqual(final?.text, "first second")
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testCancellationPropagatesToProducerAndPendingPublication() async throws {
        let terminated = expectation(description: "source cancelled")
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { _ in terminated.fulfill() }
            continuation.yield(Data("first".utf8))
        }
        let snapshots = CoalescedUIStream.snapshots(
            from: source, initial: BoundedTerminalRenderBuffer(), interval: .seconds(30),
            append: { $0.append($1) }, snapshot: { $0.snapshot })
        let consumer = Task {
            for try await _ in snapshots {}
        }
        consumer.cancel()
        _ = try? await consumer.value
        await fulfillment(of: [terminated], timeout: 2)
    }
}
