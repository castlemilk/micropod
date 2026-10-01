import MicropodCore
import SwiftUI

/// Route identity and native actions share one hierarchy at every pane width.
struct WorkspacePageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    let icon: String
    var fallback: String = "square"
    @ViewBuilder var actions: () -> Actions

    init(
        title: String, subtitle: String? = nil, icon: String, fallback: String = "square",
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.fallback = fallback
        self.actions = actions
    }

    var body: some View {
        ResponsiveRow(spacing: Tokens.Spacing.lg) {
            HStack(spacing: Tokens.Spacing.md) {
                WorkspaceIconTile(name: icon, size: 40, iconSize: 22, fallback: fallback)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(title)
                        .font(Tokens.Typography.pageTitle)
                        .foregroundStyle(Tokens.Palette.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(Tokens.Typography.metadata)
                            .foregroundStyle(Tokens.Palette.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } trailing: {
            actions()
        }
    }
}

extension WorkspacePageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, icon: String, fallback: String = "square") {
        self.init(title: title, subtitle: subtitle, icon: icon, fallback: fallback) { EmptyView() }
    }
}

/// Small reusable pictogram tile; the vector itself is decoded once by WorkspaceIcon.
struct WorkspaceIconTile: View {
    let name: String
    var size: CGFloat = 32
    var iconSize: CGFloat = 18
    var color: Color = Tokens.Palette.accentText
    var fallback: String = "square"

    var body: some View {
        WorkspaceIcon(name: name, size: iconSize, fallback: fallback)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .accessibilityHidden(true)
    }
}

/// Same state vocabulary in compact table columns and wider inspector headers.
struct WorkspaceStatusBadge: View {
    let title: String
    let color: Color
    var compact = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            StatusDot(color: color, size: 6)
            Text(title)
                .font(Tokens.Typography.metadata)
                .foregroundStyle(compact ? Tokens.Palette.secondary : color)
                .lineLimit(compact ? 2 : 1)
        }
        .padding(.horizontal, compact ? 0 : Tokens.Spacing.sm)
        .padding(.vertical, compact ? 0 : Tokens.Spacing.xs)
        .background {
            if !compact {
                Capsule().fill(color.opacity(0.10))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// A static measured budget, shared by the tray and full cache/storage screens.
/// Zero caps have no ratio; the caller explains whether that means disabled or unlimited.
struct WorkspaceBudgetMeter: View {
    let used: UInt64
    let cap: UInt64
    let label: String
    var color: Color = Tokens.Palette.success
    var height: CGFloat = 6

    static func fraction(used: UInt64, cap: UInt64) -> Double {
        guard cap > 0 else { return 0 }
        return min(1, Double(used) / Double(cap))
    }

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Tokens.Palette.separator.opacity(0.55))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(cap > 0 && used > cap ? Tokens.Palette.warning : color)
                        .frame(width: geometry.size.width * Self.fraction(used: used, cap: cap))
                }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(
            cap > 0
                ? "\(ByteFormat.string(used)) of \(ByteFormat.string(cap))"
                : "\(ByteFormat.string(used)); no configured ratio")
    }
}

/// A glance reading, without an independent subscription or decorative sparkline.
struct WorkspaceMetric: View {
    let title: String
    let value: String
    let icon: String
    var detail: String?
    var color: Color = Tokens.Palette.accentText
    var fallback: String = "square"

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(spacing: Tokens.Spacing.sm) {
                WorkspaceIcon(name: icon, size: 14, fallback: fallback)
                    .foregroundStyle(color)
                Text(title)
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.secondary)
            }
            Text(value)
                .font(Tokens.Typography.metric)
                .foregroundStyle(Tokens.Palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(Tokens.Typography.metadata)
                    .foregroundStyle(Tokens.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.md)
        .cardSurface(fillOpacity: 1)
        .accessibilityElement(children: .combine)
    }
}

/// Quiet inspector selection state using the same operational icon family.
struct WorkspaceSelectionPlaceholder: View {
    let title: String
    let description: String
    let icon: String
    var fallback: String = "square"

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: Tokens.Spacing.md) {
            WorkspaceIconTile(name: icon, size: 48, iconSize: 26, fallback: fallback)
            Text(title)
                .font(Tokens.Typography.section)
                .foregroundStyle(Tokens.Palette.primary)
            Text(description)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.secondary)
                .frame(maxWidth: 280)
        }
        .multilineTextAlignment(.center)
        .padding(Tokens.Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
