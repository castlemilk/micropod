import AppKit
import Foundation
import MicropodCore
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
private final class RuntimeSetupModel {
    var status = IsolatedRuntimeStatus()
    var error: String?
    var awaitingApproval = false
    var approvalMessage = "Administrator approval has not been requested"
    var busy = false
    private let service = SMAppService.daemon(plistName: "com.skunkworq.micropod.runtime.host.plist")
    private let client = IsolatedRuntimeClient()
    func approveHelper() {
        do {
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            awaitingApproval = service.status == .requiresApproval
            if awaitingApproval { SMAppService.openSystemSettingsLoginItems() } else { Task { await refresh() } }
        } catch {
            let failure = error as NSError
            if failure.domain == "SMAppServiceErrorDomain", failure.code == Int(kSMErrorLaunchDeniedByUser) {
                awaitingApproval = true
                approvalMessage = "macOS is waiting for administrator approval"
                SMAppService.openSystemSettingsLoginItems()
            } else {
                self.error = error.localizedDescription
            }
        }
    }
    func refresh() async {
        awaitingApproval = service.status == .requiresApproval
        switch service.status {
        case .notRegistered: approvalMessage = "Administrator approval has not been requested"
        case .enabled: approvalMessage = "The runtime helper is approved"
        case .requiresApproval: approvalMessage = "macOS is waiting for administrator approval"
        case .notFound: approvalMessage = "macOS has not registered this runtime helper yet"
        @unknown default: approvalMessage = "The helper approval state is unavailable"
        }
        guard service.status == .enabled else { return }
        do {
            status = try await client.call(.init(action: .status))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func request(_ action: IsolatedRuntimeAction) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            status = try await client.call(.init(action: action))
            while !status.isTerminal {
                try await Task.sleep(for: .milliseconds(400))
                status = try await client.call(.init(action: .status))
            }
        } catch { self.error = error.localizedDescription }
    }

    func pauseHelperForUpdate() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let current = try await client.call(.init(action: .status))
            guard current.isTerminal, current.phase != "recoveryRequired",
                current.rigAttempted != true,
                current.localGeneration == nil || current.actionVerified == true,
                try current.workerBirth?.hasExited() != false
            else {
                throw MicropodError.message("Finish or verify runtime maintenance before updating the helper")
            }
            // Service Management owns termination. The durable runtime journal
            // and admission fence survive replacement of this app bundle.
            try await service.unregister()
            approvalMessage = "The helper is paused for an app update"
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

@main
struct MicropodRuntimeSetup: App {
    @State private var model = RuntimeSetupModel()
    var body: some Scene {
        WindowGroup("Micropod Runtime Setup") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Micropod’s managed runtime", systemImage: "shippingbox").font(.title2)
                    Text(
                        "Apple container runs in a dedicated, locked macOS account. Your current Apple runtime and running jobs stay separate."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Setup needs administrator approval for Micropod’s signed helper. It creates the hidden _micropod service account, verifies Apple’s 1.5.0 package, and stores runtime data separately on this Mac."
                    )
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Approve Runtime Helper…") { model.approveHelper() }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                    Text(model.approvalMessage).font(.callout).foregroundStyle(.secondary)
                    if model.awaitingApproval {
                        Text(
                            "Approve Micropod Runtime Setup in System Settings → General → Login Items & Extensions, then check again."
                        ).font(.callout)
                    }
                    HStack {
                        Button("Check Approval") { Task { await model.refresh() } }
                        Button("Install Dedicated Runtime") { Task { await model.request(.install) } }
                        Button("Start") { Task { await model.request(.start) } }
                        Button("Stop") { Task { await model.request(.stop) } }
                    }.disabled(model.busy)
                    HStack {
                        Button("Verify Runtime") { Task { await model.request(.verify) } }
                        Button("Run Isolated Test") { Task { await model.request(.workload) } }
                    }.disabled(model.busy)
                    Button("Pause Helper for Update") { Task { await model.pauseHelperForUpdate() } }
                        .disabled(model.busy)
                    if model.busy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Button("Cancel Operation") {
                                Task { _ = try? await IsolatedRuntimeClient().call(.init(action: .cancel)) }
                            }
                        }
                    }
                    Text(model.status.message).font(.callout)
                    if let identity = model.status.identity {
                        DisclosureGroup("Runtime details") {
                            Text("Service account: \(identity.serviceUID) · Instance: \(identity.instance.uuidString)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Text("State: \(model.status.nativeState ?? model.status.phase)")
                                .font(.caption).textSelection(.enabled)
                            if let root = model.status.nativeAppRoot {
                                Text("Data: \(root)").font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let root = model.status.nativeInstallRoot {
                                Text("Runtime: \(root)").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }.font(.callout)
                    }
                    if let version = model.status.nativeVersion {
                        Text("Native Apple container \(version)").font(.callout)
                    }
                    if let error = model.status.error ?? model.error {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding(24)
            }.frame(width: 640, height: 540).task { await model.refresh() }
        }.windowResizability(.contentSize)
    }
}
