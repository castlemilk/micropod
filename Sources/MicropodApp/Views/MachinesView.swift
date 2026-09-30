import Charts
import MicropodCore
import SwiftUI

/// Machines tab: persistent `container machine` VMs (keep-alive CI) with
/// live metrics and logs. `container list` omits machines, so they never
/// showed up by name; metrics come from their per-boot backing containers
/// via the regular stats poller (see `AppStore.updateMachineStats`).
struct MachinesView: View {
    @Bindable var store: AppStore

    @State private var showCreateSheet = false
    @State private var confirmDelete: String?

    var body: some View {
        NavigationSplitView {
            listColumn
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 320)
        } detail: {
            if let id = store.selectedMachineID, store.machines.contains(where: { $0.name == id }) {
                MachineDetailView(store: store, machineID: id)
            } else {
                ContentUnavailableView(
                    "No Machine Selected",
                    systemImage: "server.rack",
                    description: Text("Select a machine to see its metrics and logs."))
            }
        }
        .task {
            // The machine list isn't polled elsewhere; stats ride the
            // container stats poller.
            let configured = UserDefaults.standard.double(forKey: UserDefaultsKeys.pollIntervalStats)
            let interval = configured > 0 ? min(configured, 5.0) : 5.0
            while !Task.isCancelled {
                await store.refreshMachines()
                if store.selectedMachineID == nil {
                    store.selectedMachineID = sortedMachines.first(where: \.isRunning)?.name
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateMachineSheet(store: store)
        }
        .confirmationDialog(
            "Delete machine?",
            isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { name in
            Button("Delete", role: .destructive) {
                Task { await store.deleteMachine(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deleting a machine removes its VM and root disk. This cannot be undone.")
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.machines.filter(\.isRunning).count) running · \(store.machines.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showCreateSheet = true
                } label: {
                    IconLabel(title: "Create", icon: "create", fallback: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(8)
            if let error = store.machineError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            Divider()
            if store.machines.isEmpty {
                ContentUnavailableView(
                    "No Machines",
                    systemImage: "server.rack",
                    description: Text("Machines are persistent Linux VMs — e.g. keep-alive CI runners."))
            } else {
                List(selection: $store.selectedMachineID) {
                    ForEach(sortedMachines) { machine in
                        MachineRowView(machine: machine, stats: store.machineStatsByID[machine.name])
                            .tag(machine.name)
                            .contextMenu {
                                if machine.isRunning {
                                    Button {
                                        Task { await store.stopMachine(machine.name) }
                                    } label: {
                                        MenuItemIconLabel(title: "Stop", icon: "stop", fallback: "stop.fill")
                                    }
                                }
                                Button(role: .destructive) {
                                    confirmDelete = machine.name
                                } label: {
                                    MenuItemIconLabel(title: "Delete", icon: "delete", fallback: "trash")
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// Running first, then newest.
    private var sortedMachines: [MachineEntry] {
        store.machines.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            return (a.created ?? "") > (b.created ?? "")
        }
    }
}

struct MachineRowView: View {
    let machine: MachineEntry
    let stats: Micropod_V1_MachineStats?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ContainerStateStyle.color(for: machine.state ?? ""))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(machine.state ?? "unknown")
                    if let ip = machine.ip, !ip.isEmpty { Text(ip) }
                    if machine.defaultMachine == true { Text("default") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let stats {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f%%", stats.cpuPercent))
                        .font(.caption.monospacedDigit())
                    Text(ByteFormat.string(stats.memoryUsedBytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One machine: header + Metrics / Logs / Inspect panes.
struct MachineDetailView: View {
    @Bindable var store: AppStore
    let machineID: String

    enum Pane: String, CaseIterable, Identifiable {
        case metrics, logs, inspect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .metrics: "Metrics"
            case .logs: "Logs"
            case .inspect: "Inspect (JSON)"
            }
        }
    }

    @State private var pane: Pane = .metrics

    private var machine: MachineEntry? {
        store.machines.first { $0.name == machineID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let machine {
                header(machine)
                Divider()
                Picker("Pane", selection: $pane) {
                    ForEach(Pane.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                switch pane {
                case .metrics:
                    MachineMetricsView(store: store, machine: machine)
                case .logs:
                    ContainerLogsView(store: store, containerID: machineID) { boot in
                        store.dependencies.machine.streamLogs(machineID, tail: 200, boot: boot)
                    }
                    .id(machineID)
                case .inspect:
                    ContainerInspectView(store: store, containerID: machineID) {
                        try await store.dependencies.machine.inspect(machineID)
                    }
                    .id(machineID)
                }
            }
        }
    }

    private func header(_ machine: MachineEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ContainerStateStyle.color(for: machine.state ?? ""))
                    .frame(width: 9, height: 9)
                Text(machine.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if machine.isRunning {
                    Button {
                        Task { await store.stopMachine(machine.name) }
                    } label: {
                        IconLabel(title: "Stop", icon: "stop", fallback: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(machine.name, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy machine ID")
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)],
                alignment: .leading, spacing: 4
            ) {
                infoItem("State", machine.state ?? "unknown")
                if let ip = machine.ip, !ip.isEmpty { infoItem("IP", ip) }
                if let cpus = machine.cpus { infoItem("CPUs", "\(cpus)") }
                if let memory = machine.memory { infoItem("Memory", memory) }
                if let disk = machine.disk { infoItem("Disk", disk) }
                if let created = machine.created.flatMap(parseDate) {
                    infoItem("Created", created.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(.background.secondary)
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.monospaced(.caption)()).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Live metrics for one machine from the store's rolling history.
struct MachineMetricsView: View {
    @Bindable var store: AppStore
    let machine: MachineEntry

    @State private var window: ChartTimeWindow = .fifteenMinutes
    /// Windows past 3 h: the rolled-up history, reloaded each minute.
    @State private var stored: [MachineSample] = []

    private var stats: Micropod_V1_MachineStats? { store.machineStatsByID[machine.name] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    ChartTimeWindowPicker(window: $window)
                        .task(id: window) {
                            while !Task.isCancelled && window.needsStore {
                                if let metricsStore = MetricsStore.shared {
                                    let name = machine.name
                                    let range = window.duration
                                    stored = await Task.detached {
                                        metricsStore.history(.machine, name, range: range).points
                                    }.value.map(MachineSample.init)
                                }
                                try? await Task.sleep(for: .seconds(60))
                            }
                        }
                }
                if let stats {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .leading)],
                        alignment: .leading, spacing: 10
                    ) {
                        statTile(
                            "CPU", String(format: "%.0f%%", stats.cpuPercent),
                            detail: "of \(stats.cpus) vCPU", icon: "cpu")
                        statTile(
                            "Memory", ByteFormat.string(stats.memoryUsedBytes),
                            detail: "of \(ByteFormat.string(stats.memoryLimitBytes))", icon: "memorychip")
                        statTile(
                            "Network", "↓\(ByteFormat.string(stats.networkRxBytes))",
                            detail: "↑\(ByteFormat.string(stats.networkTxBytes))", icon: "network")
                        statTile(
                            "Disk", "r \(ByteFormat.string(stats.blockReadBytes))",
                            detail: "w \(ByteFormat.string(stats.blockWriteBytes))", icon: "internaldrive")
                        statTile("PIDs", "\(stats.pids)", icon: "list.number")
                        statTile("Container", stats.containerID, icon: "shippingbox")
                    }
                } else if machine.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the next stats sample…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Machine is stopped — metrics resume when it runs again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let samples =
                    window.needsStore
                    ? stored
                    : (store.machineHistory[machine.name] ?? [])
                        .filter { $0.timestamp >= Date().addingTimeInterval(-window.duration) }
                let points = downsample(samples, maxPoints: 360)

                GroupBox("CPU % (of one core)") {
                    Chart(points, id: \.timestamp) { point in
                        LineMark(x: .value("Time", point.timestamp), y: .value("CPU %", point.cpuPercent))
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: 0...max(100, (points.map(\.cpuPercent).max() ?? 0) + 10))
                    .frame(height: 120)
                }

                GroupBox("Memory") {
                    Chart(points, id: \.timestamp) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Memory", Double(point.memoryUsedBytes) / 1_048_576)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxisLabel("MiB")
                    .frame(height: 120)
                }

                GroupBox("Network") {
                    Chart {
                        ForEach(points, id: \.timestamp) { point in
                            LineMark(x: .value("Time", point.timestamp), y: .value("Rx", point.netRxRate / 1024))
                                .foregroundStyle(by: .value("Direction", "Rx"))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Time", point.timestamp), y: .value("Tx", point.netTxRate / 1024))
                                .foregroundStyle(by: .value("Direction", "Tx"))
                                .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartForegroundStyleScale(["Rx": .green, "Tx": .blue])
                    .chartLegend(position: .trailing)
                    .chartYAxisLabel("KiB/s")
                    .frame(height: 120)
                }

                GroupBox("Disk I/O") {
                    Chart {
                        ForEach(points, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp), y: .value("Read", point.blockReadRate / 1024)
                            )
                            .foregroundStyle(by: .value("Op", "Read"))
                            .interpolationMethod(.catmullRom)
                            LineMark(
                                x: .value("Time", point.timestamp), y: .value("Write", point.blockWriteRate / 1024)
                            )
                            .foregroundStyle(by: .value("Op", "Write"))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartForegroundStyleScale(["Read": .orange, "Write": .purple])
                    .chartLegend(position: .trailing)
                    .chartYAxisLabel("KiB/s")
                    .frame(height: 120)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statTile(_ label: String, _ value: String, detail: String? = nil, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}
