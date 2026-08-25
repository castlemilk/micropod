import Foundation

/// Which long-op a notification-worthy activity entry belongs to.
public enum MicropodNotificationKind: String, Equatable {
    case pulls, builds, compose, prune, kernel
}

/// Pure classifier: does an activity entry warrant a system notification, and
/// under which category? The app layer maps kind → user toggle; this stays
/// CLI/UI-free so it is unit-testable.
public func notificationKind(category: String, message: String) -> MicropodNotificationKind? {
    if category == "images" {
        if message.hasPrefix("Pulled ") || message.hasPrefix("Failed to pull ") { return .pulls }
    }
    if category == "build" {
        return .builds
    }
    if category == "compose" {
        if message.hasPrefix("Up complete") || message.hasPrefix("Up failed")
            || message.hasPrefix("Tore down") || message.hasPrefix("Down failed")
        {
            return .compose
        }
    }
    if message.localizedCaseInsensitiveContains("pruned")
        || message.localizedCaseInsensitiveContains("prune failed")
    {
        return .prune
    }
    return nil
}
