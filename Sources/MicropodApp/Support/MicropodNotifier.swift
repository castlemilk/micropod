import Foundation
import MicropodCore
import UserNotifications

/// Opt-in system notifications for long-running ops. The activity feed is the
/// source of truth; notifications are a projection driven by per-category
/// toggles in Settings.
@MainActor
final class MicropodNotifier {
    static let shared = MicropodNotifier()

    private var requestedAuthorization = false

    private init() {}

    /// Decides whether an activity entry is notification-worthy and posts it
    /// if its category toggle is enabled.
    func maybePost(category: String, message: String, level: ActivityEntry.Level) {
        guard let kind = notificationKind(category: category, message: message), isEnabled(kind) else {
            return
        }
        post(title: title(for: kind, message: message), message: message, isError: level == .error)
    }

    func postKernel(result: String, isError: Bool) {
        guard isEnabled(.kernel) else { return }
        post(title: isError ? "Kernel install failed" : "Kernel installed", message: result, isError: isError)
    }

    // MARK: - Toggles

    private func defaultsKey(for kind: MicropodNotificationKind) -> String {
        switch kind {
        case .pulls: UserDefaultsKeys.notifyPulls
        case .builds: UserDefaultsKeys.notifyBuilds
        case .compose: UserDefaultsKeys.notifyCompose
        case .prune: UserDefaultsKeys.notifyPrune
        case .kernel: UserDefaultsKeys.notifyKernel
        }
    }

    private func title(for kind: MicropodNotificationKind, message: String) -> String {
        switch kind {
        case .pulls: "Image pull"
        case .builds: "Build"
        case .compose: "Compose"
        case .prune: "Prune"
        case .kernel: "Kernel"
        }
    }

    private func isEnabled(_ kind: MicropodNotificationKind) -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey(for: kind))
    }

    // MARK: - Posting

    private func post(title: String, message: String, isError: Bool) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = isError ? "\(title) failed" : title
        content.body = message
        content.sound = isError ? .default : nil
        content.userInfo = ["micropod.category": title]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
