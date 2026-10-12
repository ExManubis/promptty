import AppKit
import UserNotifications
import WorkspaceModel

enum Notifications {
    /// Posts a notification; clicking one that names a pane brings that pane forward.
    static func post(title: String, body: String, pane: PaneID?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let pane { content.userInfo = ["pane": pane.rawValue.uuidString] }
            // One notification per pane: a newer one replaces it.
            let request = UNNotificationRequest(identifier: pane.map(identifier) ?? UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    /// The user looked at the pane: its notification is no longer news.
    static func remove(for pane: PaneID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(pane)])
    }

    private static func identifier(_ pane: PaneID) -> String { "pane-\(pane.rawValue.uuidString)" }
}

/// Shows PrompTTY's notifications also while it is in front (they are about panes not in view),
/// and opens the pane of the one clicked.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let reveal: @MainActor (PaneID) -> Void

    init(reveal: @escaping @MainActor (PaneID) -> Void) {
        self.reveal = reveal
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["pane"] as? String, let id = UUID(uuidString: raw) else { return }
        await reveal(PaneID(rawValue: id))
    }
}
