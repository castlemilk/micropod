import MicropodCore
import MicropodRuntime
import SwiftUI

struct ManagedRuntimeView: View {
    @Bindable var store: AppStore
    @Bindable private var controller = ManagedRuntimeController.shared
    @State private var confirmsInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let operation = controller.operation {
                HStack(spacing: 8) {
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    Text(operation.message).font(.caption)
                }
                if let error = operation.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if controller.isBusy {
                    Button("Cancel") { Task { await controller.cancel() } }
                        .controlSize(.small)
                } else if controller.needsRecovery {
                    Button("Verify and Recover") {
                        Task {
                            try? await controller.recover()
                            await store.refreshSystemStatus(force: true)
                        }
                    }
                    .controlSize(.small)
                }
            }
            if let error = controller.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if !controller.isBusy && !controller.needsRecovery {
                HStack {
                    Button("Install Apple Container…") {
                        confirmsInstall = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("runtime.managedInstall")
                    .disabled(!RuntimeDependencyStatus.hostSupported)
                    if FileManager.default.fileExists(atPath: IsolatedRuntimePolicy.identityURL.path) {
                        Button("Start") { controller.request(.start) }
                        Button("Stop") { controller.request(.stop) }
                        Button("Restart") { controller.request(.restart) }
                    }
                }
                .controlSize(.small)
            }
        }
        .task { await controller.refresh() }
        .confirmationDialog(
            "Install Apple's container runtime?", isPresented: $confirmsInstall, titleVisibility: .visible
        ) {
            Button("Approve and Install") { controller.installWithApproval() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Micropod verifies Apple's 1.5.0 runtime (118 MB) and installs it in a dedicated, locked macOS account. macOS asks an administrator to approve Micropod's helper. Your existing Apple runtime and its jobs stay separate. You can start the managed runtime after installation."
            )
        }
    }
}
