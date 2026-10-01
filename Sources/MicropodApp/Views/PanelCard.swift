import SwiftUI

/// Keeps related controls together, stacking them when their natural widths
/// exceed the pane. The compact layout lets text wrap without shrinking buttons.
struct ResponsiveRow<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) {
                leading().fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: spacing)
                trailing().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: spacing) {
                leading().fixedSize(horizontal: false, vertical: true)
                trailing()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

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
                .fill(Tokens.Palette.surface.opacity(fillOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Tokens.Palette.separator, lineWidth: 0.5)
                }
        }
    }
}

/// A titled section card (replaces default GroupBox chrome so every section
/// matches the rest of the app).
struct PanelCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    init(
        title: String? = nil, icon: String? = nil, subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            if let title {
                HStack(spacing: Tokens.Spacing.sm) {
                    if let icon {
                        WorkspaceIcon(name: icon, size: 16)
                            .foregroundStyle(Tokens.Palette.secondary)
                    }
                    Text(title)
                        .font(Tokens.Typography.section)
                        .foregroundStyle(Tokens.Palette.primary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.secondary)
            }
            content()
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Tokens.Radius.lg, fillOpacity: 1)
    }
}

/// The single status-dot used across the app (dashboard, sidebar, rail).
/// Static `circle.fill` when the state is settled; `breathe` while the
/// runtime is in a transitional state (starting/restarting/healing) — a
/// symbol effect so Reduce Motion can disable it cleanly.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .symbolEffect(.breathe, isActive: active && !reduceMotion)
    }
}
