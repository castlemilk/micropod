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
    /// One `containerStats` call's outcome. The fan-out's children return
    /// this rather than `(String, Result<ContainerStatsEntry, any Error>)`:
    /// release builds offering that tuple back to the task group aborted
    /// with a pure virtual call in the Swift runtime's
    /// `AccumulatingTaskGroup::offer` within a second of app launch.
    private enum StatsOutcome: Sendable {
        case stats(id: String, ContainerStatsEntry, oomKills: UInt64?)
        /// The container exited between list and stats, or never ran.
        case skipped
        case transport(String)
    }

    /// The running container ids (`containerList`).
    typealias ListRunning = @Sendable () async throws -> [String]
    /// One container's `containerStats` entry.
    typealias FetchStats = @Sendable (String) async throws -> ContainerStatsEntry
    /// The guest's cgroup `memory.events` oom_kill counter, or nil when it
    /// could not be read (no answer in time, no memory-event support).
    typealias ReadOOMKills = @Sendable (String) async -> UInt64?

    /// How long one sample waits on a guest agent for `memory.events`
    /// before reporting the OOM count as unknown. The XPC stats call runs
    /// alongside, so this only bounds the tail of a slow guest.
    static let guestReadTimeout: Duration = .seconds(2)

    private let listRunning: ListRunning
    private let fetchStats: FetchStats
    private let readOOMKills: ReadOOMKills?
    private var previous: [String: (usec: Int64, at: ContinuousClock.Instant)] = [:]

    public init(api: APIServerClient) {
        let guest = GuestAgent(api: api, group: GuestAgent.sharedGroup)
        self.init(
            listRunning: {
                let listData = try await api.list(status: "running", policy: .polling)
                return try MicropodJSON.decodeArray(
                    ContainerListEntry.self, from: listData, context: "container list"
                ).map(\.id)
            },
            fetchStats: { try await api.stats(id: $0) },
            readOOMKills: { id in
                await Self.bounded(Self.guestReadTimeout) {
                    try await guest.statistics(id: id, categories: .memoryEvents)
                        .first(where: { $0.id == id })?.memoryEvents?.oomKill
                }
            })
    }

    /// Test seam: the XPC and guest reads as closures.
    init(listRunning: @escaping ListRunning, fetchStats: @escaping FetchStats, readOOMKills: ReadOOMKills?) {
        self.listRunning = listRunning
        self.fetchStats = fetchStats
        self.readOOMKills = readOOMKills
    }

    public func snapshot() async throws -> Micropod_V1_StatsSnapshot {
        try await sample(ids: try await listRunning(), forgetOthers: true)
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
    /// exited between list and stats, was never running, or its helper is
    /// wedged and the call timed out) is skipped. A transport failure is not
    /// "no stats" — it is rethrown so the caller sees `unavailable` instead
    /// of an empty, plausible-looking snapshot.
    private func sample(ids: [String], forgetOthers: Bool) async throws -> Micropod_V1_StatsSnapshot {
        let results = await withTaskGroup(of: StatsOutcome.self, returning: [StatsOutcome].self) { group in
            for id in ids {
                group.addTask {
                    // The guest read runs alongside the XPC call; it only
                    // matters if the XPC call says the container is there.
                    async let oomKills = self.readOOMKills?(id)
                    do {
                        let entry = try await self.fetchStats(id)
                        return .stats(id: id, entry, oomKills: await oomKills)
                    } catch MicropodError.transport(let detail) {
                        return .transport(detail)
                    } catch {
                        return .skipped
                    }
                }
            }
            var out: [StatsOutcome] = []
            for await item in group { out.append(item) }
            return out
        }
        // Keep the request order for a stable wire shape.
        var byID: [String: (entry: ContainerStatsEntry, oomKills: UInt64?)] = [:]
        for case .stats(let id, let entry, let oomKills) in results { byID[id] = (entry, oomKills) }
        for case .transport(let detail) in results { throw MicropodError.transport(detail) }
        let sampled = ids.compactMap { byID[$0] }

        let now = ContinuousClock.now
        var snapshot = Micropod_V1_StatsSnapshot()
        snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())

        for (entry, oomKills) in sampled {
            var stats = Micropod_V1_ContainerStats(entry: entry)
            if let oomKills { stats.oomKillCount = oomKills }

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
        let liveIDs = Set(sampled.map(\.entry.id))
        let asked = Set(ids)
        previous = previous.filter { liveIDs.contains($0.key) || (!forgetOthers && !asked.contains($0.key)) }
        return snapshot
    }

    /// `body`'s value, or nil if it throws or has not answered within
    /// `limit`. On timeout `body` is abandoned rather than awaited: a guest
    /// whose vsock never answers must not hold the whole sample.
    static func bounded<T: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> T?
    ) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let timer = Task {
                try await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let value = try? await body()
                timer.cancel()
                if once.claim() { continuation.resume(returning: value) }
            }
        }
    }
}
