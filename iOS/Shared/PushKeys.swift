import Foundation
import RemoteProtocol

/// The keys the phone's Macs seal its push notifications with, one per Mac, shared with the
/// notification service extension (`NotificationService`) through the app group. A key never
/// leaves the phone except to its Mac, over the tailnet, when the phone registers there.
enum PushKeys {
    static let group = "group.dev.promptty.PrompTTY2.phone"

    private static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }
    /// Key id → key, base64.
    private static let keysKey = "pushKeys"
    /// Mac id → key id.
    private static let macsKey = "pushKeyIDs"

    /// The Mac's key and its id, made the first time.
    static func key(for mac: UUID) -> (id: String, key: Data) {
        var macs = defaults.dictionary(forKey: macsKey) as? [String: String] ?? [:]
        var keys = defaults.dictionary(forKey: keysKey) as? [String: String] ?? [:]
        if let id = macs[mac.uuidString], let key = keys[id].flatMap({ Data(base64Encoded: $0) }) { return (id, key) }
        let id = UUID().uuidString
        let key = PushSeal.newKey()
        keys[id] = key.base64EncodedString()
        macs[mac.uuidString] = id
        defaults.set(keys, forKey: keysKey)
        defaults.set(macs, forKey: macsKey)
        return (id, key)
    }

    /// The key a push names, for opening it.
    static func key(id: String) -> Data? {
        (defaults.dictionary(forKey: keysKey) as? [String: String])?[id].flatMap { Data(base64Encoded: $0) }
    }

    /// The Mac a key belongs to, for opening the tab a push is about.
    static func mac(forKey id: String) -> UUID? {
        (defaults.dictionary(forKey: macsKey) as? [String: String])?.first { $0.value == id }.flatMap { UUID(uuidString: $0.key) }
    }

    /// A removed Mac's pushes can no longer be opened.
    static func forget(mac: UUID) {
        var macs = defaults.dictionary(forKey: macsKey) as? [String: String] ?? [:]
        var keys = defaults.dictionary(forKey: keysKey) as? [String: String] ?? [:]
        guard let id = macs.removeValue(forKey: mac.uuidString) else { return }
        keys[id] = nil
        defaults.set(keys, forKey: keysKey)
        defaults.set(macs, forKey: macsKey)
    }
}
