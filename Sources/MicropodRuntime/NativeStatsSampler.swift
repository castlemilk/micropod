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
        return try await sample(ids: entries.map(\.id), forgetOthers: true)
    }

    /// `GetStatsRequest.ids`: skips `containerList` and calls `containerStats`
    /// only for the requested ids. Unknown or stopped ids contribute nothing;
    /// CPU baselines for containers *not* asked about are kept so a later
    /// unfiltered sample still has its deltas.
    public func snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot {
        guard !ids.isEmpty else { return try await snapshot() }
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        return try await sample(ids: unique, forgetOthers: false)
    }

    /// Fan out stats calls in parallel; a container whose stats fail (it
    /// exited between list and stats, or was never running) is skipped. A
    /// transport failure is not "no stats" — it is rethrown so the caller
    /// sees `unavailable` instead of an empty, plausible-looking snapshot.
    private func sample(ids: [String], forgetOthers: Bool) async throws -> Micropod_V1_StatsSnapshot {
        let results = await withTaskGroup(
            of: (String, Result<ContainerStatsEntry, Error>).self,
            returning: [(String, Result<ContainerStatsEntry, Error>)].self
        ) { group in
            for id in ids {
                group.addTask {
                    do {
                        return (id, .success(try await self.api.stats(id: id)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var out: [(String, Result<ContainerStatsEntry, Error>)] = []
            for await item in group { out.append(item) }
            return out
        }
        // Keep the request order for a stable wire shape.
        var byID: [String: Result<ContainerStatsEntry, Error>] = [:]
        for (id, result) in results { byID[id] = result }
        var statsEntries: [ContainerStatsEntry] = []
        for id in ids {
            switch byID[id] {
            case .success(let entry)?: statsEntries.append(entry)
            case .failure(let error)?:
                if case MicropodError.transport = error { throw error }
            case nil: break
            }
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

        // Forget baselines for containers that disappeared — among the ones
        // this sample actually looked at.
        let liveIDs = Set(statsEntries.map(\.id))
        let asked = Set(ids)
        previous = previous.filter { liveIDs.contains($0.key) || (!forgetOthers && !asked.contains($0.key)) }
        return snapshot
    }
}
