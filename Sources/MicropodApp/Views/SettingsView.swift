import MicropodCore
import SwiftUI

/// Settings tab: polling behavior, menu bar, terminal shell.
struct SettingsView: View {
    @Bindable var store: AppStore

    @AppStorage(UserDefaultsKeys.pollIntervalContainers) private var containerInterval = 3.0
    @AppStorage(UserDefaultsKeys.pollIntervalStats) private var statsInterval = 5.0
    @AppStorage(UserDefaultsKeys.showMenuBarCount) private var showMenuBarCount = true
    @AppStorage(UserDefaultsKeys.terminalShell) private var terminalShell = "/bin/sh"
    @AppStorage(UserDefaultsKeys.notifyPulls) private var notifyPulls = false
    @AppStorage(UserDefaultsKeys.notifyBuilds) private var notifyBuilds = false
    @AppStorage(UserDefaultsKeys.notifyCompose) private var notifyCompose = false
    @AppStorage(UserDefaultsKeys.notifyPrune) private var notifyPrune = false
    @AppStorage(UserDefaultsKeys.notifyKernel) private var notifyKernel = false
    @State private var showCreateMachine = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $store.appearance) {
                    ForEach(AppStore.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Text("Controls the window theme; System follows the macOS appearance.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("Polling") {
                LabeledContent("Container list interval (s)") {
                    TextField("3", value: $containerInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                        .accessibilityLabel("Container list interval in seconds")
                        .accessibilityIdentifier("settings.pollIntervalContainers")
                }
                LabeledContent("Stats interval (s)") {
                    TextField("5", value: $statsInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
                Text(
                    "Stats are sampled 5s while the window is visible and up to the interval when hidden; containers always refresh at the list interval."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Section("Menu Bar") {
                Toggle("Show running container count", isOn: $showMenuBarCount)
                    .toggleStyle(.checkbox)
            }
            Section("Terminal") {
                TextField("Shell", text: $terminalShell)
                    .textFieldStyle(.roundedBorder)
                Text("Used for the container terminal pane (e.g. /bin/sh or /bin/bash).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Image pulls", isOn: $notifyPulls)
                    .toggleStyle(.checkbox)
                Toggle("Builds", isOn: $notifyBuilds)
                    .toggleStyle(.checkbox)
                Toggle("Compose up / down", isOn: $notifyCompose)
                    .toggleStyle(.checkbox)
                Toggle("Prune", isOn: $notifyPrune)
                    .toggleStyle(.checkbox)
                Toggle("Kernel install", isOn: $notifyKernel)
                    .toggleStyle(.checkbox)
                Text(
                    "Completions and failures post a system notification. Opt-in per category; the activity feed always records them."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Section("Runtime") {
                HStack {
                    Text("CLI version")
                    Spacer()
                    Text(store.systemStatus?.cliVersion ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("App root")
                    Spacer()
                    Text(store.systemStatus?.appRoot ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Machines")
                    Spacer()
                    Button {
                        Task {
                            await store.refreshMachines()
                            await store.refreshSystemProperties()
                        }
                    } label: {
                        IconLabel(title: "Refresh", icon: "refresh", fallback: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                if let machineError = store.machineError {
                    Text(machineError).font(.caption).foregroundStyle(.red)
                }
                if store.machines.isEmpty {
                    Text("No machines — the runtime uses its embedded default machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.machines, id: \.name) { machine in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(machine.name).font(.caption.weight(.medium))
                                    if machine.defaultMachine == true {
                                        Text("default").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                Text(
                                    [
                                        machine.state ?? "—",
                                        machine.cpus.map { "\($0) CPU" } ?? "",
                                        machine.memory ?? "",
                                        machine.ip ?? "",
                                    ].filter { !$0.isEmpty }.joined(separator: " · ")
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await store.deleteMachine(machine.name) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete machine")
                            .disabled(machine.defaultMachine == true)
                        }
                    }
                }
                Button {
                    showCreateMachine = true
                } label: {
                    IconLabel(title: "Create Machine…", icon: "create", fallback: "plus")
                }
                .controlSize(.small)
            }
            Section("System Properties") {
                if store.systemProperties == nil {
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(systemPropertyRows, id: \.id) { row in
                        HStack {
                            Text(row.label).font(.caption)
                            Spacer()
                            Text(row.value)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            Section("About") {
                HStack(spacing: 10) {
                    EmptyStateView.brandMark(EmptyStateArtwork.dashboardHero, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Micropod").font(.callout.weight(.semibold))
                        Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                LabeledContent("Runtime", value: "Apple `container` (github.com/apple/container)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            if store.machines.isEmpty { await store.refreshMachines() }
            if store.systemProperties == nil { await store.refreshSystemProperties() }
        }
        .sheet(isPresented: $showCreateMachine) {
            CreateMachineSheet(store: store)
        }
    }

    /// Flattened system properties: "section.key = value" rows, sections
    /// grouped and ordered for a stable list.
    private var systemPropertyRows: [PropertyRow] {
        guard let props = store.systemProperties else { return [] }
        var rows: [PropertyRow] = []
        for section in props.keys.sorted() {
            guard let values = props[section] else { continue }
            for key in values.keys.sorted() {
                let value = values[key]?.displayString ?? ""
                rows.append(
                    PropertyRow(
                        id: "\(section).\(key)",
                        label: "\(section).\(key)",
                        value: value))
            }
        }
        return rows
    }

    private struct PropertyRow: Identifiable {
        let id: String
        let label: String
        let value: String
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "0.1.0"
    }
}
