import MicropodCore
import SwiftUI

/// Menu bar icon: runtime status dot + running container count.
///
/// SwiftUI gives label views unreliable `.task`/`.onAppear` lifecycle, so
/// bootstrap uses the triple-trigger pattern (skill guidance).
struct MenuBarLabel: View {
    let store: AppStore
    @State private var didBootstrap = false
    // VoiceOver reads a meaningful label instead of the raw glyph.
    private var accessibilityLabel: String {
        if !store.clientAvailable { return "Micropod: container CLI not found" }
        if store.isRuntimeRunning {
            return "Micropod: runtime running, \(store.runningCount) container\(store.runningCount == 1 ? "" : "s")"
        }
        return "Micropod: runtime stopped"
    }

    var body: some View {
        HStack(spacing: 3) {
            if store.isStartingRuntime || store.isInstallingKernel {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
            if store.runningCount > 0 {
                Text("\(store.runningCount)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { startBootstrapIfNeeded() }
        .task { startBootstrapIfNeeded() }
        .onReceive(
            Timer.publish(every: 5, on: .main, in: .common).autoconnect()
        ) { _ in
            startBootstrapIfNeeded()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func startBootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        store.bootstrap()
    }

    private var iconName: String {
        guard store.clientAvailable else { return "shippingbox.fill" }
        if store.isRuntimeRunning { return "shippingbox.fill" }
        return "shippingbox"
    }

    private var iconColor: Color {
        guard store.clientAvailable else { return .red }
        if store.isRuntimeRunning { return .green }
        return .orange
    }
}
