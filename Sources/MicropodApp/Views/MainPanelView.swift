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
                        OperationsDrawerView(store: store)
                    }
                    .navigationTitle(store.activeTab.title)
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
                                Label("Command Palette", systemImage: "command")
                            }
                            .keyboardShortcut("k", modifiers: .command)
                            .help("Command Palette (⌘K)")
                        }
                    }
            }
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
            if let error = store.lastRefreshError {
                ErrorBanner(message: error) { store.lastRefreshError = nil }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(
                        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if store.showCommandPalette {
                CommandPaletteView(store: store)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: store.showCommandPalette)
    }

    // MARK: - Full sidebar

    private var fullSidebar: some View {
        List(selection: $store.activeTab) {
            Section("Overview") {
                tabRow(.dashboard)
            }
            Section("Resources") {
                tabRow(.containers)
                tabRow(.images)
                tabRow(.volumes)
                tabRow(.networks)
                tabRow(.registries)
                tabRow(.storage)
            }
            Section("Build & Compose") {
                tabRow(.build)
                tabRow(.compose)
                tabRow(.environments)
            }
            Section("System") {
                tabRow(.settings)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 200)
        .safeAreaInset(edge: .bottom) {
            runtimeStatusCard
        }
    }

    private func tabRow(_ tab: AppStore.ActiveTab) -> some View {
        Label(tab.title, systemImage: tab.icon)
            .badge(count(for: tab).flatMap { $0 > 0 ? Text("\($0)") : nil })
            .tag(tab)
    }

    // MARK: - Icon rail

    /// Compact icon-only navigation (Finder-style rail) for medium windows.
    private var iconRail: some View {
        VStack(spacing: 2) {
            ForEach(AppStore.ActiveTab.allCases) { tab in
                let isSelected = store.activeTab == tab
                Button {
                    store.activeTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            if let count = count(for: tab), count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor, in: Capsule())
                                    .offset(x: 4, y: -2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(
                    isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
            // Runtime status stays one glance away in rail mode.
            Button {
                if store.isRuntimeRunning {
                    Task { await store.stopRuntime() }
                } else if store.clientAvailable {
                    Task { await store.startRuntime() }
                }
            } label: {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(statusText) — click to \(store.isRuntimeRunning ? "stop" : "start")")
            .accessibilityLabel(statusText)
        }
        .padding(.vertical, 8)
        .frame(width: 50)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.activeTab {
        case .dashboard: DashboardView(store: store)
        case .containers: ContainersView(store: store)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
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
            Text("\(store.runningCount) running · \(store.containers.count) total")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private var statusText: String {
        if !store.clientAvailable { return "container CLI not found" }
        if store.isStartingRuntime { return "Starting runtime…" }
        if store.isRuntimeRunning { return "Runtime running" }
        return "Runtime stopped"
    }

    private var statusColor: Color {
        if !store.clientAvailable { return .red }
        if store.isRuntimeRunning { return .green }
        return .orange
    }

    /// Live counts per tab (HIG: badges communicate state at a glance).
    private func count(for tab: AppStore.ActiveTab) -> Int? {
        switch tab {
        case .containers: store.containers.count
        case .images: store.images.count
        case .volumes: store.volumes.count
        case .networks: store.networks.count
        default: nil
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "micropod" else { return }
        switch url.host {
        case "dashboard": store.activeTab = .dashboard
        case "containers":
            store.activeTab = .containers
            if url.pathComponents.count > 1 {
                store.selectedContainerID = url.pathComponents[1]
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
