import AppKit
import UserNotifications

/// Sends macOS desktop notifications when Claude Code tabs need attention.
class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var authorized = false

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            self?.authorized = granted
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    /// Send a notification that a tab needs attention.
    /// Only sends if the tab is not currently focused.
    func notifyTabNeedsAttention(tabName: String, reason: TabItem.BadgeState, tabId: UUID) {
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = tabName

        switch reason {
        case .waitingForInput:
            content.body = "Waiting for your input"
        case .needsPermission:
            content.body = "Needs permission approval"
            content.sound = .default
        case .error:
            content.body = "Error occurred"
            content.sound = .default
        default:
            return // Don't notify for .none or .active
        }

        content.userInfo = ["tabId": tabId.uuidString]
        content.threadIdentifier = tabId.uuidString

        let request = UNNotificationRequest(
            identifier: "\(tabId.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification tap — focus the relevant tab.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let tabIdStr = userInfo["tabId"] as? String,
           let tabId = UUID(uuidString: tabIdStr) {
            DispatchQueue.main.async {
                AppDelegate.shared?.windowController?.focusTabById(tabId)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }

    /// Show notifications even when app is in foreground (for non-focused tabs).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner even in foreground
        completionHandler([.banner, .sound])
    }
}
