import Foundation

/// The Macs added on this phone, kept in its defaults.
enum SavedMacs {
    private static let key = "macs"

    static func load() -> [PhoneMac] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let macs = try? JSONDecoder().decode([PhoneMac].self, from: data) else { return [] }
        return macs
    }

    static func save(_ macs: [PhoneMac]) {
        let saved = macs.filter { !$0.isDemo }.map { mac -> PhoneMac in
            var mac = mac
            mac.online = false
            mac.waiting = 0
            mac.status = ""
            return mac
        }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: key) }
    }
}
