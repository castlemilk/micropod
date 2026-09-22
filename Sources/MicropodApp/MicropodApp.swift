import AppKit
import MicropodCore
import SwiftUI

@main
struct MicropodApp: App {
    @State private var store = AppStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main-window") {
            MainPanelView(store: store)
                .frame(minWidth: 720, minHeight: 460)
                .background(MainWindowFrameRestorer())
                .preferredColorScheme(store.appearance.colorScheme)
                .onAppear { store.setMainWindowVisible(true) }
                .onDisappear { store.setMainWindowVisible(false) }
        }
        .defaultSize(width: 1080, height: 700)
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
                    openWindow(id: "main-window")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
                    Task { await store.stopRuntime() }
                }
                .disabled(!store.isRuntimeRunning)
                Divider()
                Button("Prune Stopped Containers") {
                    Task { await store.pruneContainers() }
                }
            }
        }

        MenuBarExtra {
            // Width is owned by MenuBarPanelView (340pt); don't pin a second,
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
        case .storage: nil
        case .settings: "0"
        }
    }
}
