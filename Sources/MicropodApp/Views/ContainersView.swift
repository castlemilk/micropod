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
    @State private var showCompactDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Incremented per refresh tap — drives the rotate symbol effect.
    @State private var refreshTicks = 0

    var body: some View {
        GeometryReader { geometry in
            let showsInspector = geometry.size.width >= 880
            VStack(spacing: 0) {
                WorkspacePageHeader(
                    title: "Containers",
                    subtitle:
                        "\(store.containers.count(where: { $0.state == "running" })) running · \(store.containers.count) total",
                    icon: "container", fallback: "shippingbox"
                )
                .padding(.horizontal, Tokens.Spacing.contentInset)
                .padding(.vertical, Tokens.Spacing.lg)
                Divider()
                Group {
                    if showsInspector {
                        HSplitView {
                            containerListColumn
                                .frame(minWidth: 340, idealWidth: 520, maxWidth: .infinity)
                            detailView
                                .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity)
                        }
                    } else if showCompactDetail, selection != nil {
                        VStack(spacing: 0) {
                            HStack {
                                Button {
                                    showCompactDetail = false
                                } label: {
                                    Label("Containers", systemImage: "chevron.left")
                                }
                                .buttonStyle(.borderless)
                                Spacer()
                            }
                            .padding(8)
                            Divider()
                            detailView
                        }
                    } else {
                        containerListColumn
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .toolbar { containerToolbar }
            .onChange(of: selection) { _, selected in
                if !showsInspector, selected != nil { showCompactDetail = true }
            }
            .onChange(of: showsInspector) { _, showsInspector in
                if !showsInspector, selection != nil { showCompactDetail = true }
            }
            .onChange(of: store.selectedContainerID) { _, selected in
                if selected != selection { selection = selected }
            }
            .onAppear {
                selection = store.selectedContainerID
                if !showsInspector, selection != nil { showCompactDetail = true }
            }
        }
        .background(Tokens.Palette.canvas)
        .sheet(isPresented: $showRunSheet) { RunContainerSheet(store: store) }
        .onChange(of: store.pendingRunSheet) { _, pending in
            if pending {
                showRunSheet = true
                store.pendingRunSheet = false
            }
        }
        .onAppear { applyFilter() }
        .onChange(of: store.containers) {
            applyFilter()
            if let selected = selection, !store.containers.contains(where: { $0.id == selected }) {
                selection = nil
                showCompactDetail = false
            }
        }
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
            if !reduceMotion { refreshTicks += 1 }
            Task { await store.refreshContainers() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13))
                .symbolEffect(.rotate.byLayer, value: refreshTicks)
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

    private var containerListColumn: some View {
        GeometryReader { geometry in
            containerInventoryColumn(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func containerInventoryColumn(width: CGFloat) -> some View {
        let layout = ContainerColumnLayout.compute(visible: visibleColumns, width: width)
        return VStack(spacing: 0) {
            filterBar(width: width)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            tableHeader(layout: layout)

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
                        selectableRow(container, layout: layout)
                            .tag(container.id)
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isSelecting {
                        selectionBar(width: width)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else {
                List(selection: $selection) {
                    ForEach(displayed) { container in
                        containerListRow(container, layout: layout)
                            .tag(container.id)
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    selection = container.id
                                    showCompactDetail = true
                                })
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isSelecting)
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
            WorkspaceSelectionPlaceholder(
                title: String(localized: "Select a Container"),
                description: String(
                    localized: "Choose a container to inspect logs, stats, files, and configuration."),
                icon: "container", fallback: "shippingbox"
            )
        }
    }

    // MARK: - Sortable table header (2.1)
    // Renders one header cell per layout spec so the header aligns with the
    // rows' cells at every width the layout can produce.

    private func tableHeader(layout: ContainerColumnLayout) -> some View {
        HStack(spacing: ContainerColumnLayout.spacing) {
            ForEach(layout.specs) { spec in
                sortButton(spec.key, title: spec.key.title, width: spec.width)
            }
            Spacer(minLength: 2)
            columnPicker
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
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

    private func containerListRow(_ container: Micropod_V1_Container, layout: ContainerColumnLayout) -> some View {
        ContainerRowView(
            container: container,
            stats: store.statsByID[container.id],
            layout: layout
        )
        .contextMenu {
            contextMenu(for: container)
        }
    }

    private func selectableRow(_ container: Micropod_V1_Container, layout: ContainerColumnLayout) -> some View {
        ContainerRowView(
            container: container,
            stats: store.statsByID[container.id],
            layout: layout
        )
        .contextMenu {
            contextMenu(for: container)
        }
    }

    @ViewBuilder
    private func filterBar(width: CGFloat) -> some View {
        if width >= 500 {
            HStack(spacing: 6) {
                searchField.frame(minWidth: 150, maxWidth: .infinity)
                filterPicker
            }
        } else {
            VStack(spacing: 8) {
                searchField
                filterPicker
            }
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(ContainerFilter.allCases) { filter in
                Text(filter.title)
                    .tag(filter)
                    .accessibilityIdentifier("containers.filter.\(filter.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 12)
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
        .cardSurface(cornerRadius: 8, fillOpacity: 0.5)
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
    private func selectionBar(width: CGFloat) -> some View {
        SelectionActionBar(count: batchSelection.count) {
            if width < 880 {
                Menu("Actions") { batchActions }
                    .disabled(batchSelection.isEmpty)
            } else {
                batchActions
            }
        } onDone: {
            isSelecting = false
            batchSelection.removeAll()
        }
    }

    @ViewBuilder
    private var batchActions: some View {
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
        case .id: nameCell(width: spec.width ?? ContainerColumnLayout.minName)
        case .image: imageCell.frame(width: spec.width, alignment: .leading)
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

    private func nameCell(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            stateIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(container.id)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Tokens.Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(container.id)
                Text(workloadMetadataSummary)
                    .font(.caption2)
                    .foregroundStyle(Tokens.Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(workloadMetadataSummary)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var imageCell: some View {
        Text(container.image)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(container.image + (container.platform.isEmpty ? "" : " · \(container.platform)"))
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
        WorkspaceStatusBadge(title: container.state, color: stateColor)
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
        var keys = visible.union([.id])
        let order: [ContainerSortKey] = [.id, .image, .state, .ports, .cpu, .memory, .created]
        // Include list insets and the header's column menu in the budget.
        let usable = max(0, width - 60)
        func requiredWidth() -> CGFloat {
            let columnWidths = keys.reduce(CGFloat.zero) { total, key in
                total + (key == .id ? minName : key == .image ? minImage : fixedWidths[key] ?? 0)
            }
            return columnWidths + CGFloat(max(0, keys.count - 1)) * spacing
        }
        for drop in dropOrder {
            if requiredWidth() <= usable { break }
            keys.remove(drop)
        }
        let columns = order.filter { keys.contains($0) }
        let extra = max(0, usable - requiredWidth())
        let specs = columns.map { key in
            let cellWidth: CGFloat
            switch key {
            case .id: cellWidth = minName + extra * (keys.contains(.image) ? 0.6 : 1)
            case .image: cellWidth = minImage + extra * 0.4
            default: cellWidth = fixedWidths[key] ?? 0
            }
            return Spec(key: key, width: cellWidth)
        }
        return ContainerColumnLayout(specs: specs)
    }

    func contains(_ key: ContainerSortKey) -> Bool {
        specs.contains { $0.key == key }
    }
}

/// Metadata remains readable at compact sheet widths; the original value is
/// always available through selection, help, and the copy action.
struct InventoryCopyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(label)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.subheadline.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(label)")
            .accessibilityLabel("Copy \(label)")
        }
        .padding(.vertical, 4)
    }
}
