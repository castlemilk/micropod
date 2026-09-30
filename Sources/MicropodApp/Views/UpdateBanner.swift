import SwiftUI

/// Pinned under the toolbar while an update is downloading or waiting to be
/// installed — Sparkle installs silently on quit, and Micropod rarely quits,
/// so without this an update could sit staged and unseen.
struct UpdateBanner: View {
    let updates: UpdateController
    @State private var dismissedVersion: String?

    var body: some View {
        if let version = visibleVersion {
            HStack(spacing: 10) {
                Image(systemName: updates.status == .readyToInstall ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 13))
                Text(message(version))
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if updates.status == .readyToInstall {
                    Button("Restart to Update") { updates.applyStagedUpdate() }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
                Button {
                    dismissedVersion = version
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide until next launch")
                .accessibilityLabel("Dismiss update notice")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
        }
    }

    private var visibleVersion: String? {
        let version: String?
        switch updates.status {
        case .readyToInstall: version = updates.stagedVersion
        case .updateAvailable: version = updates.availableVersion
        default: version = nil
        }
        guard let version, version != dismissedVersion else { return nil }
        return version
    }

    private func message(_ version: String) -> String {
        guard updates.status == .readyToInstall else { return "Downloading Micropod \(version)…" }
        return updates.installsAutomatically
            ? "Micropod \(version) is ready. It installs itself when you're away and nothing is running — or restart now."
            : "Micropod \(version) is ready to install."
    }
}
