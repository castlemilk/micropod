import Foundation

/// Per-second rates derived from two cumulative `container stats` samples.
public struct StatsDeltas: Equatable {
    public let netRxRate: Double
    public let netTxRate: Double
    public let blockReadRate: Double
    public let blockWriteRate: Double

    public init(netRxRate: Double, netTxRate: Double, blockReadRate: Double, blockWriteRate: Double) {
        self.netRxRate = netRxRate
        self.netTxRate = netTxRate
        self.blockReadRate = blockReadRate
        self.blockWriteRate = blockWriteRate
    }
}

/// Computes per-second rates between two cumulative stats samples. Pure and
/// CLI-free so it is unit-testable; used by the container stats charts.
public func statsDeltas(
    previous: Micropod_V1_ContainerStats,
    current: Micropod_V1_ContainerStats,
    seconds: TimeInterval
) -> StatsDeltas {
    let dt = max(seconds, 0.001)
    func rate(_ delta: UInt64) -> Double {
        Double(delta) / dt
    }
    // Wrapping subtraction: counters reset on restart, so a rolled-over
    // delta must wrap rather than trap.
    return StatsDeltas(
        netRxRate: rate(current.networkRxBytes &- previous.networkRxBytes),
        netTxRate: rate(current.networkTxBytes &- previous.networkTxBytes),
        blockReadRate: rate(current.blockReadBytes &- previous.blockReadBytes),
        blockWriteRate: rate(current.blockWriteBytes &- previous.blockWriteBytes))
}
