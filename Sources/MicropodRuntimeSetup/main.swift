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
    var busy = false
    /// The legacy SMAppService background item (runtime helpers before the
    /// root-owned authority). This app never registers it; it only retires
    /// it, on an explicit confirmation, once the authority serves.
    var legacyRegistered = false
    var confirmingRetirement = false
    private let legacyService = SMAppService.daemon(plistName: "com.skunkworq.micropod.runtime.host.plist")
    private let client = IsolatedRuntimeClient()

    var protected: Bool { status.componentProtection == "protected" }

    func refresh() async {
        legacyRegistered = [.enabled, .requiresApproval].contains(legacyService.status)
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

    /// Retires the legacy background item. Only offered while the
    /// root-owned authority serves and reports itself protected, so it can
    /// never take the runtime offline, and only after the confirmation in
    /// this window (no launch argument triggers it).
    func retireLegacy() async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            confirmingRetirement = false
        }
        do {
            let current = try await client.call(.init(action: .status))
            guard current.componentProtection == "protected" else {
                throw MicropodError.message(
                    "The root-owned runtime authority is not serving; the old background item was left in place")
            }
            try await legacyService.unregister()
            await refresh()
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
                        "An administrator installs the runtime helper once, as a root-owned LaunchDaemon: sudo micropod runtime install-authority. Later releases update it without another approval."
                    )
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(
                        model.status.componentProtection.map { "Runtime helper: \($0)" }
                            ?? "Runtime helper: not installed"
                    )
                    .font(.callout).foregroundStyle(model.protected ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                    HStack {
                        Button("Check Again") { Task { await model.refresh() } }
                        Button("Install Dedicated Runtime") { Task { await model.request(.install) } }
                        Button("Start") { Task { await model.request(.start) } }
                        Button("Stop") { Task { await model.request(.stop) } }
                    }.disabled(model.busy)
                    HStack {
                        Button("Verify Runtime") { Task { await model.request(.verify) } }
                        Button("Run Isolated Test") { Task { await model.request(.workload) } }
                    }.disabled(model.busy)
                    if model.legacyRegistered && model.protected {
                        Button("Retire the Old Background Item…") { model.confirmingRetirement = true }
                            .disabled(model.busy)
                            .confirmationDialog(
                                "Retire the old background item?", isPresented: $model.confirmingRetirement
                            ) {
                                Button("Retire", role: .destructive) { Task { await model.retireLegacy() } }
                            } message: {
                                Text(
                                    "The root-owned runtime authority serves now. The old item only runs a helper from /Applications, which yields to it."
                                )
                            }
                    }
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
                            if let count = model.status.pendingOperationCount, count > 0 {
                                Text("Unconfirmed requests: \(count)").font(.caption)
                                ForEach(Array((model.status.pendingOperationRoutes ?? []).enumerated()), id: \.offset) {
                                    _, route in
                                    Text(route).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
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
            }.frame(width: 640, height: 540).task {
                await model.refresh()
            }
        }.windowResizability(.contentSize)
    }
}
