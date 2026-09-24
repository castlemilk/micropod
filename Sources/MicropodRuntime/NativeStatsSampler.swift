import Foundation
import MicropodCore

/// Drop-in `StatsSampler` replacement that fans out one `containerStats`
/// XPC call per running container, in parallel.
///
/// The CLI path (`container stats --no-stream`) serializes the same
/// round-trips through a single process invocation — ~2.4 s measured.
/// Per-id XPC calls run concurrently against independent runtime helpers,
/// so the sample costs ~one helper round-trip plus JSON decode.
public actor NativeStatsSampler: StatsSampling {
    private let api: APIServerClient
    private var previous: [String: (usec: Int64, at: ContinuousClock.Instant)] = [:]

    public init(api: APIServerClient) {
        self.api = api
    }

    public func snapshot() async throws -> Micropod_V1_StatsSnapshot {
        let listData = try await api.list(status: "running")
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: listData, context: "container list")

        // Fan out stats calls; skip containers whose stats fail (they may
        // have exited between list and stats).
        let statsEntries = await withTaskGroup(
            of: ContainerStatsEntry?.self, returning: [ContainerStatsEntry].self
        ) { group in
            for entry in entries {
                group.addTask {
                    try? await self.api.stats(id: entry.id)
                }
            }
            var out: [ContainerStatsEntry] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }

        let now = ContinuousClock.now
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())

        for entry in statsEntries {
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
                        stats.cpuPercent = (Double(deltaUsec) / 1_000_000 / elapsed) * 100
                    }
                }
                previous[entry.id] = (usec: usec, at: now)
            }
            snapshot.containers.append(stats)
        }

        let liveIDs = Set(statsEntries.map(\.id))
        previous = previous.filter { liveIDs.contains($0.key) }
        return snapshot
    }
}
