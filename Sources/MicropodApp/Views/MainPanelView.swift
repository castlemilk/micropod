import MicropodCore
import SwiftUI

/// Main window shell: an adaptive sidebar that goes full → icon rail →
/// collapsed as the window narrows (HIG Finder-style rail), with the runtime
/// status always reachable. Custom HStack shell (not NavigationSplitView) so
/// the inner tab splits never fight the app sidebar for space.
struct MainPanelView: View {
    @Bindable var store: AppStore

    // Width thresholds (pt): above 1040 = full labelled sidebar;
    // 640–1040 = icon-only rail; below 640 = no sidebar (toolbar dot).
    // The full sidebar is expensive (200 pt) — keep it until the window is
    // genuinely wide so two-column tabs always have room.
    private let fullThreshold: CGFloat = 1040
    private let railThreshold: CGFloat = 640

    @State private var lastKnownWidth: CGFloat?
    @State private var resourcesExpanded = false
    @State private var projectsExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                if width >= railThreshold {
                    if width >= fullThreshold {
                        fullSidebar
                    } else {
                        iconRail
                    }
                    Divider()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !store.operations.isEmpty {
                            OperationsDrawerView(store: store, maximumListHeight: min(150, geo.size.height * 0.24))
                        }
                    }
                    .navigationTitle("Micropod")
                    .toolbar {
                        if width < railThreshold {
                            ToolbarItem(placement: .navigation) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                    .help(statusText)
                                    .accessibilityLabel(statusText)
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                store.showCommandPalette = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                    Text(width < 900 ? "Search" : "Search or run a command")
                                    Text("⌘K").foregroundStyle(Tokens.Palette.tertiary)
                                }
                                .font(Tokens.Typography.body)
                            }
                            .keyboardShortcut("k", modifiers: .command)
                            .help("Command Palette (⌘K)")
                        }
                    }
            }
            .background(Tokens.Palette.canvas)
            .tint(Tokens.Palette.accent)
            .onAppear { lastKnownWidth = width }
        }
        .task { store.bootstrap() }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onChange(of: store.activeTab) { _, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: UserDefaultsKeys.lastTab)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                UpdateBanner(updates: UpdateController.shared)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                if let error = store.lastRefreshError {
                    ErrorBanner(message: error) { store.lastRefreshError = nil }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .transition(
                            reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .overlay {
            if store.showCommandPalette {
                CommandPaletteView(store: store)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: store.showCommandPalette)
        .confirmationDialog(
            "Stop the runtime?", isPresented: $store.runtimeStopConfirmationRequested, titleVisibility: .visible
        ) {
            Button("Stop runtime", role: .destructive) { Task { await store.stopRuntime() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This interrupts \(store.runtimeStopAffectedCount) running workloads managed by the Apple runtime. You can start the runtime again from Micropod."
            )
        }
    }

    // MARK: - Full sidebar

    private var fullSidebar: some View {
        List(selection: $store.activeTab) {
            Section {
                HStack(spacing: 10) {
                    BrandMark(size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Micropod").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tokens.Palette.primary)
                        Text("Local workspace").font(Tokens.Typography.metadata)
                            .foregroundStyle(Tokens.Palette.secondary)
                    }
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
            }
            Section("Workspace") {
                tabRow(.dashboard)
                tabRow(.workloads)
                tabRow(.machines)
                tabRow(.images)
                tabRow(.cache)
                tabRow(.storage)
                tabRow(.build)
            }
            Section {
                DisclosureGroup("Resources", isExpanded: $resourcesExpanded) {
                    tabRow(.containers)
                    tabRow(.volumes)
                    tabRow(.networks)
                    tabRow(.registries)
                }
                DisclosureGroup("Projects", isExpanded: $projectsExpanded) {
                    tabRow(.compose)
                    tabRow(.environments)
                }
            }
            Section("System") {
                tabRow(.settings)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Tokens.Palette.sidebar)
        .frame(minWidth: 190, idealWidth: 200)
        .safeAreaInset(edge: .bottom) {
            runtimeStatusCard
        }
        // Cap the whole column (inset included): otherwise the HStack hands
        // the sidebar half the window whenever a tab's content is narrow.
        .frame(maxWidth: 220)
        .onAppear { revealSelection(store.activeTab) }
        .onChange(of: store.activeTab) { _, tab in revealSelection(tab) }
    }

    private func tabRow(_ tab: AppStore.ActiveTab) -> some View {
        let selected = store.activeTab == tab
        return Label {
            Text(tab.title)
                .font(Tokens.Typography.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Tokens.Palette.accentText : Tokens.Palette.primary)
        } icon: {
            WorkspaceIcon(name: pictogram(for: tab), size: 18, fallback: tab.icon)
                .foregroundStyle(selected ? Tokens.Palette.accentText : Tokens.Palette.secondary)
        }
        .badge(count(for: tab).flatMap { $0 > 0 ? Text("\($0)") : nil })
        .tag(tab)
    }

    // MARK: - Icon rail

    /// Compact icon-only navigation (Finder-style rail) for medium windows.
    private var iconRail: some View {
        VStack(spacing: 2) {
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(AppStore.ActiveTab.allCases) { tab in
                        let isSelected = store.activeTab == tab
                        Button {
                            store.activeTab = tab
                        } label: {
                            WorkspaceIcon(name: pictogram(for: tab), size: 18, fallback: tab.icon)
                                .frame(width: 34, height: 30)
                                .contentShape(Rectangle())
                                .overlay(alignment: .topTrailing) {
                                    if let count = count(for: tab), count > 0 {
                                        Text("\(count)")
                                            .font(.system(size: 8, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 3)
                                            .padding(.vertical, 1)
                                            .background(Tokens.Palette.action, in: Capsule())
                                            .contentTransition(.numericText())
                                            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: count)
                                            .offset(x: -1, y: -1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(tab.title)
                        .accessibilityLabel(tab.title)
                        .foregroundStyle(isSelected ? Tokens.Palette.accentText : Tokens.Palette.secondary)
                        .background(
                            isSelected ? Tokens.Palette.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Runtime status stays one glance away in rail mode.
            Button {
                if store.isRuntimeRunning {
                    store.activeTab = .settings
                } else if store.clientAvailable {
                    Task { await store.startRuntime() }
                }
            } label: {
                StatusDot(color: statusColor, size: 10, active: store.isStartingRuntime)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.isRuntimeRunning ? "Runtime settings" : "Start runtime")
            .accessibilityLabel(statusText)
        }
        .padding(.vertical, 8)
        .frame(width: 50)
        .background(Tokens.Palette.sidebar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.activeTab {
        case .dashboard: DashboardView(store: store)
        case .workloads: WorkloadsView(store: store)
        case .cache: CacheView(store: store)
        case .containers: ContainersView(store: store)
        case .machines: MachinesView(store: store)
        case .images: ImagesView(store: store)
        case .volumes: VolumesView(store: store)
        case .networks: NetworksView(store: store)
        case .registries: RegistriesView(store: store)
        case .build: BuildView(store: store)
        case .compose: ComposeView(store: store)
        case .environments: EnvironmentsView(store: store)
        case .storage: StorageView(store: store)
        case .settings: SettingsView(store: store)
        }
    }

    // MARK: - Runtime status

    private var runtimeStatusCard: some View {
        let count = store.workloadItems.count(where: \.isRunning)
        let available = store.clientAvailable && store.isRuntimeRunning
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(color: statusColor, size: 8, active: store.isStartingRuntime)
                Text(statusText)
                    .font(.caption2.weight(.medium))
                Spacer()
                if !store.isRuntimeRunning && store.clientAvailable {
                    Button {
                        Task { await store.startRuntime() }
                    } label: {
                        Image(systemName: "play.fill").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isStartingRuntime)
                    .accessibilityLabel("Start runtime")
                }
            }
            Text(available ? "\(count) running · Local" : "\(count) last seen running")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: count)
        }
        .padding(10)
        .cardSurface(cornerRadius: 10, fillOpacity: 0.8)
        .padding(8)
    }

    private var statusText: String {
        if !store.clientAvailable { return "container CLI not found" }
        if store.isStartingRuntime { return "Starting runtime…" }
        if store.runtimeHealth == .wedged { return "Runtime needs attention" }
        if store.isRuntimeRunning { return "Runtime ready" }
        return "Runtime stopped"
    }

    private var statusColor: Color {
        if !store.clientAvailable { return Tokens.Palette.danger }
        if store.isStartingRuntime || store.runtimeHealth == .wedged { return Tokens.Palette.warning }
        if store.isRuntimeRunning { return Tokens.Palette.success }
        return Tokens.Palette.tertiary
    }

    /// Live counts per tab (HIG: badges communicate state at a glance).
    private func count(for tab: AppStore.ActiveTab) -> Int? {
        switch tab {
        case .workloads: store.workloadItems.count
        case .containers: store.containers.count
        case .machines: store.machines.filter(\.isRunning).count
        case .images: store.images.count
        case .volumes: store.volumes.count
        case .networks: store.networks.count
        default: nil
        }
    }

    private func revealSelection(_ tab: AppStore.ActiveTab) {
        if [.containers, .volumes, .networks, .registries].contains(tab) { resourcesExpanded = true }
        if [.compose, .environments].contains(tab) { projectsExpanded = true }
    }

    private func pictogram(for tab: AppStore.ActiveTab) -> String {
        switch tab {
        case .dashboard: "activity"
        case .workloads: "workloads"
        case .containers: "container"
        case .machines: "microvm"
        case .images: "images"
        case .cache: "cache"
        case .storage, .volumes: "storage"
        case .networks, .registries: "network"
        case .build: "terminal"
        case .compose: "stack"
        case .environments: "workloads"
        case .settings: "settings"
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "micropod" else { return }
        switch url.host {
        case "dashboard": store.activeTab = .dashboard
        case "workloads": store.activeTab = .workloads
        case "cache": store.activeTab = .cache
        case "containers":
            store.activeTab = .containers
            if url.pathComponents.count > 1 {
                store.selectedContainerID = url.pathComponents[1]
            }
        case "machines":
            store.activeTab = .machines
            if url.pathComponents.count > 1 {
                store.selectedMachineID = url.pathComponents[1]
            }
        case "images": store.activeTab = .images
        case "volumes": store.activeTab = .volumes
        case "networks": store.activeTab = .networks
        case "registries": store.activeTab = .registries
        case "build": store.activeTab = .build
        case "compose": store.activeTab = .compose
        case "environments": store.activeTab = .environments
        case "storage": store.activeTab = .storage
        case "settings": store.activeTab = .settings
        default: break
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
