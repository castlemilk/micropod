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
    @State private var compactDetailID: String?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            VStack(spacing: 0) {
                WorkspacePageHeader(
                    title: "MicroVMs",
                    subtitle: "\(store.machines.count(where: \.isRunning)) running · \(store.machines.count) total",
                    icon: "microvm", fallback: "server.rack"
                ) {
                    HStack(spacing: Tokens.Spacing.sm) {
                        if compact, let selected = store.selectedMachineID {
                            Button {
                                compactDetailID = selected
                            } label: {
                                Image(systemName: "sidebar.right")
                            }
                            .buttonStyle(.borderless)
                            .help("Inspect selected machine")
                            .accessibilityLabel("Inspect selected machine")
                        }
                        Button {
                            showCreateSheet = true
                        } label: {
                            IconLabel(title: "Create", icon: "create", fallback: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Tokens.Palette.action)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.contentInset)
                .padding(.vertical, Tokens.Spacing.lg)
                Divider()
                if compact {
                    listColumn(compact: true)
                } else {
                    HSplitView {
                        listColumn(compact: false)
                            .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                        machineDetail
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Tokens.Palette.canvas)
        .task(id: store.mainWindowVisible) {
            guard store.mainWindowVisible else { return }
            // Refresh is coalesced by the store with the workload and tray pollers;
            // stats ride the container stats poller.
            let configured = UserDefaults.standard.double(forKey: UserDefaultsKeys.pollIntervalStats)
            let interval = AppStore.statsPollingCadence(configured: configured).visible
            while !Task.isCancelled {
                await store.refreshMachines()
                guard !Task.isCancelled else { return }
                if store.selectedMachineID == nil {
                    store.selectedMachineID = sortedMachines.first(where: \.isRunning)?.name
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateMachineSheet(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { compactDetailID != nil },
                set: { if !$0 { compactDetailID = nil } }
            )
        ) {
            VStack(spacing: 0) {
                HStack {
                    Text("MicroVM Inspector").font(Tokens.Typography.section)
                    Spacer()
                    Button("Done") { compactDetailID = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                if let compactDetailID {
                    MachineDetailView(store: store, machineID: compactDetailID)
                }
            }
            .frame(minWidth: 320, idealWidth: 640, maxWidth: 900, minHeight: 320, idealHeight: 600, maxHeight: 900)
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

    @ViewBuilder
    private var machineDetail: some View {
        if let id = store.selectedMachineID, store.machines.contains(where: { $0.name == id }) {
            MachineDetailView(store: store, machineID: id)
        } else {
            WorkspaceSelectionPlaceholder(
                title: "Select a MicroVM", description: "Select a machine to see its metrics and logs.",
                icon: "microvm", fallback: "server.rack")
        }
    }

    private func listColumn(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if let error = store.machineError {
                Text(error)
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.danger)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            if store.machines.isEmpty {
                WorkspaceSelectionPlaceholder(
                    title: "No MicroVMs", description: "Create a persistent Linux VM for work such as a CI runner.",
                    icon: "microvm", fallback: "server.rack")
            } else {
                List(
                    selection: Binding(
                        get: { store.selectedMachineID },
                        set: { selected in
                            store.selectedMachineID = selected
                            if compact { compactDetailID = selected }
                        }
                    )
                ) {
                    ForEach(sortedMachines) { machine in
                        MachineRowView(
                            machine: machine, stats: store.isRuntimeRunning ? store.machineStatsByID[machine.name] : nil
                        )
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
            WorkspaceIconTile(name: "microvm", size: 28, iconSize: 16, fallback: "server.rack")
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(Tokens.Typography.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    WorkspaceStatusBadge(
                        title: machine.state ?? "unknown",
                        color: ContainerStateStyle.color(for: machine.state ?? ""), compact: true)
                    if let ip = machine.ip, !ip.isEmpty { Text(ip) }
                    if machine.defaultMachine == true { Text("default") }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .font(Tokens.Typography.metadata)
                .foregroundStyle(Tokens.Palette.secondary)
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

    init(store: AppStore, machineID: String, initialPane: Pane = .metrics) {
        self._store = Bindable(store)
        self.machineID = machineID
        self._pane = State(initialValue: initialPane)
    }

    private var machine: MachineEntry? {
        store.machines.first { $0.name == machineID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let machine {
                header(machine)
                Divider()
                ViewThatFits(in: .horizontal) {
                    Picker("Pane", selection: $pane) {
                        ForEach(Pane.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    Picker("Inspector", selection: $pane) {
                        ForEach(Pane.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                Group {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkspaceSelectionPlaceholder(
                    title: "Machine Removed", description: "Select another MicroVM from the inventory.",
                    icon: "microvm", fallback: "server.rack")
            }
        }
        .onChange(of: machineID) { _, _ in pane = .metrics }
    }

    private func header(_ machine: MachineEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WorkspaceIconTile(name: "microvm", size: 28, iconSize: 16, fallback: "server.rack")
                Text(machine.name)
                    .font(Tokens.Typography.section)
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
                .accessibilityLabel("Copy machine ID")
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)],
                alignment: .leading, spacing: 4
            ) {
                HStack(spacing: 4) {
                    Text("State").foregroundStyle(Tokens.Palette.secondary)
                    WorkspaceStatusBadge(
                        title: machine.state ?? "unknown",
                        color: ContainerStateStyle.color(for: machine.state ?? ""), compact: true)
                }
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
        .background(Tokens.Palette.canvas)
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.monospaced(.caption)()).lineLimit(1).truncationMode(.middle).help(value)
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
    @State private var historyTarget: String?

    private struct HistoryRequest: Equatable {
        let target: String
        let window: ChartTimeWindow
        let visible: Bool
    }

    private var stats: Micropod_V1_MachineStats? {
        guard store.isRuntimeRunning, store.clientAvailable, machine.isRunning else { return nil }
        return store.machineStatsByID[machine.name]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    ChartTimeWindowPicker(window: $window)
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
                } else if !store.isRuntimeRunning || !store.clientAvailable {
                    Text("Live readings unavailable. Recorded history remains available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .chartLegend(position: .bottom)
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
                    .chartLegend(position: .bottom)
                    .chartYAxisLabel("KiB/s")
                    .frame(height: 120)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: HistoryRequest(target: machine.name, window: window, visible: store.mainWindowVisible)) {
            if historyTarget != machine.name {
                historyTarget = machine.name
                stored = []
            }
            guard store.mainWindowVisible, window.needsStore, store.metrics != nil,
                let metricsStore = MetricsStore.shared
            else { return }
            let name = machine.name
            let range = window.duration
            while !Task.isCancelled {
                let points = await Task.detached(priority: .utility) {
                    metricsStore.history(.machine, name, range: range).points
                }.value
                guard !Task.isCancelled, name == machine.name else { return }
                stored = points.map(MachineSample.init)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func statTile(_ label: String, _ value: String, detail: String? = nil, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Tokens.Spacing.xs) {
                WorkspaceIcon(name: metricIcon(icon), size: 12, fallback: icon)
                Text(label)
            }
            .font(Tokens.Typography.metadata)
            .foregroundStyle(Tokens.Palette.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(2)
                .truncationMode(.middle)
                .help(value)
                .textSelection(.enabled)
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricIcon(_ symbol: String) -> String {
        switch symbol {
        case "memorychip": "memory"
        case "internaldrive": "storage"
        case "shippingbox": "container"
        case "list.number": "workloads"
        default: symbol
        }
    }
}
