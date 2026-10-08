import Foundation

/// Common interface for container stats samplers (CLI and native backends).
public protocol StatsSampling: Sendable {
    /// Every running container.
    func snapshot() async throws -> Micropod_V1_StatsSnapshot
    /// Only the given containers (`GetStatsRequest.ids`); empty means every
    /// running container. Ids that are unknown or not running contribute
    /// nothing — the caller asked about them, so their absence is the answer.
    func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot
}

extension StatsSampling {
    /// Default: sample everything, keep the requested ids in sampler order.
    /// The CLI path has one `container stats` invocation for any subset, so
    /// filtering after the fact costs nothing extra; the native sampler
    /// overrides this to call `containerStats` per id only.
    public func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot {
        var snapshot = try await snapshot()
        guard !ids.isEmpty else { return snapshot }
        let wanted = Set(ids)
        snapshot.containers.removeAll { !wanted.contains($0.id) }
        return snapshot
    }
}

/// Samples resource usage for all running containers.
///
/// CPU percentage is computed from `cpuUsageUsec` deltas between samples
/// (the CLI only reports cumulative CPU time), so consecutive samples must
/// be taken by the same sampler instance.
public actor StatsSampler: StatsSampling {
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
            var stats = Micropod_V1_ContainerStats(entry: entry)

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

extension Micropod_V1_ContainerStats {
    /// The counters a `ContainerStatsEntry` carries directly (CLI and XPC
    /// share the shape). `cpuPercent` is a delta, so each sampler fills it
    /// from its own baselines; `oomKillCount` is not in the entry at all.
    /// Negative counters (never expected) clamp to 0 = not reported.
    public init(entry: ContainerStatsEntry) {
        self.init()
        func counter(_ value: Int64?) -> UInt64 { UInt64(max(value ?? 0, 0)) }
        id = entry.id
        cpuUsageUsec = counter(entry.cpuUsageUsec)
        memoryUsedBytes = counter(entry.memoryUsageBytes)
        memoryLimitBytes = counter(entry.memoryLimitBytes)
        networkRxBytes = counter(entry.networkRxBytes)
        networkTxBytes = counter(entry.networkTxBytes)
        blockReadBytes = counter(entry.blockReadBytes)
        blockWriteBytes = counter(entry.blockWriteBytes)
        blockIoObserved =
            entry.blockReadBytes.map { $0 >= 0 } == true
            && entry.blockWriteBytes.map { $0 >= 0 } == true
        pids = counter(entry.numProcesses)
    }
}
