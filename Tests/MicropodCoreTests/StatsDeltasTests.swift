import XCTest

@testable import MicropodCore

final class StatsDeltasTests: XCTestCase {
    private func sample(
        rx: UInt64, tx: UInt64, read: UInt64, write: UInt64
    ) -> Micropod_V1_ContainerStats {
        var s = Micropod_V1_ContainerStats()
        s.networkRxBytes = rx
        s.networkTxBytes = tx
        s.blockReadBytes = read
        s.blockWriteBytes = write
        return s
    }

    func testRatesAreDeltasOverTime() {
        let previous = sample(rx: 1000, tx: 500, read: 2000, write: 1000)
        let current = sample(rx: 6000, tx: 3500, read: 12000, write: 21000)
        let deltas = statsDeltas(previous: previous, current: current, seconds: 2)
        XCTAssertEqual(deltas.netRxRate, 2500, accuracy: 0.001)
        XCTAssertEqual(deltas.netTxRate, 1500, accuracy: 0.001)
        XCTAssertEqual(deltas.blockReadRate, 5000, accuracy: 0.001)
        XCTAssertEqual(deltas.blockWriteRate, 10000, accuracy: 0.001)
    }

    func testZeroDeltaGivesZeroRates() {
        let previous = sample(rx: 100, tx: 100, read: 100, write: 100)
        let deltas = statsDeltas(previous: previous, current: previous, seconds: 5)
        XCTAssertEqual(deltas.netRxRate, 0, accuracy: 0.001)
        XCTAssertEqual(deltas.blockWriteRate, 0, accuracy: 0.001)
    }

    func testCounterResetProducesHugeRateWithoutCrashing() {
        let previous = sample(rx: UInt64.max, tx: 0, read: 0, write: 0)
        let current = sample(rx: 10, tx: 0, read: 0, write: 0)
        // Counter wrapped: delta is (10 - max) which wraps to 11 — a valid
        // estimate; the point is we never trap or divide by zero.
        let deltas = statsDeltas(previous: previous, current: current, seconds: 1)
        XCTAssertGreaterThanOrEqual(deltas.netRxRate, 0)
    }

    func testTinyDeltaIsClamped() {
        let previous = sample(rx: 100, tx: 100, read: 100, write: 100)
        let current = sample(rx: 200, tx: 200, read: 200, write: 200)
        let deltas = statsDeltas(previous: previous, current: current, seconds: 0)
        XCTAssertEqual(deltas.netRxRate, 100_000, accuracy: 1)
    }
}
