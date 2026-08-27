import AppKit
import Foundation
import UserNotifications

/// Best-effort notifications. Clicking a link in Slack gives no visual feedback,
/// so when a link *can't* be opened locally we say why rather than silently
/// dumping the user in a browser tab.
///
/// Notifications are a nice-to-have: the menu bar always carries the same
/// information, so nothing breaks if permission is refused.
enum Notifier {

    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // Don't ask for a permission the user has already switched the feature
        // off for. macOS only offers the prompt once, so spending it here would
        // leave the toggle unable to work if it's ever switched back on.
        guard Config.notificationsEnabled else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// No `enabled` flag any more. It was a mutable global written from the
    /// authorisation callback and read from the main thread — a data race — and
    /// it started out false, so every notification posted before that callback
    /// landed was silently dropped. `add` already does nothing when permission
    /// was refused, which is the same outcome without the race.
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard Config.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// What macOS thinks of our notification permission, in a form a settings
    /// row can show. Read live rather than cached: the user can change it in
    /// System Settings at any time, and the app is never told.
    static func permissionDescription() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Blocked in System Settings"
        case .notDetermined: return "Not yet asked"
        @unknown default: return "Unknown"
        }
    }

    /// Deep link to this app's own row in System Settings → Notifications. The
    /// only way back from a denied permission — the app is not allowed to ask
    /// twice.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
        if let url { NSWorkspace.shared.open(url) }
    }
}
