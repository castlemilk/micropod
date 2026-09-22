import SwiftUI

/// Shared "card" visual language for the whole app — menu bar popover,
/// dashboard sections, resource tiles. One treatment everywhere: a raised
/// `controlBackgroundColor` fill with a hairline separator stroke and
/// continuous corners, so surfaces read as grouped content on top of the
/// window/popover background.
///
/// NOTE: in `Shape.fill(_:)`, `.primary` resolves to HierarchicalShapeStyle
/// (fully opaque) — always use an explicit `Color` for fills.
extension View {
    /// Applies the standard card surface behind this view.
    func cardSurface(cornerRadius: CGFloat = 10, fillOpacity: Double = 0.65) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
    }
}

/// A titled section card (replaces default GroupBox chrome so every section
/// matches the rest of the app).
struct PanelCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12, fillOpacity: 1)
    }
}

/// Control Center-style action tile used in the menu bar and dashboard:
/// tinted rounded fill + leading icon. `prominent` swaps the fill to the
/// accent color for the single primary action.
struct TileButton: View {
    let title: String
    let icon: String
    var prominent = false
    var horizontalPadding: CGFloat = 10
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: AppIcon.sfName(for: icon))
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(prominent ? .white : .primary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        prominent
                            ? Color.accentColor
                            : Color(nsColor: .controlBackgroundColor).opacity(0.75))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
