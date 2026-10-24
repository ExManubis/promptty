import RemoteProtocol
import UserNotifications

/// Opens a push from a Mac: the relay passed on only a sealed notice (`s`) and its key's id (`k`);
/// the key is the phone's own (`PushKeys`). One it can't open shows the relay's placeholder.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let info = request.content.userInfo
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let keyID = info["k"] as? String, let sealed = info["s"] as? String, let key = PushKeys.key(id: keyID),
              let notice = try? PushSeal.open(sealed, key: key)
        else { return contentHandler(request.content) }
        content.title = notice.title
        content.subtitle = notice.mac
        content.body = notice.body
        // One notification per pane: a newer one replaces it.
        if let pane = notice.pane { content.threadIdentifier = pane }
        content.userInfo = ["k": keyID, "tab": notice.tab ?? "", "pane": notice.pane ?? ""]
        contentHandler(content)
    }
}
