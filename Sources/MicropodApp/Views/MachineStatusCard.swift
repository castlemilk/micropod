import SwiftUI

/// The hvf machine at the top of the menu-bar panel: its state and why,
/// engine, containers, cache disk, disk flush, a pending update, and Start,
/// Stop and Restart. Everything goes through `MachineModel` over the API.
/// A deferred stop or restart (containers would be interrupted) asks first
/// and retries with `force`.
struct MachineStatusCard: View {
    @Bindable var model: MachineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: model.color, size: 7, active: model.transitioning)
                Text(model.headline).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.primary).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                actions
            }
            .accessibilityElement(children: .contain)
            if let reason = model.reason {
                Text(reason).font(.system(size: 10)).foregroundStyle(Tokens.Palette.danger)
                    .lineLimit(2).truncationMode(.tail).help(reason)
            }
            let details = [model.engineLine, model.containersLine].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: "  ·  ")).font(.system(size: 10))
                    .foregroundStyle(Tokens.Palette.secondary).lineLimit(1)
            }
            let disks = [model.cacheDiskLine, model.diskFlushLine].compactMap { $0 }
            if !disks.isEmpty {
                Text(disks.joined(separator: "  ·  ")).font(.system(size: 10))
                    .foregroundStyle(Tokens.Palette.tertiary).lineLimit(1).truncationMode(.tail)
                    .help(disks.joined(separator: "\n"))
            }
            if model.updatePending {
                Text(model.updateLabel).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Tokens.Palette.warning.opacity(0.18)))
                    .foregroundStyle(Tokens.Palette.warning).lineLimit(1).fixedSize()
                    .help("A newer machine payload is staged: `micropod update hvf apply`")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Tokens.Radius.lg, fillOpacity: 1)
        .confirmationDialog(
            deferralTitle, isPresented: deferralShown, titleVisibility: .visible, presenting: model.deferral
        ) { _ in
            Button(deferralConfirm, role: .destructive) { Task { await model.confirmDeferral() } }
            Button("Cancel", role: .cancel) { model.cancelDeferral() }
        } message: { deferral in
            Text("This interrupts \(deferral.reason).")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            if model.canStart {
                Button("Start") { Task { await model.perform(.start) } }
                    .accessibilityLabel("Start the machine")
            }
            if model.canStop {
                Button("Stop") { Task { await model.perform(.stop) } }
                    .accessibilityLabel("Stop the machine")
            }
            if model.canRestart {
                Button("Restart") { Task { await model.perform(.restart) } }
                    .accessibilityLabel("Restart the machine")
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    /// The card asks about its own requests; Settings asks about autostart.
    private var deferralShown: Binding<Bool> {
        Binding(
            get: {
                if case .control? = model.deferral?.request { return true }
                return false
            }, set: { if !$0 { model.cancelDeferral() } })
    }

    private var deferralTitle: String {
        model.deferral?.request == .control(.restart) ? "Restart the machine?" : "Stop the machine?"
    }

    private var deferralConfirm: String {
        model.deferral?.request == .control(.restart) ? "Restart anyway" : "Stop anyway"
    }
}
