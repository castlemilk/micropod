import Foundation
import MicropodCore

/// Route IDs are namespaced because a container and a persistent machine can
/// legitimately have the same user-assigned name.
enum WorkloadRoute: Hashable, Sendable {
    case container(String)
    case machine(String)

    var id: String {
        switch self {
        case .container(let name): "container:\(name)"
        case .machine(let name): "machine:\(name)"
        }
    }
}

enum WorkloadKind: String, CaseIterable, Sendable {
    case container, sandbox, machine

    var label: String {
        switch self {
        case .container: "Container"
        case .sandbox: "Ephemeral VM"
        case .machine: "MicroVM"
        }
    }

    var symbol: String {
        switch self {
        case .container: "shippingbox"
        case .sandbox: "bolt.square"
        case .machine: "server.rack"
        }
    }
}

struct WorkloadItem: Identifiable, Equatable, Sendable {
    let route: WorkloadRoute
    let name: String
    let project: String
    let kind: WorkloadKind
    let engineLabel: String
    let state: String
    let image: String
    let cpuCores: Double?
    let memoryBytes: UInt64?
    let ports: [UInt32]
    let sampledAt: Date?
    /// Includes real labels and addresses; no project is inferred from names.
    let searchTerms: String

    var id: String { route.id }
    var kindLabel: String { kind.label }
    var isRunning: Bool { state == "running" }
    var stateLabel: String { state.isEmpty ? "Unknown" : state.localizedCapitalized }
    var hasMetrics: Bool { cpuCores != nil || memoryBytes != nil }

    func metricsAreStale(at date: Date, after interval: TimeInterval = 30) -> Bool {
        guard hasMetrics else { return false }
        guard let sampledAt else { return true }
        return date.timeIntervalSince(sampledAt) > interval
    }
}

enum WorkloadTypeFilter: String, CaseIterable, Identifiable {
    case all, containers, machines, sandboxes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All types"
        case .containers: "Containers"
        case .machines: "MicroVMs"
        case .sandboxes: "Ephemeral VMs"
        }
    }

    func matches(_ item: WorkloadItem) -> Bool {
        switch self {
        case .all: true
        case .containers: item.kind == .container
        case .machines: item.kind == .machine
        case .sandboxes: item.kind == .sandbox
        }
    }
}

enum WorkloadStateFilter: String, CaseIterable, Identifiable {
    case all, running, inactive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All states"
        case .running: "Running"
        case .inactive: "Inactive"
        }
    }

    func matches(_ item: WorkloadItem) -> Bool {
        switch self {
        case .all: true
        case .running: item.isRunning
        case .inactive: !item.isRunning
        }
    }
}

enum WorkloadSort: String, CaseIterable, Identifiable {
    case name, state, cpu, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .state: "State"
        case .cpu: "CPU cores"
        case .memory: "Memory"
        }
    }
}

struct WorkloadGroup: Identifiable, Equatable {
    let project: String
    let items: [WorkloadItem]
    var id: String { project }
}

struct WorkloadSummary: Equatable {
    let runningCount: Int
    let totalCount: Int
    let cpuCores: Double?
    let memoryBytes: UInt64?
    let cpuSampleCount: Int
    let memorySampleCount: Int
    let sampledWorkloadCount: Int
    let staleSampleCount: Int

    var isPartial: Bool {
        runningCount > 0 && (cpuSampleCount < runningCount || memorySampleCount < runningCount)
    }
}

/// Pure mapping and ordering are shared by the workspace and the menu bar.
/// Metrics use the existing cgroup sampler: 100 percent means one CPU core.
enum WorkloadInventory {
    static func items(
        containers: [Micropod_V1_Container],
        machines: [MachineEntry],
        containerStats: [String: Micropod_V1_ContainerStats],
        machineStats: [String: Micropod_V1_MachineStats],
        sampledAt: Date?,
        runtimeAvailable: Bool = true
    ) -> [WorkloadItem] {
        // Normally machine backing containers are omitted by `container list`.
        // If one is returned, suppress only an explicitly sampled backing ID.
        let machineNames = Set(machines.map(\.name))
        let backingIDs = Set(
            machineStats.filter { machineNames.contains($0.key) }
                .values.map(\.containerID).filter { !$0.isEmpty })
        var result: [WorkloadItem] = []
        result.reserveCapacity(containers.count + machines.count)
        for container in containers where !backingIDs.contains(container.id) {
            let state = normalizedState(container.state)
            let running = state == "running"
            let stats = running && runtimeAvailable ? containerStats[container.id] : nil
            let runtime = container.runtime.lowercased()
            let kind: WorkloadKind = runtime == "sandbox" ? .sandbox : .container
            let engine = engineLabel(runtime)
            let project = projectName(container.labels)
            let ports = Array(Set(container.publishedPorts.map(\.hostPort).filter { $0 > 0 })).sorted()
            let labels = container.labels.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: " ")
            let search = [
                container.id, container.image, project, engine, state, kind.label,
                container.ipv4Address, ports.map(String.init).joined(separator: " "), labels,
            ]
            .joined(separator: " ").lowercased()
            result.append(
                WorkloadItem(
                    route: .container(container.id), name: container.id, project: project,
                    kind: kind, engineLabel: engine, state: state, image: container.image,
                    cpuCores: stats.flatMap { validCores($0.cpuPercent) },
                    memoryBytes: stats?.memoryUsedBytes, ports: ports,
                    sampledAt: stats == nil ? nil : sampledAt, searchTerms: search))
        }
        for machine in machines {
            let state = normalizedState(machine.state ?? "unknown")
            let stats = machine.isRunning && runtimeAvailable ? machineStats[machine.name] : nil
            result.append(
                WorkloadItem(
                    route: .machine(machine.name), name: machine.name, project: "Standalone",
                    kind: .machine, engineLabel: "Apple", state: state, image: "Persistent Linux VM",
                    cpuCores: stats.flatMap { validCores($0.cpuPercent) },
                    memoryBytes: stats?.memoryUsedBytes, ports: [],
                    sampledAt: stats == nil ? nil : sampledAt,
                    searchTerms: [machine.name, machine.ip ?? "", "microvm persistent linux vm apple", state]
                        .joined(separator: " ").lowercased()))
        }
        return result
    }

    static func groups(
        items: [WorkloadItem], query: String = "", type: WorkloadTypeFilter = .all,
        state: WorkloadStateFilter = .all, sort: WorkloadSort = .name, ascending: Bool = true
    ) -> [WorkloadGroup] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let visible = items.filter { item in
            type.matches(item) && state.matches(item)
                && terms.allSatisfy { item.searchTerms.contains($0) }
        }
        let grouped = Dictionary(grouping: visible, by: \.project)
        return grouped.keys.sorted { left, right in
            if left == "Standalone" { return false }
            if right == "Standalone" { return true }
            return namePrecedes(left, right)
        }.map { project in
            WorkloadGroup(
                project: project,
                items: grouped[project, default: []].sorted {
                    precedes($0, $1, sort: sort, ascending: ascending)
                })
        }
    }

    static func summary(
        items: [WorkloadItem], at date: Date = Date(), runtimeAvailable: Bool = true
    ) -> WorkloadSummary {
        var runningCount = 0
        var cpuSampleCount = 0
        var memorySampleCount = 0
        var sampledWorkloadCount = 0
        var staleSampleCount = 0
        var cpuCores = 0.0
        var memoryBytes: UInt64 = 0
        for item in items where item.isRunning {
            runningCount += 1
            guard runtimeAvailable else { continue }
            if let cpu = item.cpuCores {
                cpuSampleCount += 1
                cpuCores += cpu
            }
            if let memory = item.memoryBytes {
                memorySampleCount += 1
                let (sum, overflow) = memoryBytes.addingReportingOverflow(memory)
                memoryBytes = overflow ? UInt64.max : sum
            }
            if item.cpuCores != nil && item.memoryBytes != nil { sampledWorkloadCount += 1 }
            if item.metricsAreStale(at: date) { staleSampleCount += 1 }
        }
        return WorkloadSummary(
            runningCount: runningCount, totalCount: items.count,
            cpuCores: runtimeAvailable && (runningCount == 0 || cpuSampleCount > 0) ? cpuCores : nil,
            memoryBytes: runtimeAvailable && (runningCount == 0 || memorySampleCount > 0) ? memoryBytes : nil,
            cpuSampleCount: cpuSampleCount, memorySampleCount: memorySampleCount,
            sampledWorkloadCount: sampledWorkloadCount, staleSampleCount: staleSampleCount)
    }

    /// Filtering never changes selection. Removal clears the missing route;
    /// existing detail-route selection seeds the workspace only on first entry.
    static func resolvedSelection(
        currentID: String?, selectedContainerID: String?, selectedMachineID: String?,
        items: [WorkloadItem]
    ) -> String? {
        let live = Set(items.map(\.id))
        if let currentID { return live.contains(currentID) ? currentID : nil }
        if let selectedContainerID, live.contains(WorkloadRoute.container(selectedContainerID).id) {
            return WorkloadRoute.container(selectedContainerID).id
        }
        if let selectedMachineID, live.contains(WorkloadRoute.machine(selectedMachineID).id) {
            return WorkloadRoute.machine(selectedMachineID).id
        }
        return nil
    }

    private static func projectName(_ labels: [String: String]) -> String {
        for key in ["com.skunkworq.micropod.compose", "com.docker.compose.project", "com.micropod.project"] {
            if let value = labels[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "Standalone"
    }

    private static func engineLabel(_ runtime: String) -> String {
        switch runtime {
        case "", "apple": "Apple"
        case "docker": "Docker"
        case "sandbox": "Sandbox"
        default: runtime.localizedCapitalized
        }
    }

    private static func normalizedState(_ state: String) -> String {
        let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func validCores(_ percent: Double) -> Double? {
        percent.isFinite && percent >= 0 ? percent / 100 : nil
    }

    private static func precedes(
        _ left: WorkloadItem, _ right: WorkloadItem, sort: WorkloadSort, ascending: Bool
    ) -> Bool {
        switch sort {
        case .cpu:
            return optionalValuePrecedes(left.cpuCores, right.cpuCores, left: left, right: right, ascending: ascending)
        case .memory:
            return optionalValuePrecedes(
                left.memoryBytes, right.memoryBytes, left: left, right: right, ascending: ascending)
        case .name, .state:
            let comparison = (sort == .name ? left.name : left.state)
                .localizedCaseInsensitiveCompare(sort == .name ? right.name : right.state)
            if comparison == .orderedSame { return namePrecedes(left.id, right.id) }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func optionalValuePrecedes<T: Comparable>(
        _ leftValue: T?, _ rightValue: T?, left: WorkloadItem, right: WorkloadItem, ascending: Bool
    ) -> Bool {
        switch (leftValue, rightValue) {
        case (nil, nil): namePrecedes(left.id, right.id)
        case (nil, _): false
        case (_, nil): true
        case (.some(let lhs), .some(let rhs)):
            lhs == rhs ? namePrecedes(left.id, right.id) : ascending ? lhs < rhs : lhs > rhs
        }
    }

    private static func namePrecedes(_ left: String, _ right: String) -> Bool {
        let order = left.localizedCaseInsensitiveCompare(right)
        return order == .orderedSame ? left < right : order == .orderedAscending
    }
}

/// The store advances revisions when sources change. Reads, selections and
/// window resizes reuse the same array; sampling never rebuilds labels or ports.
@MainActor
final class WorkloadInventoryCache {
    private var metadataRevision: UInt64?
    private var metricsRevision: UInt64?
    private var runtimeAvailable: Bool?
    private var metadata: [WorkloadItem] = []
    private var machineNames: Set<String> = []
    private var runningMachineNames: Set<String> = []
    private var cachedItems: [WorkloadItem] = []
    private var indexByID: [String: Int] = [:]
    private(set) var ids: [String] = []

    func items(
        containers: [Micropod_V1_Container], machines: [MachineEntry],
        containerStats: [String: Micropod_V1_ContainerStats],
        machineStats: [String: Micropod_V1_MachineStats], sampledAt: Date?,
        runtimeAvailable: Bool, metadataRevision: UInt64, metricsRevision: UInt64
    ) -> [WorkloadItem] {
        let metadataChanged = self.metadataRevision != metadataRevision
        if metadataChanged {
            metadata = WorkloadInventory.items(
                containers: containers, machines: machines, containerStats: [:],
                machineStats: [:], sampledAt: nil)
            machineNames = Set(machines.map(\.name))
            runningMachineNames = Set(machines.filter(\.isRunning).map(\.name))
            self.metadataRevision = metadataRevision
        }
        guard
            metadataChanged || self.metricsRevision != metricsRevision
                || self.runtimeAvailable != runtimeAvailable
        else { return cachedItems }
        self.metricsRevision = metricsRevision
        self.runtimeAvailable = runtimeAvailable
        let backingIDs = Set(
            machineStats.lazy.filter { self.machineNames.contains($0.key) }
                .map { $0.value.containerID }.filter { !$0.isEmpty })
        cachedItems = metadata.compactMap { item in
            let cpuPercent: Double?
            let memoryBytes: UInt64?
            switch item.route {
            case .container(let id):
                guard !backingIDs.contains(id) else { return nil }
                let stats = runtimeAvailable && item.isRunning ? containerStats[id] : nil
                cpuPercent = stats?.cpuPercent
                memoryBytes = stats?.memoryUsedBytes
            case .machine(let name):
                let stats = runtimeAvailable && runningMachineNames.contains(name) ? machineStats[name] : nil
                cpuPercent = stats?.cpuPercent
                memoryBytes = stats?.memoryUsedBytes
            }
            return WorkloadItem(
                route: item.route, name: item.name, project: item.project, kind: item.kind,
                engineLabel: item.engineLabel, state: item.state, image: item.image,
                cpuCores: cpuPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 / 100 : nil },
                memoryBytes: memoryBytes, ports: item.ports,
                sampledAt: cpuPercent == nil && memoryBytes == nil ? nil : sampledAt,
                searchTerms: item.searchTerms)
        }
        indexByID = Dictionary(
            cachedItems.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        ids = cachedItems.map(\.id)
        return cachedItems
    }

    func current(metadataRevision: UInt64, metricsRevision: UInt64, runtimeAvailable: Bool) -> [WorkloadItem]? {
        guard self.metadataRevision == metadataRevision, self.metricsRevision == metricsRevision,
            self.runtimeAvailable == runtimeAvailable
        else { return nil }
        return cachedItems
    }

    func item(id: String?) -> WorkloadItem? {
        id.flatMap { indexByID[$0] }.map { cachedItems[$0] }
    }
}

/// Sorting/filtering is independent of selection and geometry. When only a
/// sampler tick changes, name/state order is reused and rows receive new values.
@MainActor
final class WorkloadGroupingCache {
    private struct Key: Equatable {
        let metadataRevision: UInt64
        let query: String
        let type: WorkloadTypeFilter
        let state: WorkloadStateFilter
        let sort: WorkloadSort
        let ascending: Bool
    }
    private var key: Key?
    private var metricsRevision: UInt64?
    private var runtimeAvailable: Bool?
    private var ids: [String] = []
    private var cachedGroups: [WorkloadGroup] = []

    func groups(
        items: [WorkloadItem], ids: [String], metadataRevision: UInt64, metricsRevision: UInt64,
        runtimeAvailable: Bool, query: String, type: WorkloadTypeFilter,
        state: WorkloadStateFilter, sort: WorkloadSort, ascending: Bool
    ) -> [WorkloadGroup] {
        let nextKey = Key(
            metadataRevision: metadataRevision, query: query, type: type,
            state: state, sort: sort, ascending: ascending)
        let keyUnchanged = key == nextKey
        guard
            !keyUnchanged || self.metricsRevision != metricsRevision
                || self.runtimeAvailable != runtimeAvailable
        else { return cachedGroups }
        if keyUnchanged && (sort == .name || sort == .state) && self.ids == ids {
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            cachedGroups = cachedGroups.map { group in
                WorkloadGroup(project: group.project, items: group.items.compactMap { byID[$0.id] })
            }
        } else {
            cachedGroups = WorkloadInventory.groups(
                items: items, query: query, type: type, state: state, sort: sort, ascending: ascending)
        }
        key = nextKey
        self.metricsRevision = metricsRevision
        self.runtimeAvailable = runtimeAvailable
        self.ids = ids
        return cachedGroups
    }
}

@MainActor
extension AppStore {
    var workloadItems: [WorkloadItem] {
        if let cached = workloadCache.current(
            metadataRevision: workloadMetadataRevision, metricsRevision: workloadMetricsRevision,
            runtimeAvailable: isRuntimeRunning)
        {
            return cached
        }
        return workloadCache.items(
            containers: containers, machines: machines, containerStats: statsByID,
            machineStats: machineStatsByID, sampledAt: statsSnapshot.flatMap { parseDate($0.sampledAt) },
            runtimeAvailable: isRuntimeRunning, metadataRevision: workloadMetadataRevision,
            metricsRevision: workloadMetricsRevision)
    }

    func workloadItem(id: String?) -> WorkloadItem? {
        _ = workloadItems
        return workloadCache.item(id: id)
    }

    func selectWorkload(_ item: WorkloadItem) {
        selectedWorkloadID = item.id
        switch item.route {
        case .container(let id): selectedContainerID = id
        case .machine(let name): selectedMachineID = name
        }
    }

    func openWorkload(_ item: WorkloadItem) {
        selectWorkload(item)
        workloadInspectionRequest &+= 1
        activeTab = .workloads
    }
}
