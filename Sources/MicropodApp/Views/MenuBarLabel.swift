import MicropodCore
import SwiftUI

/// Monochrome brand mark, observed running-workload count, and guest CPU.
/// Sampling stays in AppStore's shared visibility-aware tasks.
struct MenuBarLabel: View {
    let store: AppStore
    var activateRuntimeObservation = true
    @State private var didBootstrap = false
    @AppStorage(UserDefaultsKeys.showMenuBarCount) private var showMenuBarCount = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarImages.brandMark)
                .renderingMode(.template)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(healthColor).frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 0.8))
                        .offset(x: 2, y: 1)
                        .accessibilityHidden(true)
                }
            if showMenuBarCount, runningCount > 0 {
                Text("\(runningCount)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: runningCount)
                if let cpu = cpuLabel {
                    Text(cpu).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { startBootstrapIfNeeded() }
        .task { startBootstrapIfNeeded() }
        .help(accessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var runningCount: Int { store.workloadItems.count { $0.isRunning } }

    private var cpuLabel: String? {
        guard store.isRuntimeRunning else { return nil }
        let metrics = MenuBarGuestMetrics(workloads: store.workloadItems)
        guard metrics.cpuText != "—" else { return nil }
        return metrics.cpuText.replacingOccurrences(of: " ", with: "") + "c"
    }

    private var accessibilityLabel: String {
        let count = "\(runningCount) compute workload\(runningCount == 1 ? "" : "s")"
        let cpu = cpuLabel.map { ", \($0.dropLast()) consumed guest CPU cores" } ?? ""
        if !store.clientAvailable { return "Micropod: runtime unavailable, \(count) last seen running" }
        if store.isHealingRuntime { return "Micropod: recovering runtime, \(count) last seen running" }
        if store.isStartingRuntime || store.isRestartingRuntime { return "Micropod: starting runtime" }
        if store.isInstallingKernel { return "Micropod: installing Linux kernel" }
        if store.runtimeHealth == .wedged { return "Micropod: runtime unresponsive, \(count) last seen running" }
        if !store.isRuntimeRunning { return "Micropod: runtime stopped, \(count) last seen running" }
        if helpersDegraded { return "Micropod: runtime running, a helper is unavailable, \(count) running\(cpu), active jobs unknown" }
        let health = store.runtimeHealth == .healthy ? "healthy" : "running, health not yet verified"
        return "Micropod: runtime \(health), \(count) running\(cpu), active jobs unknown"
    }

    private var helpersDegraded: Bool {
        store.agentStatuses.contains { $0.state == .retryPending || $0.state == .missing }
    }

    private var healthColor: Color {
        if !store.clientAvailable { return Tokens.Palette.danger }
        if store.runtimeHealth == .wedged || store.isHealingRuntime || store.isStartingRuntime
            || store.isRestartingRuntime || store.isInstallingKernel || helpersDegraded
        {
            return Tokens.Palette.warning
        }
        return store.isRuntimeRunning && store.runtimeHealth == .healthy
            ? Tokens.Palette.success : Tokens.Palette.tertiary
    }

    private func startBootstrapIfNeeded() {
        guard activateRuntimeObservation, !didBootstrap else { return }
        didBootstrap = true
        store.bootstrap()
    }
}
