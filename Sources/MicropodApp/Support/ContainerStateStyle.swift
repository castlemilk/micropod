import SwiftUI

/// Container state styling — single source of truth for the semantic color
/// and display label of a runtime state. Previously duplicated (and drifting:
/// "exited" was red in list/detail panes but gray in the menu bar).
enum ContainerStateStyle {
    static func color(for state: String) -> Color {
        switch state {
        case "running": .green
        case "exited": .red
        case "stopped": .gray
        case "created": .orange
        default: .orange
        }
    }

    /// Human label for tooltips/rows ("exited" stays as-is; unknown → "unknown").
    static func label(for state: String) -> String {
        state.isEmpty ? "unknown" : state
    }
}
