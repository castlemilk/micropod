import Foundation

/// Samples resource usage for running container machines.
///
/// A running machine is backed by a per-boot container named
/// `<machine>-<6 hex>` that `container stats` reports (while `container
/// list` omits it), so machine metrics are the same cgroup counters as
/// container stats — one runtime call covers every machine. Nothing is
/// exec'd in the guest: a `machine run` per sample would add a process to
/// the VM being measured, and would boot a machine that stopped between
/// list and exec.
///
/// CPU % is a `cpuUsageUsec` delta between samples, so consecutive samples
/// must go through the same instance; a machine with no recent baseline is
/// sampled twice ~0.5 s apart so one-shot callers (CLI, MCP) still get a
/// real figure.
public actor MachineStatsSampler {
    private let client: ContainerCLIClient
    private let machines: MachineService
    private var previous: [String: (usec: Int64, at: ContinuousClock.Instant)] = [:]

    /// Baselines older than this are re-primed rather than averaged over.
    private let baselineMaxAge: Duration = .seconds(60)

    public init(client: ContainerCLIClient) {
        self.client = client
        self.machines = MachineService(client: client)
    }

    /// Stats for every running machine, or just `id` (throws when that
    /// machine is missing or stopped).
    public func snapshot(id: String? = nil) async throws -> Micropod_V1_MachineStatsSnapshot {
        let all = try await machines.list()
        var targets = all.filter(\.isRunning)
        if let id, !id.isEmpty {
            guard let machine = all.first(where: { $0.name == id }) else {
                throw MicropodError.message("notFound: no such machine: \(id)")
            }
            guard machine.isRunning else {
                throw MicropodError.message(
                    "failedPrecondition: machine \(id) is \(machine.state ?? "not running") — no stats")
            }
            targets = [machine]
        }

        var snapshot = Micropod_V1_MachineStatsSnapshot()
        guard !targets.isEmpty else {
            snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())
            return snapshot
        }

        var backing = try await sampleBacking(targets)
        let primed = ContinuousClock.now
        let needsPrime = backing.filter { name, _ in
            guard let prior = previous[name] else { return true }
            return prior.at.duration(to: primed) > baselineMaxAge
        }
        if !needsPrime.isEmpty {
            for (name, entry) in needsPrime {
                if let usec = entry.cpuUsageUsec { previous[name] = (usec, primed) }
            }
            try? await Task.sleep(for: .milliseconds(500))
            backing = try await sampleBacking(targets)
        }

        let now = ContinuousClock.now
        snapshot.sampledAt = ISO8601DateFormatter().string(from: Date())
        for machine in targets {
            guard let entry = backing[machine.name] else { continue }
            var stats = Self.stats(machine: machine, entry: entry)
            if let usec = entry.cpuUsageUsec {
                if let prior = previous[machine.name] {
                    let dt = prior.at.duration(to: now).components
                    let elapsed = Double(dt.seconds) + Double(dt.attoseconds) / 1e18
                    let deltaUsec = usec - prior.usec
                    if elapsed > 0.05, deltaUsec >= 0 {
                        stats.cpuPercent = (Double(deltaUsec) / 1_000_000 / elapsed) * 100
                    }
                }
                previous[machine.name] = (usec, now)
            }
            snapshot.machines.append(stats)
        }
        if let id, !id.isEmpty, snapshot.machines.isEmpty {
            throw MicropodError.message("unavailable: machine \(id) is running but reports no stats yet")
        }

        // Forget baselines for machines that stopped or disappeared.
        if id == nil || id?.isEmpty == true {
            let live = Set(targets.map(\.name))
            previous = previous.filter { live.contains($0.key) }
        }
        return snapshot
    }

    private func sampleBacking(_ targets: [MachineEntry]) async throws -> [String: ContainerStatsEntry] {
        let output = try await client.run(ContainerCommandFactory.statsSnapshot(), timeout: .seconds(15))
        let entries = try MicropodJSON.decodeArray(
            ContainerStatsEntry.self, from: Data(output.utf8), context: "stats")
        return Self.backingEntries(entries.map { ($0.id, $0) }, machines: targets.map(\.name))
    }

    /// Pairs each machine name with its per-boot backing container — the ID
    /// that is exactly `<name>-` plus six lowercase hex digits. The exact
    /// length keeps `ci` from claiming `ci-a1b2c3`'s container
    /// (`ci-a1b2c3-f00ba4`).
    public static func backingEntries<T>(_ entries: [(id: String, value: T)], machines: [String]) -> [String: T] {
        var result: [String: T] = [:]
        for name in machines {
            let prefix = name + "-"
            if let match = entries.first(where: { entry in
                guard entry.id.hasPrefix(prefix) else { return false }
                let suffix = entry.id.dropFirst(prefix.count)
                return suffix.count == 6 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            }) {
                result[name] = match.value
            }
        }
        return result
    }

    /// Machine stats from a container stats sample of its backing container
    /// (the app's poller already has these, CPU % included).
    public static func stats(machine: MachineEntry, container: Micropod_V1_ContainerStats) -> Micropod_V1_MachineStats {
        var stats = Micropod_V1_MachineStats()
        stats.id = machine.name
        stats.containerID = container.id
        stats.cpuPercent = container.cpuPercent
        stats.cpus = Int32(machine.cpus ?? 0)
        stats.memoryUsedBytes = container.memoryUsedBytes
        stats.memoryLimitBytes = container.memoryLimitBytes
        stats.networkRxBytes = container.networkRxBytes
        stats.networkTxBytes = container.networkTxBytes
        stats.blockReadBytes = container.blockReadBytes
        stats.blockWriteBytes = container.blockWriteBytes
        stats.pids = container.pids
        return stats
    }

    static func stats(machine: MachineEntry, entry: ContainerStatsEntry) -> Micropod_V1_MachineStats {
        var stats = Micropod_V1_MachineStats()
        stats.id = machine.name
        stats.containerID = entry.id
        stats.cpus = Int32(machine.cpus ?? 0)
        stats.memoryUsedBytes = UInt64(max(entry.memoryUsageBytes ?? 0, 0))
        stats.memoryLimitBytes = UInt64(max(entry.memoryLimitBytes ?? 0, 0))
        stats.networkRxBytes = UInt64(max(entry.networkRxBytes ?? 0, 0))
        stats.networkTxBytes = UInt64(max(entry.networkTxBytes ?? 0, 0))
        stats.blockReadBytes = UInt64(max(entry.blockReadBytes ?? 0, 0))
        stats.blockWriteBytes = UInt64(max(entry.blockWriteBytes ?? 0, 0))
        stats.pids = UInt64(max(entry.numProcesses ?? 0, 0))
        return stats
    }
}
