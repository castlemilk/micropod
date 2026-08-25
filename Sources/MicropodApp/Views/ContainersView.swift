import MicropodCore
import SwiftUI

/// Containers tab: searchable/filterable, sortable table + detail pane.
struct ContainersView: View {
    @Bindable var store: AppStore

    @State private var searchText = ""
    @State private var filter: ContainerFilter = .all
    @State private var displayed: [Micropod_V1_Container] = []
    @State private var selection: String?
    @State private var showRunSheet = false
    @State private var confirmDeleteID: String?
    @State private var confirmDeleteIDs: Set<String> = []
    @State private var confirmPrune = false
    /// Multi-select mode (HIG: explicit mode toggles batch actions safely).
    @State private var isSelecting = false
    @State private var batchSelection: Set<String> = []
    /// Sort state (2.1 — sortable dense table).
    @State private var sortKey: ContainerSortKey = .id
    @State private var sortAscending = true
    @State private var visibleColumns: Set<ContainerSortKey> = [.id, .image, .state, .ports, .cpu, .memory]
    /// Available width of the table column — drives the responsive layout.
    @State private var tableWidth: CGFloat = 340
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columnLayout: ContainerColumnLayout {
        ContainerColumnLayout.compute(visible: visibleColumns, width: tableWidth)
    }

    var body: some View {
        NavigationSplitView {
            containerListColumn
                .toolbar { containerToolbar }
                .sheet(isPresented: $showRunSheet) {
                    RunContainerSheet(store: store)
                }
                .onChange(of: store.pendingRunSheet) { _, pending in
                    if pending {
                        showRunSheet = true
                        store.pendingRunSheet = false
                    }
                }
        } detail: {
            detailView
        }
        .onAppear { applyFilter() }
        .onChange(of: store.containers) { applyFilter() }
        .onChange(of: searchText) { applyFilter() }
        .onChange(of: filter) { applyFilter() }
        .onChange(of: sortKey) { applyFilter() }
        .onChange(of: sortAscending) { applyFilter() }
        .onChange(of: store.statsByID) {
            if sortKey == .cpu || sortKey == .memory {
                applyFilter()
            }
        }
        .onChange(of: selection) { _, newValue in
            store.selectedContainerID = newValue
        }
        .confirmationDialog(
            "Delete Container?",
            isPresented: Binding(
                get: { confirmDeleteID != nil },
                set: { if !$0 { confirmDeleteID = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteID {
                    confirmDeleteID = nil
                    Task { await store.deleteContainer(id, force: true) }
                }
            }
            Button("Cancel", role: .cancel) { confirmDeleteID = nil }
        } message: {
            Text("Deleting a container is irreversible. This removes the container and its writable layer.")
        }
        .confirmationDialog(
            "Prune Stopped Containers?",
            isPresented: $confirmPrune
        ) {
            Button("Prune Stopped Containers", role: .destructive) {
                Task { await store.pruneContainers() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every stopped container and its writable layer.")
        }
        .confirmationDialog(
            "Delete \(confirmDeleteIDs.count) containers?",
            isPresented: Binding(
                get: { !confirmDeleteIDs.isEmpty },
                set: { if !$0 { confirmDeleteIDs = [] } })
        ) {
            Button("Delete \(confirmDeleteIDs.count) Containers", role: .destructive) {
                let ids = Array(confirmDeleteIDs)
                confirmDeleteIDs = []
                Task {
                    await store.batchDelete(ids)
                    batchSelection.removeAll()
                    isSelecting = false
                }
            }
            Button("Cancel", role: .cancel) { confirmDeleteIDs = [] }
        } message: {
            Text(confirmDeleteIDs.sorted().joined(separator: "\n"))
        }
    }

    @ToolbarContentBuilder
    private var containerToolbar: some ToolbarContent {
        ToolbarItemGroup {
            toolbarRefresh
            toolbarSelect
            bulkMenu
            toolbarRun
        }
    }

    @ViewBuilder
    private var toolbarRefresh: some View {
        Button {
            Task { await store.refreshContainers() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13))
        }
        .help("Refresh containers")
        .accessibilityLabel("Refresh containers")
    }

    @ViewBuilder
    private var toolbarSelect: some View {
        Button {
            isSelecting.toggle()
            batchSelection.removeAll()
        } label: {
            Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .help(isSelecting ? "Done selecting" : "Select multiple containers")
        .accessibilityLabel(isSelecting ? "Done selecting" : "Select multiple containers")
    }

    @ViewBuilder
    private var toolbarRun: some View {
        Button {
            showRunSheet = true
        } label: {
            IconLabel(title: "Run", icon: "start")
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    @ViewBuilder
    private var containerListColumn: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            tableHeader

            if store.containers.isEmpty && store.clientAvailable && !hasSearchQuery && filter == .all {
                EmptyStateView(
                    title: String(localized: "No Containers"),
                    description: String(localized: "Run an image to create your first container."),
                    imageName: EmptyStateArtwork.containers,
                    symbol: "shippingbox",
                    actionTitle: String(localized: "Run Container…"),
                    action: { store.pendingRunSheet = true }
                )
            } else if displayed.isEmpty {
                EmptyStateView(
                    title: emptyResultsTitle,
                    description: emptyResultsDescription,
                    symbol: emptyResultsSymbol
                )
            } else if isSelecting {
                List(selection: $batchSelection) {
                    ForEach(displayed) { container in
                        selectableRow(container)
                            .tag(container.id)
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isSelecting {
                        selectionBar
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else {
                List(selection: $selection) {
                    ForEach(displayed) { container in
                        containerListRow(container)
                            .tag(container.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            tableWidth = $0
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isSelecting)
        .navigationSplitViewColumnWidth(min: 300, ideal: 460)
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Containers")
    }

    @ViewBuilder
    private var detailView: some View {
        if let selected = selection ?? store.selectedContainerID,
            store.containers.contains(where: { $0.id == selected })
        {
            ContainerDetailView(store: store, containerID: selected)
                .id(selected)
        } else {
            EmptyStateView(
                title: String(localized: "Select a Container"),
                description: String(
                    localized: "Choose a container to inspect logs, stats, files, and configuration."),
                symbol: "shippingbox"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
    }

    // MARK: - Sortable table header (2.1)
    // Renders one header cell per layout spec so the header aligns with the
    // rows' cells at every width the layout can produce.

    private var tableHeader: some View {
        HStack(spacing: ContainerColumnLayout.spacing) {
            ForEach(columnLayout.specs) { spec in
                sortButton(spec.key, title: spec.key.title, width: spec.width)
            }
            Spacer(minLength: 2)
            columnPicker
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func sortButton(_ key: ContainerSortKey, title: String, width: CGFloat?) -> some View {
        Button {
            if sortKey == key {
                sortAscending.toggle()
            } else {
                sortKey = key
                sortAscending = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment(for: key))
        .frame(
            minWidth: width
                ?? (key == .id ? ContainerColumnLayout.minName : ContainerColumnLayout.minImage),
            alignment: alignment(for: key)
        )
        .help("Sort by \(title)")
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(
            sortKey == key
                ? (sortAscending ? "Ascending" : "Descending")
                : "Not selected")
    }

    private func alignment(for key: ContainerSortKey) -> Alignment {
        key == .cpu || key == .memory || key == .created ? .trailing : .leading
    }

    private var columnPicker: some View {
        Menu {
            ForEach(ContainerSortKey.allCases) { key in
                if key != .id {
                    Button {
                        if visibleColumns.contains(key) {
                            visibleColumns.remove(key)
                        } else {
                            visibleColumns.insert(key)
                        }
                    } label: {
                        if visibleColumns.contains(key) {
                            Label(key.title, systemImage: "checkmark")
                        } else {
                            Text(key.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose columns")
        .accessibilityLabel("Choose columns")
    }

    // MARK: - Rows

    private func containerListRow(_ container: Micropod_V1_Container) -> some View {
        ContainerRowView(
            container: container,
            stats: store.statsByID[container.id],
            layout: columnLayout
        )
        .contextMenu {
            contextMenu(for: container)
        }
    }

    private func selectableRow(_ container: Micropod_V1_Container) -> some View {
        ContainerRowView(
            container: container,
            stats: store.statsByID[container.id],
            layout: columnLayout
        )
        .contextMenu {
            contextMenu(for: container)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            searchField
            Picker("Filter", selection: $filter) {
                ForEach(ContainerFilter.allCases) { f in
                    Text(f.title)
                        .tag(f)
                        .accessibilityIdentifier("containers.filter.\(f.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 224)
        }
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyResultsTitle: String {
        if hasSearchQuery {
            return String(localized: "No Matching Containers")
        }

        switch filter {
        case .all: return String(localized: "No Containers")
        case .running: return String(localized: "No Running Containers")
        case .stopped: return String(localized: "No Stopped Containers")
        case .agents: return String(localized: "No Agent Containers")
        }
    }

    private var emptyResultsDescription: String {
        if hasSearchQuery {
            return String(localized: "No containers match that name, image, or label.")
        }

        switch filter {
        case .all: return String(localized: "Run an image to create your first container.")
        case .running: return String(localized: "No containers are currently running.")
        case .stopped: return String(localized: "No containers are currently stopped.")
        case .agents:
            return String(localized: "Agent workloads appear here when they carry a supported agent label.")
        }
    }

    private var emptyResultsSymbol: String {
        if hasSearchQuery {
            return "magnifyingglass"
        }

        switch filter {
        case .all: return "shippingbox"
        case .running: return "play.circle"
        case .stopped: return "stop.circle"
        case .agents: return "person.crop.circle.badge.checkmark"
        }
    }

    private var bulkMenu: some View {
        Menu {
            Button(role: .destructive) {
                Task { await store.stopAllContainers() }
            } label: {
                MenuItemIconLabel(title: "Stop All", icon: "stop", fallback: "stop.fill")
            }
            Button(role: .destructive) {
                confirmDeleteIDs = Set(displayed.map(\.id))
            } label: {
                MenuItemIconLabel(title: "Delete All Shown (\(displayed.count))", icon: "deleteall", fallback: "trash")
            }
            Button(role: .destructive) {
                confirmDeleteIDs = []
                confirmPrune = true
            } label: {
                MenuItemIconLabel(title: "Prune Stopped Containers", icon: "prune", fallback: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More container actions")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search containers")
                .accessibilityIdentifier("containers.search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func applyFilter() {
        let createdDates = displayedCreatedDates()
        displayed = store.containers.filter { container in
            switch filter {
            case .all: true
            case .running: container.state == "running"
            case .stopped: container.state != "running"
            case .agents: WorkloadMetadata(labels: container.labels).isAgent
            }
        }.filter { container in
            workloadMatchesQuery(
                query: searchText,
                id: container.id,
                image: container.image,
                labels: container.labels
            )
        }.sorted(by: { lhs, rhs in
            sortAscending
                ? compare(lhs, rhs, createdDates: createdDates)
                : compare(rhs, lhs, createdDates: createdDates)
        })
    }

    /// createdAt parsed once per sort pass (parseDate was per-comparison).
    private func displayedCreatedDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        dates.reserveCapacity(store.containers.count)
        for container in store.containers {
            dates[container.id] = parseDate(container.createdAt) ?? .distantPast
        }
        return dates
    }

    /// Three-way comparison for the active sort key.
    private func compare(
        _ lhs: Micropod_V1_Container,
        _ rhs: Micropod_V1_Container,
        createdDates: [String: Date]
    ) -> Bool {
        switch sortKey {
        case .id:
            return idPrecedes(lhs.id, rhs.id)
        case .image:
            let order = lhs.image.localizedCaseInsensitiveCompare(rhs.image)
            return order == .orderedSame ? idPrecedes(lhs.id, rhs.id) : order == .orderedAscending
        case .state:
            let l = stateRank(lhs.state), r = stateRank(rhs.state)
            return valuePrecedes(l, r, lhsID: lhs.id, rhsID: rhs.id)
        case .ports:
            return valuePrecedes(
                lhs.publishedPorts.first?.hostPort ?? 0,
                rhs.publishedPorts.first?.hostPort ?? 0,
                lhsID: lhs.id,
                rhsID: rhs.id)
        case .cpu:
            return valuePrecedes(
                store.statsByID[lhs.id]?.cpuPercent ?? 0,
                store.statsByID[rhs.id]?.cpuPercent ?? 0,
                lhsID: lhs.id,
                rhsID: rhs.id)
        case .memory:
            return valuePrecedes(
                store.statsByID[lhs.id]?.memoryUsedBytes ?? 0,
                store.statsByID[rhs.id]?.memoryUsedBytes ?? 0,
                lhsID: lhs.id,
                rhsID: rhs.id)
        case .created:
            return valuePrecedes(
                createdDates[lhs.id] ?? .distantPast,
                createdDates[rhs.id] ?? .distantPast,
                lhsID: lhs.id,
                rhsID: rhs.id)
        }
    }

    private func valuePrecedes<T: Comparable>(
        _ lhs: T, _ rhs: T, lhsID: String, rhsID: String
    ) -> Bool {
        lhs == rhs ? idPrecedes(lhsID, rhsID) : lhs < rhs
    }

    private func idPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedCaseInsensitiveCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }

    private func stateRank(_ state: String) -> Int {
        switch state {
        case "running": 0
        case "created": 1
        case "exited": 2
        case "stopped": 3
        default: 4
        }
    }

    /// Embedded multi-select action bar (floating bottom capsule).
    private var selectionBar: some View {
        SelectionActionBar(count: batchSelection.count) {
            Button {
                runBatch(store.batchStart)
            } label: {
                IconLabel(title: "Start", icon: "start", fallback: "play.fill")
            }
            Button {
                runBatch(store.batchStop)
            } label: {
                IconLabel(title: "Stop", icon: "stop", fallback: "stop.fill")
            }
            Button {
                runBatch(store.batchRestart)
            } label: {
                IconLabel(title: "Restart", icon: "restart", fallback: "arrow.clockwise")
            }
            Button {
                runBatch(store.batchKill)
            } label: {
                IconLabel(title: "Kill", icon: "kill", fallback: "bolt")
            }
            .foregroundStyle(.orange)
            Button(role: .destructive) {
                confirmDeleteIDs = batchSelection
            } label: {
                IconLabel(title: "Delete…", icon: "delete", fallback: "trash")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(batchSelection.sorted().joined(separator: "\n"), forType: .string)
            } label: {
                IconLabel(title: "Copy IDs", icon: "copy", fallback: "doc.on.doc")
            }
        } onDone: {
            isSelecting = false
            batchSelection.removeAll()
        }
    }

    private func runBatch(_ action: @escaping ([String]) async -> Void) {
        let ids = Array(batchSelection)
        Task {
            await action(ids)
            batchSelection.removeAll()
            isSelecting = false
        }
    }

    @ViewBuilder
    private func contextMenu(for container: Micropod_V1_Container) -> some View {
        if container.state == "running" {
            Button {
                Task { await store.stopContainer(container.id) }
            } label: {
                MenuItemIconLabel(title: "Stop", icon: "stop", fallback: "stop.fill")
            }
            Button {
                Task { await store.restartContainer(container.id) }
            } label: {
                MenuItemIconLabel(title: "Restart", icon: "restart", fallback: "arrow.clockwise")
            }
            Button {
                Task { await store.killContainer(container.id) }
            } label: {
                MenuItemIconLabel(title: "Kill", icon: "kill", fallback: "xmark.octagon")
            }
        } else {
            Button {
                Task { await store.startContainer(container.id) }
            } label: {
                MenuItemIconLabel(title: "Start", icon: "start", fallback: "play.fill")
            }
        }
        Button(role: .destructive) {
            confirmDeleteID = container.id
        } label: {
            MenuItemIconLabel(title: "Delete", icon: "delete", fallback: "trash")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        } label: {
            MenuItemIconLabel(title: "Copy ID", icon: "copy", fallback: "doc.on.doc")
        }
    }
}

/// A container list row. `@MainActor Equatable` prevents parent re-render
/// cascades (perf checklist). Renders one aligned cell per layout spec so
/// values line up with the sortable header at any window width.
struct ContainerRowView: View, @MainActor Equatable {
    let container: Micropod_V1_Container
    let stats: Micropod_V1_ContainerStats?
    let layout: ContainerColumnLayout

    static func == (lhs: ContainerRowView, rhs: ContainerRowView) -> Bool {
        lhs.container == rhs.container
            && lhs.stats == rhs.stats
            && lhs.layout == rhs.layout
    }

    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(layout.specs) { spec in
                cell(spec)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func cell(_ spec: ContainerColumnLayout.Spec) -> some View {
        switch spec.key {
        case .id: nameCell(minWidth: spec.width ?? ContainerColumnLayout.minName)
        case .image: imageCell
        case .state: fixedCell(spec.width, alignment: .leading) { statePill }
        case .ports: fixedCell(spec.width, alignment: .leading) { portsText }
        case .cpu: fixedCell(spec.width, alignment: .trailing) { cpuText }
        case .memory: fixedCell(spec.width, alignment: .trailing) { memoryText }
        case .created: fixedCell(spec.width, alignment: .trailing) { createdText }
        }
    }

    private func fixedCell<Content: View>(
        _ width: CGFloat?, alignment: Alignment, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: width, alignment: alignment)
            .lineLimit(1)
    }

    // MARK: - Cells

    private func nameCell(minWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            stateIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(container.id)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(workloadMetadataSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(workloadMetadataSummary)
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .layoutPriority(1)
    }

    private var imageCell: some View {
        Text(container.image)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(container.image + (container.platform.isEmpty ? "" : " · \(container.platform)"))
            .frame(minWidth: ContainerColumnLayout.minImage, alignment: .leading)
    }

    /// Uptime joins the metadata line only when the row is roomy (several
    /// columns still visible); compact layouts stay at two lines total.
    private var showUptimeUnderName: Bool {
        layout.specs.count >= 4
    }

    private var workloadMetadataSummary: String {
        let metadata = WorkloadMetadata(labels: container.labels)
        var parts: [String] = []
        if metadata.isAgent {
            parts.append("Agent")
        }
        parts.append(metadata.source.rawValue)
        if let jobID = metadata.jobID {
            parts.append("Job \(jobID)")
        }
        if let owner = metadata.owner {
            parts.append("Owner \(owner)")
        }
        if showUptimeUnderName, let uptime {
            parts.append(uptime)
        }
        return parts.joined(separator: " · ")
    }

    private var portsText: some View {
        Group {
            if container.publishedPorts.isEmpty {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(
                    container.publishedPorts
                        .map { "\($0.hostPort):\($0.containerPort)" }
                        .joined(separator: ", ")
                )
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
            }
        }
    }

    private var cpuText: some View {
        Group {
            if let stats {
                Text(String(format: "%.1f%%", stats.cpuPercent))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var memoryText: some View {
        Group {
            if let stats {
                Text(ByteFormat.string(stats.memoryUsedBytes))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var createdText: some View {
        Text(relativeCreated)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - State styling

    private var stateIcon: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 7, height: 7)
    }

    private var stateColor: Color { ContainerStateStyle.color(for: container.state) }

    private var statePill: some View {
        Text(container.state)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(stateColor.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(stateColor.opacity(0.4), lineWidth: 1))
            .foregroundStyle(stateColor)
    }

    private var uptime: String? {
        guard container.state == "running" else { return nil }
        guard let date = parseDate(container.createdAt) else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    private var relativeCreated: String {
        guard let date = parseDate(container.createdAt) else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// Filter options for the containers list.
enum ContainerFilter: String, CaseIterable, Identifiable {
    case all, running, stopped, agents
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Sortable table columns for the containers list (2.1).
enum ContainerSortKey: String, CaseIterable, Identifiable {
    case id, image, state, ports, cpu, memory, created
    var id: String { rawValue }
    var title: String {
        switch self {
        case .id: "Name"
        case .cpu: "CPU"
        default: rawValue.capitalized
        }
    }
}

/// Responsive table layout: fixed-width columns are dropped by priority as
/// the window narrows; Name always stays and shares the flexible remainder
/// with Image. The same specs drive the header and every row so columns
/// align regardless of content width.
struct ContainerColumnLayout: Equatable {
    struct Spec: Identifiable, Equatable {
        let key: ContainerSortKey
        let width: CGFloat?
        var id: String { key.rawValue }
    }

    let specs: [Spec]

    private static let dropOrder: [ContainerSortKey] = [.created, .ports, .memory, .cpu, .image, .state]
    private static let fixedWidths: [ContainerSortKey: CGFloat] = [
        .state: 76, .ports: 96, .cpu: 56, .memory: 70, .created: 62,
    ]
    static let minName: CGFloat = 118
    static let minImage: CGFloat = 92
    static let spacing: CGFloat = 8

    static func compute(visible: Set<ContainerSortKey>, width: CGFloat) -> ContainerColumnLayout {
        var keys = visible
        // List rows apply their own horizontal insets (~28pt) on top of the
        // pane width — budget for them or flexible cells get squeezed.
        let usable = max(0, width - 36)
        func requiredWidth() -> CGFloat {
            var total = minName + spacing
            if keys.contains(.image) {
                total += minImage + spacing
            }
            for key in keys where fixedWidths[key] != nil {
                total += fixedWidths[key]! + spacing
            }
            return total
        }
        for drop in dropOrder {
            if requiredWidth() <= usable {
                break
            }
            keys.remove(drop)
        }
        let order: [ContainerSortKey] = [.id, .image, .state, .ports, .cpu, .memory, .created]
        let specs: [Spec] =
            order
            .filter { key in key == .id || keys.contains(key) }
            .map { key in Spec(key: key, width: fixedWidths[key]) }
        return ContainerColumnLayout(specs: specs)
    }

    func contains(_ key: ContainerSortKey) -> Bool {
        specs.contains { $0.key == key }
    }
}
