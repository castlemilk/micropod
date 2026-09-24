import MicropodCore
import SwiftUI

/// Menu bar icon: runtime status dot + running container count.
///
/// SwiftUI gives label views unreliable `.task`/`.onAppear` lifecycle, so
/// bootstrap uses the triple-trigger pattern (skill guidance): `.onAppear`,
/// `.task`, and a bounded retry loop inside that task — a perpetual
/// `Timer.publish` would wake the process every few seconds forever for a
/// one-shot bootstrap.
struct MenuBarLabel: View {
    let store: AppStore
    @State private var didBootstrap = false
    @AppStorage(UserDefaultsKeys.showMenuBarCount) private var showMenuBarCount = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // VoiceOver reads a meaningful label instead of the raw glyph.
    private var accessibilityLabel: String {
        if !store.clientAvailable { return "Micropod: container CLI not found" }
        if store.isRuntimeRunning {
            let cpu = aggregateCPU.map { ", \( $0) CPU" } ?? ""
            let health =
                switch healthBadge?.symbol {
                case "checkmark.circle.fill": "healthy, "
                case "exclamationmark.circle.fill": "degraded, "
                default: ""
                }
            return
                "Micropod: runtime \(health)running, \(store.runningCount) container\(store.runningCount == 1 ? "" : "s")\(cpu)"
        }
        return "Micropod: runtime stopped"
    }

    var body: some View {
        HStack(spacing: 3) {
            if store.isStartingRuntime || store.isInstallingKernel {
                // Breathing brand mark reads "coming up" more calmly than a
                // dasher spinner squeezed into 14pt.
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.orange)
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace))
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = healthBadge {
                            Image(systemName: badge.symbol)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(badge.color)
                                .offset(x: 3, y: 3)
                                .accessibilityHidden(true)
                        }
                    }
            }
            if showMenuBarCount, store.runningCount > 0 {
                Text("\(store.runningCount)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.runningCount)
                if let cpu = aggregateCPU {
                    Text(cpu)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: cpu)
                }
            }
        }
        .onAppear { startBootstrapIfNeeded() }
        .task {
            // Third trigger as a bounded retry: covers the case where the
            // label's lifecycle hooks never fire, then stops — ~30s window.
            for _ in 0..<15 where !didBootstrap && !Task.isCancelled {
                startBootstrapIfNeeded()
                try? await Task.sleep(for: .seconds(2))
            }
            startBootstrapIfNeeded()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Total CPU across running containers (e.g. "12%") — nil when no stats
    /// have landed yet. Shown in the menu bar so load is visible at a glance.
    private var aggregateCPU: String? {
        guard store.isRuntimeRunning, let snapshot = store.statsSnapshot else { return nil }
        let total = snapshot.containers.reduce(0.0) { $0 + $1.cpuPercent }
        return String(format: "%.0f%%", total)
    }

    private func startBootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        store.bootstrap()
    }

    private var iconName: String {
        guard store.clientAvailable else { return "exclamationmark.triangle.fill" }
        if store.isRuntimeRunning { return "shippingbox.fill" }
        return "shippingbox"
    }

    private var iconColor: Color {
        guard store.clientAvailable else { return .red }
        // Stopped is a normal state, not a warning — dim it instead of orange.
        return store.isRuntimeRunning ? .green : .secondary
    }

    /// Bottom-trailing superscript: green check when the whole stack is
    /// healthy (runtime running, liveness probe clean, every enabled agent
    /// serving), amber warning while wedged/healing or an agent is down.
    private var healthBadge: (symbol: String, color: Color)? {
        guard store.clientAvailable, store.isRuntimeRunning else { return nil }
        let runtimeDegraded = store.runtimeHealth == .wedged || store.isHealingRuntime
        // `stopped` = user-disabled, `starting` = still probing — neither is
        // a failure. retryPending/missing means something should be up but
        // isn't.
        let agentsDegraded = store.agentStatuses.contains {
            $0.state == .retryPending || $0.state == .missing
        }
        if runtimeDegraded || agentsDegraded {
            return ("exclamationmark.circle.fill", .orange)
        }
        return ("checkmark.circle.fill", .green)
    }
}
