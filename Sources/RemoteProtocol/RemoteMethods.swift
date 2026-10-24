import Foundation
import RemoteControl

/// The remote protocol's version, and the methods both sides know. The Mac's remote API (PTY-70)
/// and the iPhone app import this module, so they cannot drift apart; each feature that adds
/// messages (subscriptions, prompt answers, mirroring) adds them here.
public enum RemoteProtocol {
    /// Raised when a message changes in a way an older peer would misread.
    public static let version = 1
    /// The versions this side can speak.
    public static let supported: ClosedRange<Int> = 1...1

    public enum Method {
        /// The first request on a connection: the versions are compared, the peers named.
        public static let hello = "hello"
    }

    /// The control socket's commands, each a method of its own (`ls`, `send`, `capture`, …):
    /// `ControlParams` in, `ControlResponse` out, handled by the same code as `promptty`'s.
    public static let controlMethods = ControlCommandLine.commands
}

/// `hello`'s params: the client and the protocol version it speaks.
public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// "PrompTTY for iPhone 0.1", for the Mac's list of connected clients.
    public var client: String

    public init(protocolVersion: Int = RemoteProtocol.version, client: String) {
        self.protocolVersion = protocolVersion
        self.client = client
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case client
    }
}

/// `hello`'s result: the version both will speak, and which Mac and user answered.
public struct Welcome: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// "PrompTTY 2.1".
    public var server: String
    /// The Mac's name ("Mikkel's Mac Studio").
    public var mac: String
    /// The tailnet user the caller was let in as.
    public var user: String

    public init(protocolVersion: Int = RemoteProtocol.version, server: String, mac: String, user: String) {
        self.protocolVersion = protocolVersion
        self.server = server
        self.mac = mac
        self.user = user
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case server, mac, user
    }

    /// The answer to `hello`: the welcome, or the error for a version this side cannot speak.
    public static func answer(_ hello: Hello, server: String, mac: String, user: String) -> Result<Welcome, RemoteError> {
        guard RemoteProtocol.supported.contains(hello.protocolVersion) else {
            return .failure(RemoteError(code: RemoteError.unsupportedVersion,
                                        message: "PrompTTY speaks protocol \(RemoteProtocol.version); this client speaks \(hello.protocolVersion)",
                                        data: .array(RemoteProtocol.supported.map(JSONValue.int))))
        }
        return .success(Welcome(protocolVersion: hello.protocolVersion, server: server, mac: mac, user: user))
    }
}

/// A control command's params: `promptty`'s arguments without the command, which is the method,
/// and without a caller pane, which a remote client does not have.
public struct ControlParams: Codable, Equatable, Sendable {
    /// The pane to act on, by id, id suffix or label (`PaneTarget`).
    public var target: String?
    public var arguments: [String]
    public var flags: Set<String>
    public var options: [String: String]

    public init(target: String? = nil, arguments: [String] = [], flags: Set<String> = [], options: [String: String] = [:]) {
        self.target = target
        self.arguments = arguments
        self.flags = flags
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        flags = try container.decodeIfPresent(Set<String>.self, forKey: .flags) ?? []
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(target, forKey: .target)
        if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
        // Sorted, so the same params are always the same text.
        if !flags.isEmpty { try container.encode(flags.sorted(), forKey: .flags) }
        if !options.isEmpty { try container.encode(options, forKey: .options) }
    }

    private enum CodingKeys: String, CodingKey {
        case target, arguments, flags, options
    }

    /// The request the control socket's handler takes.
    public func request(command: String) -> ControlRequest {
        ControlRequest(command: command, caller: nil, target: target, arguments: arguments, flags: flags, options: options)
    }
}
