import AppKit
import MicropodCore
import SwiftUI

@main
struct MicropodApp: App {
    @NSApplicationDelegateAdaptor(MicropodApplicationDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @Environment(\.openWindow) private var openWindow

    init() {
        if let url = Bundle.micropodResources.url(
            forResource: "app-tile", withExtension: "svg", subdirectory: "uplift"),
            let image = NSImage(contentsOf: url)
        {
            NSApplication.shared.applicationIconImage = image
        }
        // Control socket for the API server / MCP to reach app-process
        // features (Sparkle update checks today).
        AppControlServer.shared.start()
        // ~/.local/bin/micropod + micropod-mcp → this bundle, so the CLI and
        // MCP server update with the app.
        CLIToolLinks.refresh()
        // Hot service paths (exec, stats, logs, lifecycle) swap to direct
        // apiserver XPC when the handshake succeeds — CLI fallback otherwise.
        Task { await AppDependencies.shared.useNativeBackend() }
    }

    var body: some Scene {
        MainWindowScene {
            MainPanelView(store: store)
                .frame(minWidth: 720, minHeight: 460)
                .background(MainWindowFrameRestorer())
                .background(
                    MainWindowVisibilityObserver { id, visible in
                        store.setMainWindowVisible(visible, windowID: id)
                    }
                )
                .preferredColorScheme(store.appearance.colorScheme)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Command Palette…") {
                    store.showCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Open Main Window") {
                    showMainWindow()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Check for Updates…") {
                    UpdateController.shared.checkForUpdates()
                }
                .disabled(!UpdateController.shared.canCheckForUpdates)
            }
            CommandMenu("View") {
                ForEach(AppStore.ActiveTab.allCases) { tab in
                    Button(tab.title) {
                        store.activeTab = tab
                    }
                    // Tabs without a shortcut (storage) get none — the old
                    // ?? "s" fallback gave Storage a stray ⌃⌘S binding.
                    .keyboardShortcut(
                        shortcut(for: tab).map { KeyboardShortcut($0, modifiers: [.command, .control]) })
                }
                Divider()
                Button("Refresh") {
                    Task { await store.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Container") {
                Button("Start Runtime") {
                    Task { await store.startRuntime() }
                }
                .disabled(store.isRuntimeRunning)
                Button("Stop Runtime") {
                    showMainWindow()
                    store.requestRuntimeStop()
                }
                .disabled(!store.isRuntimeRunning)
                Divider()
                Button("Prune Stopped Containers") {
                    Task { await store.pruneContainers() }
                }
            }
        }

        MenuBarExtra {
            // Width is owned by MenuBarPanelView; don't pin a second,
            // conflicting width here.
            MenuBarPanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }

    private func showMainWindow() {
        MainWindowPresenter.shared.show { openWindow(id: MainWindowPresenter.sceneID) }
    }

    private func shortcut(for tab: AppStore.ActiveTab) -> KeyEquivalent? {
        switch tab {
        case .dashboard: "1"
        case .containers: "2"
        case .images: "3"
        case .volumes: "4"
        case .networks: "5"
        case .registries: "6"
        case .build: "7"
        case .compose: "8"
        case .environments: "9"
        case .machines, .storage, .workloads, .cache: nil
        case .settings: "0"
        }
    }
}
