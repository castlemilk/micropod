import Foundation

/// Samples resource usage for all running containers.
///
/// CPU percentage is computed from `cpuUsageUsec` deltas between samples
/// (the CLI only reports cumulative CPU time), so consecutive samples must
/// be taken by the same sampler instance.
public actor StatsSampler {
    private let client: ContainerCLIClient
    private var previous: [String: (usec: Int64, at: ContinuousClock.Instant)] = [:]

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func snapshot() async throws -> Micropod_V1_StatsSnapshot {
        let output = try await client.run(ContainerCommandFactory.statsSnapshot(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(ContainerStatsEntry.self, from: Data(output.utf8), context: "stats")

        let now = ContinuousClock.now
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())

        for entry in entries {
            var stats = Micropod_V1_ContainerStats()
            stats.id = entry.id
            stats.memoryUsedBytes = UInt64(entry.memoryUsageBytes ?? 0)
            stats.memoryLimitBytes = UInt64(entry.memoryLimitBytes ?? 0)
            stats.networkRxBytes = UInt64(entry.networkRxBytes ?? 0)
            stats.networkTxBytes = UInt64(entry.networkTxBytes ?? 0)
            stats.blockReadBytes = UInt64(entry.blockReadBytes ?? 0)
            stats.blockWriteBytes = UInt64(entry.blockWriteBytes ?? 0)
            stats.pids = UInt64(entry.numProcesses ?? 0)

            if let usec = entry.cpuUsageUsec {
                if let previousSample = previous[entry.id] {
                    let dt = previousSample.at.duration(to: now).components
                    let elapsed = Double(dt.seconds) + Double(dt.attoseconds) / 1e18
                    let deltaUsec = usec - previousSample.usec
                    if elapsed > 0.05, deltaUsec >= 0 {
                        // CPU time is per-core; report as % of one core (like top).
                        stats.cpuPercent = (Double(deltaUsec) / 1_000_000 / elapsed) * 100
                    }
                }
                previous[entry.id] = (usec: usec, at: now)
            }
            snapshot.containers.append(stats)
        }

        // Forget stats for containers that disappeared.
        let liveIDs = Set(entries.map(\.id))
        previous = previous.filter { liveIDs.contains($0.key) }
        return snapshot
    }
}
