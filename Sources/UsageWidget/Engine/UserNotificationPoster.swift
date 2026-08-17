import Foundation
import UserNotifications

/// Posts a local notification for a near-limit plan. Separated from the decision logic so the
/// once-per-cycle rules can be exercised without actually notifying.
protocol NotificationPosting: AnyObject {
    func post(title: String, body: String)
}

/// Stateless wrapper around `UNUserNotificationCenter`, which is thread-safe, so this is safe
/// to send across a `Task` boundary.
final class UserNotificationPoster: NotificationPosting, @unchecked Sendable {
    /// Ask the OS for permission once. Best-effort; the app still works if the user declines.
    func authorize() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
