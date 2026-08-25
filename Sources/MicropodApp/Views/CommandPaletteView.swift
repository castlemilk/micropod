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
        let resources = resourceItems.filter { $0.matches(q) }
        if !resources.isEmpty { result.append(PaletteSection(title: "Resources", items: resources)) }
        return result
    }

    private var flatItems: [PaletteItem] {
        let items = sections.flatMap(\.items)
        if selection >= items.count { selection = 0 }
        return items
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { store.showCommandPalette = false }

            VStack(spacing: 0) {
                searchField
                Divider()
                if flatItems.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    resultList
                }
                footer
            }
            .frame(width: 560, height: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .onExitCommand { store.showCommandPalette = false }
        }
        .onAppear {
            searchFocused = true
            selection = 0
            if let previous = UserDefaults.standard.string(forKey: Self.lastQueryKey) {
                query = previous
            }
        }
        .onDisappear {
            UserDefaults.standard.set(query, forKey: Self.lastQueryKey)
        }
    }

    private var searchField: some View {
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
                    selection = (selection - 1 + flatItems.count) % flatItems.count
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !flatItems.isEmpty else { return .handled }
                    selection = (selection + 1) % flatItems.count
                    return .handled
                }
                .onSubmit {
                    guard !flatItems.isEmpty, flatItems.indices.contains(selection) else { return }
                    run(flatItems[selection])
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var resultList: some View {
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
                            row(item)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: selection) { _, newValue in
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

    private func row(_ item: PaletteItem) -> some View {
        let index = flatItems.firstIndex { $0.id == item.id } ?? 0
        let isSelected = index == selection
        return Button {
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

    private var resourceItems: [PaletteItem] {
        // Filter the FULL arrays first — the palette must stay a real search
        // no matter how many resources exist — then cap only for rendering.
        let q = query.lowercased()
        func matches(_ title: String, _ subtitle: String?) -> Bool {
            guard !q.isEmpty else { return true }
            return title.lowercased().contains(q) || subtitle?.lowercased().contains(q) == true
        }
        var items: [PaletteItem] = []
        items += store.containers
            .filter { matches($0.id, $0.image) }
            .prefix(15)
            .map { container in
                PaletteItem(
                    icon: "shippingbox",
                    title: container.id,
                    subtitle: container.image,
                    badge: container.state,
                    action: .selectContainer(container.id))
            }
        items += store.images
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
        items += store.volumes
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
        items += store.networks
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
        case .selectContainer(let id):
            store.activeTab = .containers
            store.selectedContainerID = id
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
            store.activeTab = .containers
            store.pendingRunSheet = true
        case .pullImage:
            store.activeTab = .images
            store.pendingPullSheet = true
        case .refreshAll: Task { await store.refreshAll() }
        case .startRuntime: Task { await store.startRuntime() }
        case .stopRuntime: Task { await store.stopRuntime() }
        case .installKernel: Task { await store.installRecommendedKernel() }
        case .pruneContainers: Task { await store.pruneContainers() }
        }
    }
}

/// One palette row.
struct PaletteItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    let action: PaletteAction
    var isEnabled = true

    func matches(_ query: String) -> Bool {
        title.lowercased().contains(query) || subtitle?.lowercased().contains(query) == true
    }
}

enum PaletteAction {
    case switchTab(AppStore.ActiveTab)
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
