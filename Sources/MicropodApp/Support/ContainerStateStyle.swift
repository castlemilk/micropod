import SwiftUI

/// Container state styling — single source of truth for the semantic color
/// and display label of a runtime state. Previously duplicated (and drifting:
/// "exited" was red in list/detail panes but gray in the menu bar).
enum ContainerStateStyle {
    static func color(for state: String) -> Color {
        switch state {
        case "running": Tokens.Palette.success
        case "exited", "stopped": Tokens.Palette.tertiary
        case "failed", "dead": Tokens.Palette.danger
        case "created", "starting": Tokens.Palette.warning
        default: Tokens.Palette.tertiary
        }
    }

    /// Human label for tooltips/rows ("exited" stays as-is; unknown → "unknown").
    static func label(for state: String) -> String {
        state.isEmpty ? "unknown" : state
    }
}
