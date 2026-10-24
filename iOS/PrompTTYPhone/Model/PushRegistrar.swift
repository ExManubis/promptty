import os
import RemoteProtocol
import UIKit
import UserNotifications

/// Push notifications on the phone: asks for them once a real Mac connects, keeps the device
/// token APNs gives, and has each Mac it connects to push to it (`MacConnection.registerPush`).
/// A tapped notification opens its tab.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

    /// The device token, hex, once APNs has given one.
    private(set) var token: String?
    /// Called when the token comes (the connected Mac registers it).
    var onToken: (() -> Void)?
    /// A tapped notification: its Mac and tab.
    var onOpen: ((UUID, UUID) -> Void)?
    private var asked = false
    private let log = Logger(subsystem: "dev.promptty.PrompTTY2.phone", category: "push")

    /// What the Mac pushes, from the phone's Settings.
    static var kinds: [String] {
        UserDefaults.standard.stringArray(forKey: "pushKinds") ?? [PushKind.permission.rawValue, PushKind.done.rawValue]
    }

    static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    /// Asks for notifications, the first time a Mac connects; then registers with APNs.
    func start() {
        guard !asked else { return }
        asked = true
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return log.notice("notifications not allowed") }
            log.notice("registering for remote notifications")
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func received(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        log.notice("device token received")
        onToken?()
    }

    func failed(_ error: Error) {
        log.error("no device token: \(error.localizedDescription, privacy: .public)")
    }

    /// What to send a Mac so it pushes to this phone, sealed with that Mac's key.
    func registration(for mac: UUID) -> PushRegistration? {
        guard let token else { return nil }
        let key = PushKeys.key(for: mac)
        return PushRegistration(token: token, environment: Self.environment, device: UIDevice.current.name, kinds: Self.kinds,
                                keyID: key.id, key: key.key.base64EncodedString())
    }

    func opened(keyID: String?, tab: String?) {
        guard let keyID, let mac = PushKeys.mac(forKey: keyID), let tab = tab.flatMap(UUID.init(uuidString:)) else { return }
        onOpen?(mac, tab)
    }
}

/// The app's delegate, for what SwiftUI doesn't hand on: the device token, and notifications.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRegistrar.shared.received(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushRegistrar.shared.failed(error) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let keyID = info["k"] as? String, tab = info["tab"] as? String
        await MainActor.run { PushRegistrar.shared.opened(keyID: keyID, tab: tab) }
    }
}
