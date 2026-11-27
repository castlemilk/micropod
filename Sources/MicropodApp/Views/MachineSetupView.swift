import AppKit
import MicropodCore
import SwiftUI

/// First run of the hvf machine from the app: one button that asks the API
/// to set it up (`SetupMachine`: the runtime files and base disk from this
/// app's bundle, a cache disk, then a start), the steps as they came back,
/// and, when the bundle has no base disk, a local disk image to choose or
/// the exact command to run instead. Nothing is downloaded from here.
struct MachineSetupView: View {
    let machine: MachineModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text(String(localized: "Set up the Linux machine"))
                    .font(.callout.weight(.semibold))
                Spacer()
                if machine.phase == .running {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Text(
                String(
                    localized:
                        "Containers run in one Linux machine on this Mac. Setting it up copies the runtime from this app, creates its disks and starts it."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !machine.setupSteps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(machine.setupSteps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("machineSetup.steps")
            }

            if let error = machine.setupError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tokens.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if machine.settingUp {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Setting up… (copying the disk and starting the machine)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if machine.phase != .running {
                    Button {
                        Task { await machine.setUp() }
                    } label: {
                        IconLabel(title: String(localized: "Set Up Machine"), icon: "start", fallback: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("machineSetup.start")
                    if machine.setupFailure?.id == "disk" {
                        Button(String(localized: "Choose Disk Image…")) { chooseDisk() }
                            .accessibilityIdentifier("machineSetup.chooseDisk")
                    }
                }
                Spacer(minLength: 0)
            }

            if machine.setupFailure != nil || machine.setupError != nil {
                HStack(spacing: 6) {
                    Text(String(localized: "Or in Terminal:"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(machine.setupCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(machine.setupCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Copy the command"))
                }
            }
        }
    }

    private func stepRow(_ step: Micropod_V1_SetupMachineStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.symbol(step.state))
                .foregroundStyle(Self.color(step.state))
                .font(.caption)
            Text(Self.title(step.id))
                .font(.caption.weight(.medium))
                .frame(width: 96, alignment: .leading)
            Text(step.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseDisk() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an ext4 disk image for the machine")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await machine.setUp(diskFrom: url) }
    }

    static func title(_ id: String) -> String {
        switch id {
        case "runtime-files": String(localized: "Runtime files")
        case "disk": String(localized: "Disk")
        case "cache-disk": String(localized: "Cache disk")
        case "start": String(localized: "Start")
        case "default-runtime": String(localized: "Default runtime")
        default: id
        }
    }

    static func symbol(_ state: String) -> String {
        switch state {
        case "done", "kept": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "skipped": "minus.circle"
        default: "circle.dotted"
        }
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "done", "kept": .green
        case "failed": Tokens.Palette.danger
        default: Tokens.Palette.tertiary
        }
    }
}
