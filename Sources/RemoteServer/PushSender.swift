import Foundation
import RemoteProtocol

/// The devices the Mac pushes its notices to (`push.register`), kept in a file of their own: their
/// tokens and the keys their notices are sealed with.
public struct PushDevices: Codable, Equatable, Sendable {
    public private(set) var devices: [PushRegistration] = []

    public init(devices: [PushRegistration] = []) {
        self.devices = devices
    }

    /// A token registered again replaces its earlier registration (a new key, other kinds).
    public mutating func register(_ registration: PushRegistration) {
        devices.removeAll { $0.token == registration.token }
        devices.append(registration)
    }

    @discardableResult
    public mutating func unregister(_ token: String) -> Bool {
        let before = devices.count
        devices.removeAll { $0.token == token }
        return devices.count != before
    }

    public func devices(for kind: PushKind) -> [PushRegistration] {
        devices.filter { $0.kinds.contains(kind.rawValue) }
    }

    public static func load(from url: URL) -> PushDevices {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PushDevices.self, from: $0) } ?? PushDevices()
    }

    /// Readable by the user only: the keys open their notices.
    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Seals a notice for each device that wants it and posts it to the relay (`Relay/`), which hands
/// it to APNs. The relay sees the token and ciphertext only.
public enum PushSender {
    /// What came of one push: sent, or the device is gone (APNs no longer knows its token), or it
    /// failed and the next notice tries again.
    public enum Outcome: Equatable, Sendable {
        case sent
        case gone
        case failed(String)
    }

    /// Posts `body` to the relay: its HTTP status, or an error.
    public typealias Transport = @Sendable (URLRequest) async throws -> Int

    /// The relay's address as typed in Settings, if it is one: http or https with a host.
    public static func relayURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme), url.host != nil else { return nil }
        return url
    }

    public static func request(_ notice: PushNotice, to device: PushRegistration, relay: URL) throws -> URLRequest {
        guard let key = Data(base64Encoded: device.key) else { throw RemoteError(code: RemoteError.invalidParams, message: "the device's key is not base64") }
        let push = RelayPush(token: device.token, environment: device.environment, keyID: device.keyID, sealed: try PushSeal.seal(notice, key: key))
        var request = URLRequest(url: relay, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(push)
        return request
    }

    /// Sends `notice` to every device that wants its kind, each in turn; the outcome by token.
    public static func send(_ notice: PushNotice, devices: PushDevices, relay: URL, transport: Transport) async -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        for device in devices.devices(for: notice.kind) {
            do {
                let status = try await transport(try request(notice, to: device, relay: relay))
                outcomes[device.token] = switch status {
                case 200: .sent
                case 410: .gone
                default: .failed("the relay answered \(status)")
                }
            } catch {
                outcomes[device.token] = .failed(error.localizedDescription)
            }
        }
        return outcomes
    }

    /// URLSession's: the status of the relay's answer.
    public static let urlSession: Transport = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
