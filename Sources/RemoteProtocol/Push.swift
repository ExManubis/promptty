import CryptoKit
import Foundation

// Push notifications: iOS drops a background app's socket, so "Claude needs you" reaches the phone
// through Apple's push service. The phone gives the Mac its device token and a key of its own
// (`push.register`); the Mac seals each notice with that key and hands it to a relay that holds
// the APNs signing key, so the relay only sees a token and ciphertext. The phone's notification
// service extension opens it (`PushSeal`).

extension RemoteProtocol.Method {
    /// Push this device the Mac's notices (`PushRegistration` → `PushRegistered`).
    public static let pushRegister = "push.register"
    /// No more pushes to this device token (`PushUnregistration` → `PushRegistered`).
    public static let pushUnregister = "push.unregister"
}

public struct PushRegistration: Codable, Equatable, Sendable {
    /// The APNs device token, hex.
    public var token: String
    /// APNs' sandbox ("development", a Debug build) or production.
    public var environment: String
    /// The phone's name for itself ("Mikkel's iPhone"), as Settings lists it on the Mac.
    public var device: String
    /// Which notices: `PushKind` raw values.
    public var kinds: [String]
    /// Names the key below, so the phone's extension knows which Mac sealed a push.
    public var keyID: String
    /// The 32-byte key, base64, the Mac seals with (ChaCha20-Poly1305).
    public var key: String

    public init(token: String, environment: String, device: String, kinds: [String], keyID: String, key: String) {
        self.token = token
        self.environment = environment
        self.device = device
        self.kinds = kinds
        self.keyID = keyID
        self.key = key
    }

    public static let environments: Set<String> = ["development", "production"]

    /// A token is hex; a key 32 bytes.
    public var isValid: Bool {
        (32...200).contains(token.count) && token.allSatisfy(\.isHexDigit) && Self.environments.contains(environment)
            && Data(base64Encoded: key)?.count == 32 && (1...64).contains(keyID.count) && device.count <= 100
    }
}

public struct PushUnregistration: Codable, Equatable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public struct PushRegistered: Codable, Equatable, Sendable {
    public var token: String
    /// Pushes go out: the Mac has a relay to send them through.
    public var relay: Bool

    public init(token: String, relay: Bool) {
        self.token = token
        self.relay = relay
    }
}

/// What a device can choose to be told about.
public enum PushKind: String, Codable, CaseIterable, Sendable {
    /// An agent asks for permission, or needs attention.
    case permission
    /// An agent finished its turn.
    case done
    /// A long command finished or failed (the Mac's threshold, Settings › Tabs).
    case command
}

/// A notice as the phone shows it, before sealing.
public struct PushNotice: Codable, Equatable, Sendable {
    public var kind: PushKind
    public var title: String
    public var body: String
    /// The Mac's name, as the phone's notification says where it happened.
    public var mac: String
    public var pane: String?
    public var tab: String?

    public init(kind: PushKind, title: String, body: String, mac: String, pane: String? = nil, tab: String? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.mac = mac
        self.pane = pane
        self.tab = tab
    }
}

/// What the Mac hands the relay: where to, and the sealed notice.
public struct RelayPush: Codable, Equatable, Sendable {
    public var token: String
    public var environment: String
    public var keyID: String
    /// `PushSeal.seal`'s output, base64.
    public var sealed: String

    public init(token: String, environment: String, keyID: String, sealed: String) {
        self.token = token
        self.environment = environment
        self.keyID = keyID
        self.sealed = sealed
    }
}

/// Seals a notice with the phone's key (ChaCha20-Poly1305: nonce, ciphertext and tag together).
public enum PushSeal {
    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func seal(_ notice: PushNotice, key: Data) throws -> String {
        let plain = try JSONEncoder().encode(notice)
        return try ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined.base64EncodedString()
    }

    public static func open(_ sealed: String, key: Data) throws -> PushNotice {
        guard let data = Data(base64Encoded: sealed) else { throw CryptoKitError.incorrectParameterSize }
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: SymmetricKey(data: key))
        return try JSONDecoder().decode(PushNotice.self, from: plain)
    }
}
