import MicropodCore
import SwiftUI

/// The same setup actions are available after onboarding has been skipped.
struct RuntimeDependencyActions: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.runtimeDependencyStatus.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.runtimeDependencyStatus.state == .missingCLI {
                Text(
                    "Open Apple's release page, download the signed installer package, and follow macOS Installer. Micropod checks for the installation while it stays open."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Link("Get Apple container 1.5.0…", destination: ContainerExecutableLocator.installerURL)
                    .accessibilityIdentifier("runtime.getInstaller")
                    .formActionBounds("runtime.getInstaller")
            } else if store.runtimeDependencyStatus.state != .nativeReady {
                Text(store.runtimeDependencyStatus.nextAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if store.runtimeDependencyStatus.state == .stopped {
                    Button("Start Runtime") { Task { await store.startRuntime() } }
                        .disabled(store.runtimeOperationInProgress)
                        .accessibilityIdentifier("runtime.start")
                }
                Button("Check Again") { Task { await store.refreshSystemStatus(force: true) } }
                    .disabled(store.runtimeOperationInProgress)
                    .accessibilityIdentifier("runtime.recheck")
                    .formActionBounds("runtime.recheck")
            }
            .controlSize(.small)
        }
    }
}
