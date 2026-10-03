import MicropodCore
import SwiftUI

/// ⌘K command palette: actions + navigation + live resource search.
/// HIG: menu-like card, arrow-key navigation, Return activates, Esc dismisses.
struct CommandPaletteView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    /// ⌘K reopens with the previous query (HIG: state persistence).
    private static let lastQueryKey = "paletteQuery"

    private var sections: [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            return [PaletteSection(title: "Actions", items: actionItems)]
        }
        var result: [PaletteSection] = []
        let actions = actionItems.filter { $0.matches(q) }
        if !actions.isEmpty { result.append(PaletteSection(title: "Actions", items: actions)) }
        let navigate = navigateItems.filter { $0.matches(q) }
        if !navigate.isEmpty { result.append(PaletteSection(title: "Navigate", items: navigate)) }
        let resources = resourceItems(query: q)
        if !resources.isEmpty { result.append(PaletteSection(title: "Resources", items: resources)) }
        return result
    }

    var body: some View {
        // Compute the model once per render — sections filter every resource
        // array, so re-deriving them per accessor tripled the work (and the
        // row lookup was an O(n²) firstIndex scan).
        let sections = self.sections
        let flatItems = sections.flatMap(\.items)
        let effectiveSelection = flatItems.isEmpty ? 0 : min(selection, flatItems.count - 1)
        let indexByID = Dictionary(
            flatItems.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })

        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { store.showCommandPalette = false }

                VStack(spacing: 0) {
                    searchField(flatItems: flatItems, selection: effectiveSelection)
                    Divider()
                    if flatItems.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        resultList(sections: sections, indexByID: indexByID, selection: effectiveSelection)
                    }
                    footer
                }
                .frame(
                    width: min(560, max(0, geometry.size.width - 32)),
                    height: min(380, max(0, geometry.size.height - 32))
                )
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                .onExitCommand { store.showCommandPalette = false }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selection = 0
            if let previous = UserDefaults.standard.string(forKey: Self.lastQueryKey) {
                query = previous
            }
        }
        .task {
            // The overlay's native text field must be installed before it
            // can replace the page's current field editor. Requesting focus
            // during onAppear can leave shortcuts reaching the page below.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, store.showCommandPalette else { return }
            searchFocused = true
        }
        .onDisappear {
            UserDefaults.standard.set(query, forKey: Self.lastQueryKey)
        }
    }

    private func searchField(flatItems: [PaletteItem], selection: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14, weight: .medium))
            TextField("Command palette…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel("Command palette search")
                .accessibilityIdentifier("palette.search")
                .onKeyPress(.upArrow) {
                    guard !flatItems.isEmpty else { return .handled }
                    self.selection = (selection - 1 + flatItems.count) % flatItems.count
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !flatItems.isEmpty else { return .handled }
                    self.selection = (selection + 1) % flatItems.count
                    return .handled
                }
                .onSubmit {
                    guard flatItems.indices.contains(selection) else { return }
                    run(flatItems[selection])
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func resultList(sections: [PaletteSection], indexByID: [PaletteAction: Int], selection: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        Text(section.title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(section.items) { item in
                            row(item, isSelected: indexByID[item.id] == selection)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: selection) { _, newValue in
                let flatItems = sections.flatMap(\.items)
                guard flatItems.indices.contains(newValue) else { return }
                if reduceMotion {
                    proxy.scrollTo(flatItems[newValue].id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(flatItems[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        Button {
            run(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.title)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let badge = item.badge {
                    Text(badge)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(item.id)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ Navigate")
            Text("↵ Run")
            Text("⎋ Dismiss")
            Spacer()
            Text("Micropod")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Items

    private var actionItems: [PaletteItem] {
        [
            PaletteItem(icon: "plus.circle", title: "Run Container…", action: .runContainer),
            PaletteItem(icon: "arrow.down.circle", title: "Pull Image…", action: .pullImage),
            PaletteItem(icon: "arrow.clockwise.circle", title: "Refresh All", action: .refreshAll),
            PaletteItem(
                icon: "play.circle", title: "Start Runtime",
                action: .startRuntime, isEnabled: !store.isRuntimeRunning),
            PaletteItem(
                icon: "stop.circle", title: "Stop Runtime",
                action: .stopRuntime, isEnabled: store.isRuntimeRunning),
            PaletteItem(
                icon: "cpu", title: "Install Recommended Kernel",
                action: .installKernel, isEnabled: !store.isInstallingKernel),
            PaletteItem(icon: "trash", title: "Prune Stopped Containers", action: .pruneContainers),
        ]
    }

    private var navigateItems: [PaletteItem] {
        AppStore.ActiveTab.allCases.map { tab in
            PaletteItem(
                icon: tab.icon,
                title: "Go to \(tab.title)",
                subtitle: nil,
                action: .switchTab(tab))
        }
    }

    private func resourceItems(query q: String) -> [PaletteItem] {
        // Filter the FULL arrays first — the palette must stay a real search
        // no matter how many resources exist — then cap only for rendering.
        let workloadTerms = PaletteSearch.terms(in: q)
        func matches(_ title: String, _ subtitle: String?) -> Bool {
            guard !q.isEmpty else { return true }
            return title.lowercased().contains(q) || subtitle?.lowercased().contains(q) == true
        }
        var items: [PaletteItem] = []
        items += store.workloadItems.lazy
            .filter { PaletteSearch.matchesNormalizedWorkload($0.searchTerms, terms: workloadTerms) }
            .prefix(15)
            .map(PaletteItem.forWorkload)
        items += store.images.lazy
            .filter { matches($0.names.first ?? $0.id, $0.id) }
            .prefix(10)
            .map { image in
                PaletteItem(
                    icon: "photo.stack",
                    title: image.names.first ?? image.id,
                    subtitle: image.id,
                    badge: ByteFormat.string(image.sizeBytes),
                    action: .selectImage(image.id))
            }
        items += store.volumes.lazy
            .filter { matches($0.id, $0.driver) }
            .prefix(8)
            .map { volume in
                PaletteItem(
                    icon: "externaldrive",
                    title: volume.id,
                    subtitle: volume.driver,
                    badge: ByteFormat.string(volume.sizeBytes),
                    action: .selectVolume(volume.id))
            }
        items += store.networks.lazy
            .filter { matches($0.id, "\($0.mode) · \($0.ipv4Subnet)") }
            .prefix(8)
            .map { network in
                PaletteItem(
                    icon: "network",
                    title: network.id,
                    subtitle: "\(network.mode) · \(network.ipv4Subnet)",
                    action: .selectNetwork(network.id))
            }
        return items
    }

    private func run(_ item: PaletteItem) {
        guard item.isEnabled else { return }
        store.showCommandPalette = false
        switch item.action {
        case .switchTab(let tab): store.activeTab = tab
        case .selectWorkload(let route):
            if let item = store.workloadItems.first(where: { $0.route == route }) {
                store.openWorkload(item)
            }
        case .selectContainer(let id):
            store.activeTab = .workloads
            store.selectedContainerID = id
            store.selectedWorkloadID = "container:\(id)"
        case .selectImage(let id):
            store.activeTab = .images
            store.selectedImageID = id
        case .selectVolume(let id):
            store.activeTab = .volumes
            store.selectedVolumeID = id
        case .selectNetwork(let id):
            store.activeTab = .networks
            store.selectedNetworkID = id
        case .runContainer:
            store.activeTab = .workloads
            store.pendingRunSheet = true
        case .pullImage:
            store.activeTab = .images
            store.pendingPullSheet = true
        case .refreshAll: Task { await store.refreshAll() }
        case .startRuntime: Task { await store.startRuntime() }
        case .stopRuntime: store.requestRuntimeStop()
        case .installKernel: Task { await store.installRecommendedKernel() }
        case .pruneContainers: Task { await store.pruneContainers() }
        }
    }
}

/// One palette row.
struct PaletteItem: Identifiable {
    var id: PaletteAction { action }
    let icon: String
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    let action: PaletteAction
    var isEnabled = true
    var searchTerms: String? = nil

    func matches(_ query: String) -> Bool {
        if let searchTerms { return PaletteSearch.matchesWorkload(searchTerms, query: query) }
        return title.lowercased().contains(query) || subtitle?.lowercased().contains(query) == true
    }

    static func forWorkload(_ workload: WorkloadItem) -> PaletteItem {
        PaletteItem(
            icon: workload.kind == .machine ? "server.rack" : "shippingbox",
            title: workload.name,
            subtitle: "\(workload.kindLabel) · \(workload.engineLabel) · \(workload.project)",
            badge: workload.state, action: .selectWorkload(workload.route),
            searchTerms: workload.searchTerms)
    }
}

/// The palette uses the inventory's real indexed metadata at both filter
/// stages. Static commands keep their existing title/subtitle matching.
enum PaletteSearch {
    static func terms(in query: String) -> [Substring] {
        query.lowercased().split(whereSeparator: \.isWhitespace)
    }

    /// Inventory metadata is already normalized. Parse the query once for
    /// the whole search, and stop scanning once the result limit is reached.
    static func matchesNormalizedWorkload(_ searchTerms: String, terms: [Substring]) -> Bool {
        terms.allSatisfy { searchTerms.contains($0) }
    }

    static func matchesWorkload(_ searchTerms: String, query: String) -> Bool {
        matchesNormalizedWorkload(searchTerms.lowercased(), terms: terms(in: query))
    }
}

enum PaletteAction: Hashable {
    case switchTab(AppStore.ActiveTab)
    case selectWorkload(WorkloadRoute)
    case selectContainer(String)
    case selectImage(String)
    case selectVolume(String)
    case selectNetwork(String)
    case runContainer
    case pullImage
    case refreshAll
    case startRuntime
    case stopRuntime
    case installKernel
    case pruneContainers
}

struct PaletteSection: Identifiable {
    let title: String
    let items: [PaletteItem]
    var id: String { title }
}
