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
                    Button("Prepare Apple Container…") {
                        confirmsInstall = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("runtime.managedInstall")
                    .disabled(!RuntimeDependencyStatus.hostSupported)
                    if ManagedRuntimeLocation.executable() != nil {
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
            "Prepare Apple's container runtime?", isPresented: $confirmsInstall, titleVisibility: .visible
        ) {
            Button("Download and Verify Runtime") { controller.request(store.clientAvailable ? .repair : .install) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Micropod downloads and verifies Apple's 1.5.0 runtime (118 MB) and stages a private copy for your account. Activation and kernel setup require qualified coordination for every runtime consumer. That coordination is not yet available, so the current service will keep running."
            )
        }
    }
}
