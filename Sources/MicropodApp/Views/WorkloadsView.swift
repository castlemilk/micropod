import MicropodCore
import SwiftUI

/// One inventory for real containers and separately managed persistent VMs.
/// All resource rows reuse AppStore's sampler; this view starts no pollers.
struct WorkloadsView: View {
    @Bindable var store: AppStore
    @State private var query = ""
    @State private var typeFilter: WorkloadTypeFilter = .all
    @State private var stateFilter: WorkloadStateFilter = .all
    @State private var sort: WorkloadSort = .name
    @State private var ascending = true
    @State private var tableWidth: CGFloat = 460
    @State private var showRunSheet = false
    @State private var showMachineSheet = false
    @State private var showCompactDetail = false
    @State private var isRefreshing = false
    @FocusState private var searchFocused: Bool
    @State private var groupingCache = WorkloadGroupingCache()

    private var items: [WorkloadItem] { store.workloadItems }

    var body: some View {
        let inventory = items
        let now = Date()
        let summary = WorkloadInventory.summary(items: inventory, at: now, runtimeAvailable: store.isRuntimeRunning)
        let inventoryIDs = store.workloadCache.ids
        let groups = groupingCache.groups(
            items: inventory, ids: inventoryIDs, metadataRevision: store.workloadMetadataRevision,
            metricsRevision: store.workloadMetricsRevision, runtimeAvailable: store.isRuntimeRunning,
            query: query, type: typeFilter, state: stateFilter, sort: sort, ascending: ascending)
        let selected = store.workloadCache.item(id: store.selectedWorkloadID)
        GeometryReader { geometry in
            VStack(spacing: 0) {
                pageHeader(summary)
                resourceStrip(summary, width: geometry.size.width)
                Divider()
                if geometry.size.width >= 780 {
                    HSplitView {
                        inventoryColumn(groups: groups, inventory: inventory)
                            .frame(minWidth: 350, idealWidth: 460, maxWidth: .infinity)
                        inspector(selected)
                            .frame(minWidth: 320, idealWidth: Tokens.Layout.inspector, maxWidth: 600)
                    }
                } else if showCompactDetail, let selected {
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                showCompactDetail = false
                            } label: {
                                Label("Workloads", systemImage: "chevron.left")
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Text(selected.kindLabel)
                                .font(Tokens.Typography.metadata)
                                .foregroundStyle(Tokens.Palette.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider()
                        inspector(selected)
                    }
                } else {
                    inventoryColumn(groups: groups, inventory: inventory)
                }
                sampleFooter(inventory: inventory, summary: summary)
            }
            .background(Tokens.Palette.canvas)
            .onChange(of: store.selectedWorkloadID) { _, selection in
                if geometry.size.width < 780, selection != nil { showCompactDetail = true }
            }
            .onChange(of: store.workloadInspectionRequest) { _, _ in
                if geometry.size.width < 780, store.selectedWorkloadID != nil { showCompactDetail = true }
            }
            .onAppear {
                synchronizeSelection(inventory)
                if geometry.size.width < 780, selected != nil { showCompactDetail = true }
            }
        }
        .task { await store.refreshMachines() }
        .onChange(of: inventoryIDs) { _, _ in synchronizeSelection(inventory) }
        .onChange(of: store.selectedContainerID) { _, id in
            guard let id, let item = store.workloadItem(id: WorkloadRoute.container(id).id) else { return }
            if store.selectedWorkloadID != item.id { store.selectWorkload(item) }
        }
        .onChange(of: store.selectedMachineID) { _, id in
            guard let id, let item = store.workloadItem(id: WorkloadRoute.machine(id).id) else { return }
            if store.selectedWorkloadID != item.id { store.selectWorkload(item) }
        }
        .onChange(of: store.pendingRunSheet) { _, pending in
            if pending { consumeRunRequest() }
        }
        .onAppear { if store.pendingRunSheet { consumeRunRequest() } }
        .sheet(isPresented: $showRunSheet) { RunContainerSheet(store: store) }
        .sheet(isPresented: $showMachineSheet) { CreateMachineSheet(store: store) }
        .background {
            Button("Find Workloads") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private func pageHeader(_ summary: WorkloadSummary) -> some View {
        WorkspacePageHeader(
            title: "Workloads",
            subtitle: store.isRuntimeRunning
                ? "\(summary.runningCount) running · \(summary.totalCount) total"
                : "\(summary.runningCount) last seen running · \(summary.totalCount) total",
            icon: "workloads", fallback: "square.stack.3d.up"
        ) {
            HStack(spacing: Tokens.Spacing.sm) {
                Button {
                    guard !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        await store.refreshContainers()
                        await store.refreshMachines()
                        await store.refreshStats()
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh workloads")
                .accessibilityLabel("Refresh workloads")
                Menu {
                    Button("Run Container…") { showRunSheet = true }
                    Button("Create MicroVM…") { showMachineSheet = true }
                } label: {
                    Label("Run", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Palette.action)
                .fixedSize()
                .help("Run a container or create a persistent MicroVM")
            }
        }
        .padding(.horizontal, Tokens.Spacing.contentInset)
        .padding(.vertical, Tokens.Spacing.lg)
    }

    private func resourceStrip(_ summary: WorkloadSummary, width: CGFloat) -> some View {
        let columns = max(1, min(3, Int((width - 2 * Tokens.Spacing.contentInset + Tokens.Spacing.md) / 192)))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.md), count: columns),
            spacing: Tokens.Spacing.md
        ) {
            resourceMetric(
                "CPU cores", value: summary.cpuCores.map { String(format: "%.2f", $0) } ?? "—",
                symbol: "cpu", measured: summary.cpuSampleCount, total: summary.runningCount)
            resourceMetric(
                "Workload memory", value: summary.memoryBytes.map(ByteFormat.string) ?? "—",
                symbol: "memorychip", measured: summary.memorySampleCount, total: summary.runningCount)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    !store.isRuntimeRunning
                        ? "Readings unavailable"
                        : summary.staleSampleCount > 0
                            ? "Stale samples" : summary.isPartial ? "Partial coverage" : "Shared sampler"
                )
                .font(Tokens.Typography.section)
                .foregroundStyle(summary.staleSampleCount > 0 ? Tokens.Palette.warning : Tokens.Palette.secondary)
                Text(
                    !store.isRuntimeRunning
                        ? "Last known inventory"
                        : summary.runningCount == 0
                            ? "No running workloads"
                            : "\(summary.sampledWorkloadCount) of \(summary.runningCount) measured"
                )
                .font(Tokens.Typography.metadata)
                .foregroundStyle(Tokens.Palette.tertiary)
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(Tokens.Spacing.md)
            .cardSurface(fillOpacity: 1)
        }
        .padding(.horizontal, Tokens.Spacing.contentInset)
        .padding(.bottom, Tokens.Spacing.lg)
    }

    private func resourceMetric(
        _ title: String, value: String, symbol: String, measured: Int, total: Int
    ) -> some View {
        WorkspaceMetric(
            title: title, value: value, icon: symbol == "cpu" ? "cpu" : "memory",
            color: symbol == "cpu" ? Tokens.Chart.cpu : Tokens.Chart.memory, fallback: symbol
        )
        .help(
            !store.isRuntimeRunning
                ? "Resource readings are unavailable. The inventory shows its last known state."
                : total > measured
                    ? "Measured usage for \(measured) of \(total) running workloads; remaining readings unavailable."
                    : "Measured workload usage. CPU: one consumed core equals 100% in the runtime sampler.")
    }

    private func inventoryColumn(groups: [WorkloadGroup], inventory: [WorkloadItem]) -> some View {
        let sampledNow = Date()
        return VStack(spacing: 0) {
            filters
            tableHeader
            if inventory.isEmpty {
                ContentUnavailableView {
                    Label("No Workloads", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Run a container or create a persistent MicroVM to get started.")
                } actions: {
                    Button("Run Container…") { showRunSheet = true }
                }
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Matching Workloads", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try another type, state or search."))
            } else {
                List(selection: selectionBinding(inventory)) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                WorkloadRow(
                                    item: item, width: tableWidth, stale: item.metricsAreStale(at: sampledNow),
                                    runtimeAvailable: store.isRuntimeRunning
                                )
                                .equatable()
                                .tag(item.id)
                                .contextMenu { rowMenu(item) }
                                .onTapGesture(count: 2) {
                                    store.selectWorkload(item)
                                    showCompactDetail = true
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: group.project == "Standalone" ? "square.stack.3d.up" : "folder")
                                Text(group.project)
                                Spacer()
                                Text("\(group.items.count)").monospacedDigit()
                            }
                            .font(Tokens.Typography.metadata)
                            .foregroundStyle(Tokens.Palette.secondary)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Tokens.Palette.surface)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            tableWidth = $0
        }
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.Palette.tertiary)
                TextField("Find a workload, project or image", text: $query)
                    .textFieldStyle(.plain)
                    .font(Tokens.Typography.body)
                    .focused($searchFocused)
                    .accessibilityLabel("Filter workloads")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Palette.secondary)
                    .accessibilityLabel("Clear workload search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Tokens.Palette.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm).stroke(Tokens.Palette.controlBorder, lineWidth: 0.5))
            HStack(spacing: 8) {
                Picker("Workload type", selection: $typeFilter) {
                    ForEach(WorkloadTypeFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Picker("Workload state", selection: $stateFilter) {
                    ForEach(WorkloadStateFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Spacer(minLength: 0)
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(WorkloadSort.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Ascending", isOn: $ascending)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort workloads")
                .accessibilityLabel("Sort workloads")
                if store.selectedWorkloadID != nil, tableWidth < 780 {
                    Button {
                        showCompactDetail = true
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Show selected workload")
                    .accessibilityLabel("Show selected workload inspector")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            sortButton("Name / type", key: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tableWidth >= 480 {
                sortButton(store.isRuntimeRunning ? "State" : "Last state", key: .state).frame(width: 70)
            }
            sortButton("CPU", key: .cpu).frame(width: 66)
            sortButton("Memory", key: .memory).frame(width: 76)
            if tableWidth >= 610 {
                Text("Ports").frame(width: 66, alignment: .trailing)
            }
        }
        .font(Tokens.Typography.metadata)
        .foregroundStyle(Tokens.Palette.tertiary)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Tokens.Palette.canvas)
    }

    private func sortButton(_ title: String, key: WorkloadSort, alignment: Alignment = .trailing) -> some View {
        Button {
            if sort == key {
                ascending.toggle()
            } else {
                sort = key
                ascending = key == .name || key == .state
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(key.title)")
        .accessibilityLabel("Sort by \(key.title)\(sort == key ? ascending ? ", ascending" : ", descending" : "")")
    }

    @ViewBuilder
    private func inspector(_ item: WorkloadItem?) -> some View {
        if let item {
            switch item.route {
            case .container(let id): ContainerDetailView(store: store, containerID: id, initialPane: .logs).id(item.id)
            case .machine(let name): MachineDetailView(store: store, machineID: name).id(item.id)
            }
        } else {
            WorkspaceSelectionPlaceholder(
                title: "Select a Workload",
                description: "Inspect logs, metrics, files and configuration while keeping the inventory in view.",
                icon: "workloads", fallback: "sidebar.right")
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: WorkloadItem) -> some View {
        Button("Inspect \(item.name)") {
            store.selectWorkload(item)
            showCompactDetail = true
        }
        Button(item.kind == .machine ? "Show in MicroVMs" : "Show in Containers") {
            store.selectWorkload(item)
            store.activeTab = item.kind == .machine ? .machines : .containers
        }
        if item.isRunning {
            Button("Stop") {
                Task {
                    switch item.route {
                    case .container(let id): await store.stopContainer(id)
                    case .machine(let name): await store.stopMachine(name)
                    }
                }
            }
            .disabled(!store.isRuntimeRunning)
        } else if item.kind == .container {
            Button("Start") {
                if case .container(let id) = item.route { Task { await store.startContainer(id) } }
            }
            .disabled(!store.isRuntimeRunning)
        }
    }

    private func sampleFooter(inventory: [WorkloadItem], summary: WorkloadSummary) -> some View {
        HStack(spacing: 8) {
            if !store.isRuntimeRunning {
                Text(
                    store.systemStatus?.status == "stopped"
                        ? "Runtime stopped · readings unavailable" : "Runtime unavailable · readings unavailable")
            } else if let error = store.machineError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Tokens.Palette.warning)
                Text("MicroVM inventory unavailable")
                    .help(error)
            } else if summary.staleSampleCount > 0 {
                Text("\(summary.staleSampleCount) workload readings are stale")
                    .foregroundStyle(Tokens.Palette.warning)
            } else if let date = inventory.lazy.compactMap(\.sampledAt).max() {
                Text("Sampled \(date.formatted(.relative(presentation: .numeric)))")
            } else {
                Text(summary.runningCount == 0 ? "No running workloads" : "Waiting for resource samples")
            }
            Spacer(minLength: 8)
            Text("CPU in consumed cores")
        }
        .font(Tokens.Typography.metadata)
        .foregroundStyle(Tokens.Palette.tertiary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Tokens.Palette.canvas)
    }

    private func selectionBinding(_ inventory: [WorkloadItem]) -> Binding<String?> {
        Binding(
            get: { store.selectedWorkloadID },
            set: { id in
                if let item = store.workloadItem(id: id) {
                    store.selectWorkload(item)
                } else {
                    store.selectedWorkloadID = nil
                }
            })
    }

    private func synchronizeSelection(_ inventory: [WorkloadItem]) {
        store.selectedWorkloadID = WorkloadInventory.resolvedSelection(
            currentID: store.selectedWorkloadID, selectedContainerID: store.selectedContainerID,
            selectedMachineID: store.selectedMachineID, items: inventory)
    }

    private func consumeRunRequest() {
        showRunSheet = true
        store.pendingRunSheet = false
    }
}

private struct WorkloadRow: View, Equatable {
    let item: WorkloadItem
    let width: CGFloat
    let stale: Bool
    let runtimeAvailable: Bool

    private var displayedState: String {
        runtimeAvailable ? item.stateLabel : "Last seen \(item.state)"
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                WorkspaceIconTile(
                    name: item.kind == .container ? "container" : "microvm", size: 28, iconSize: 16,
                    fallback: item.kind.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(Tokens.Typography.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(
                        "\(item.kindLabel) · \(item.engineLabel)\(width < 480 ? " · \(displayedState)" : "")\(stale ? " · Stale" : "")"
                    )
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if width >= 480 {
                WorkspaceStatusBadge(title: displayedState, color: stateColor, compact: true)
                    .frame(width: 70, alignment: .trailing)
            }
            Text(item.cpuCores.map { String(format: "%.2f", $0) } ?? "—")
                .frame(width: 66, alignment: .trailing)
                .foregroundStyle(stale ? Tokens.Palette.warning : Tokens.Palette.primary)
                .help(item.cpuCores == nil ? "CPU sample unavailable" : "Consumed CPU cores")
            Text(item.memoryBytes.map(ByteFormat.string) ?? "—")
                .frame(width: 76, alignment: .trailing)
                .foregroundStyle(stale ? Tokens.Palette.warning : Tokens.Palette.primary)
            if width >= 610 {
                Text(item.ports.isEmpty ? "—" : item.ports.map(String.init).joined(separator: ", "))
                    .frame(width: 66, alignment: .trailing)
                    .lineLimit(1)
                    .help(item.ports.map(String.init).joined(separator: ", "))
            }
        }
        .font(Tokens.Typography.metadata)
        .foregroundStyle(Tokens.Palette.primary)
        .monospacedDigit()
        .frame(minHeight: Tokens.Layout.tableRow)
        .contentShape(Rectangle())
        .help("\(item.name) · \(item.kindLabel) · \(displayedState)\n\(item.image)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.kindLabel), \(item.engineLabel), \(displayedState)")
        .accessibilityValue(
            "CPU \(item.cpuCores.map { String(format: "%.2f cores", $0) } ?? "unavailable"), memory \(item.memoryBytes.map(ByteFormat.string) ?? "unavailable")"
        )
    }

    private var stateColor: Color {
        guard runtimeAvailable else { return Tokens.Palette.tertiary }
        return switch item.state {
        case "running": Tokens.Palette.success
        case "failed", "error": Tokens.Palette.danger
        case "starting", "stopping", "created": Tokens.Palette.accentText
        default: Tokens.Palette.tertiary
        }
    }
}
