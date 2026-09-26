import Foundation
import XCTest

@testable import MicropodCore

/// O13: StreamContainerLogs used to hand the HTTP writer one Connect envelope
/// per log line, and the writer awaits `contentProcessed` for every send —
/// 500k lines cost 500k awaited sends. The coalescer packs whole envelopes
/// into sends of up to `maxBytes`, flushing a partial batch after
/// `maxDelay`, so a flood costs a few hundred sends while every envelope
/// (one LogChunk, one line) stays intact and in order on the wire.
final class StreamFrameCoalescerTests: XCTestCase {

    /// Connect envelope framing (flags byte, big-endian length, payload), the
    /// shape the API mounts in front of the coalescer.
    private static func envelope(_ payload: String) -> Data {
        let bytes = Data(payload.utf8)
        var frame = Data([0])
        var length = UInt32(bytes.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(bytes)
        return frame
    }

    /// Splits a byte run back into envelope payloads; fails on a torn frame.
    private static func payloads(in data: Data) throws -> [String] {
        var out: [String] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard data.endIndex - cursor >= 5 else { throw TornFrame() }
            let length = data[(cursor + 1)..<(cursor + 5)].reduce(0) { $0 << 8 | Int($1) }
            let start = cursor + 5
            guard data.endIndex - start >= length else { throw TornFrame() }
            out.append(String(decoding: data[start..<(start + length)], as: UTF8.self))
            cursor = start + length
        }
        return out
    }

    private struct TornFrame: Error {}

    private static func source(_ frames: [Data]) -> AsyncStream<Data> {
        AsyncStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    func testHundredThousandLinesArriveWholeInOrderInFarFewerSends() async throws {
        let lines = (0..<100_000).map { #"{"text":"line \#($0) of a synthetic flood"}"# }
        let maxBytes = 64 * 1024
        let coalesced = StreamFrameCoalescer.coalesce(
            Self.source(lines.map(Self.envelope)), maxBytes: maxBytes, maxDelay: .milliseconds(10))

        var sends = 0
        var received: [String] = []
        for await chunk in coalesced {
            sends += 1
            XCTAssertLessThanOrEqual(chunk.count, maxBytes, "a batch of small frames must stay under the cap")
            // Every send carries whole envelopes: no line is torn across sends.
            received.append(contentsOf: try Self.payloads(in: chunk))
        }

        XCTAssertEqual(received.count, lines.count)
        XCTAssertEqual(received, lines, "every line, in order")
        // ~48 bytes per envelope → ~1.4k per 64 KiB send → ~75 sends.
        XCTAssertLessThan(sends, 200, "sends must be far fewer than lines, got \(sends)")
    }

    func testFrameLargerThanCapTravelsAloneAndUnsplit() async throws {
        let big = String(repeating: "x", count: 100 * 1024)
        let frames = [Self.envelope("a"), Self.envelope(big), Self.envelope("b")]
        var chunks: [Data] = []
        for await chunk in StreamFrameCoalescer.coalesce(
            Self.source(frames), maxBytes: 64 * 1024, maxDelay: .seconds(5))
        {
            chunks.append(chunk)
        }
        XCTAssertEqual(try chunks.map { try Self.payloads(in: $0) }, [["a"], [big], ["b"]])
    }

    func testPartialBatchFlushesAfterTheDelayWhileTheSourceStaysOpen() async throws {
        let (source, continuation) = AsyncStream<Data>.makeStream()
        var iterator = StreamFrameCoalescer.coalesce(
            source, maxBytes: 64 * 1024, maxDelay: .milliseconds(10)
        ).makeAsyncIterator()

        continuation.yield(Self.envelope("first"))
        continuation.yield(Self.envelope("second"))
        let clock = ContinuousClock()
        let started = clock.now
        let first = await iterator.next()
        XCTAssertEqual(try first.map(Self.payloads(in:)), ["first", "second"])
        XCTAssertLessThan(clock.now - started, .seconds(2), "a quiet stream must not hold lines back")

        // The next batch starts its own timer.
        continuation.yield(Self.envelope("third"))
        let second = await iterator.next()
        XCTAssertEqual(try second.map(Self.payloads(in:)), ["third"])

        continuation.finish()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testSourceEndFlushesTheTailWithoutWaitingForTheTimer() async throws {
        let frames = [Self.envelope("tail-1"), Self.envelope("tail-2"), Self.envelope("{}")]
        let clock = ContinuousClock()
        let started = clock.now
        var chunks: [Data] = []
        for await chunk in StreamFrameCoalescer.coalesce(
            Self.source(frames), maxBytes: 64 * 1024, maxDelay: .seconds(30))
        {
            chunks.append(chunk)
        }
        XCTAssertLessThan(clock.now - started, .seconds(5))
        XCTAssertEqual(chunks.count, 1, "the tail and the trailer leave in one send")
        XCTAssertEqual(try Self.payloads(in: chunks[0]), ["tail-1", "tail-2", "{}"])
    }

    func testDroppingTheCoalescedStreamStopsPullingTheSource() async throws {
        let terminated = expectation(description: "source terminated")
        let source = AsyncStream<Data> { continuation in
            continuation.onTermination = { _ in terminated.fulfill() }
            continuation.yield(Self.envelope("only"))
        }
        do {
            var iterator = StreamFrameCoalescer.coalesce(
                source, maxBytes: 64 * 1024, maxDelay: .milliseconds(10)
            ).makeAsyncIterator()
            _ = await iterator.next()
        }
        await fulfillment(of: [terminated], timeout: 5)
    }
}
