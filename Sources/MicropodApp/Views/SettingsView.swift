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
            Section("Agents") {
                ForEach(store.agentSpecs, id: \.id) { spec in
                    agentRow(spec)
                }
                Button {
                    store.restartAllAgents()
                } label: {
                    IconLabel(title: "Restart All Agents", icon: "restart", fallback: "arrow.clockwise")
                }
                .controlSize(.small)
                Text(
                    "Helper processes the app runs for you. They start with the app, restart if they die, and quit when Micropod quits."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                    Text("Health")
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(runtimeHealthColor)
                            .frame(width: 6, height: 6)
                        Text(runtimeHealthText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("CLI version")
                    Spacer()
                    Text(store.systemStatus?.cliVersion ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await store.restartRuntime() }
                    } label: {
                        IconLabel(
                            title: store.isRestartingRuntime ? "Restarting…" : "Restart Runtime",
                            icon: "restart", fallback: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(
                        !store.isRuntimeRunning || store.isRestartingRuntime || store.isHealingRuntime)
                    Button {
                        store.recoverRuntimeNow()
                    } label: {
                        IconLabel(
                            title: store.isHealingRuntime ? "Recovering…" : "Recover Runtime",
                            icon: "refresh", fallback: "stethoscope")
                    }
                    .controlSize(.small)
                    .disabled(store.isHealingRuntime || store.isRestartingRuntime)
                    .help(
                        "Bounces `container system` (stop + start) — the same recovery the supervisor runs when the apiserver stops answering."
                    )
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

    /// One agent: enable toggle, live state dot + pid/endpoint, restart.
    private func agentRow(_ spec: AgentSpec) -> some View {
        let status = store.agentStatuses.first { $0.id == spec.id }
        return HStack(spacing: 8) {
            Toggle(isOn: agentEnabledBinding(spec)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.displayName).font(.caption.weight(.medium))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(agentStateColor(status?.state))
                            .frame(width: 6, height: 6)
                        Text(agentStateText(status))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let status, status.restarts > 0 {
                Text("\(status.restarts)× restart")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if store.isAgentEnabled(spec.id) {
                Button {
                    store.restartAgent(spec.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart \(spec.displayName)")
                .accessibilityLabel("Restart \(spec.displayName)")
            }
        }
    }

    private func agentEnabledBinding(_ spec: AgentSpec) -> Binding<Bool> {
        Binding(
            get: { store.isAgentEnabled(spec.id) },
            set: { store.setAgentEnabled(spec.id, $0) })
    }

    private func agentStateColor(_ state: AgentStatus.State?) -> Color {
        switch state {
        case .running: .green
        case .adopted: .blue
        case .starting, .retryPending: .orange
        case .missing: .red
        case .stopped, nil: .gray
        }
    }

    private func agentStateText(_ status: AgentStatus?) -> String {
        guard let status else { return "starting…" }
        switch status.state {
        case .running:
            return "running · pid \(status.pid ?? 0) · \(status.endpoint)"
        case .adopted:
            return "running externally · \(status.endpoint)"
        case .starting:
            return "starting… · \(status.endpoint)"
        case .retryPending:
            return status.lastError.map { "down — \($0)" } ?? "down — retrying"
        case .missing:
            return "not installed · \(status.endpoint)"
        case .stopped:
            return "off"
        }
    }

    private var runtimeHealthColor: Color {
        if !store.clientAvailable { return .red }
        if store.isHealingRuntime || store.isRestartingRuntime { return .orange }
        if store.runtimeHealth == .wedged { return .orange }
        return store.isRuntimeRunning ? .green : .gray
    }

    private var runtimeHealthText: String {
        if !store.clientAvailable { return "CLI not found" }
        if store.isHealingRuntime { return "recovering…" }
        if store.isRestartingRuntime { return "restarting…" }
        if store.runtimeHealth == .wedged { return "unresponsive (self-healing)" }
        return store.isRuntimeRunning ? "healthy" : "stopped"
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
