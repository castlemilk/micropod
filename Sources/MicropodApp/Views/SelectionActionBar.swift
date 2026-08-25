import SwiftUI

/// Floating bottom action bar for multi-select mode (Photos-style): embedded
/// via safeAreaInset so the list scrolls under it instead of being pushed
/// down by a strip wedged at the top. Compact capsule: count + actions + Done.
struct SelectionActionBar<Actions: View>: View {
    let count: Int
    @ViewBuilder let actions: () -> Actions
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider().frame(height: 14)
            actions()
            Spacer(minLength: 8)
            Button(String(localized: "Done"), action: onDone)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}
