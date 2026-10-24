import Foundation

/// What the Mac and the phone send each other over the remote connection: JSON-RPC 2.0, one message
/// per WebSocket text frame. A request expects a response with its id; a notification (an event,
/// the Mac telling the phone what changed) expects none.
public enum RemoteMessage: Equatable, Sendable {
    case request(RemoteRequest)
    case response(RemoteResponse)
    case notification(RemoteNotification)

    /// The message as it goes on the wire: keys sorted, so the same message is always the same text.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RemoteMessage {
        try JSONDecoder().decode(RemoteMessage.self, from: data)
    }
}

/// A request's id, which its response repeats: a number or a string, as JSON-RPC allows.
public enum RemoteID: Codable, Hashable, Sendable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case number(Int)
    case string(String)

    public init(integerLiteral value: Int) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .number(value) } else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct RemoteRequest: Equatable, Sendable {
    public var id: RemoteID
    public var method: String
    public var params: JSONValue?

    public init(id: RemoteID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// (Its fields set here: `JSONValue` is itself `Encodable`, so `self.init` would call this again.)
    public init<P: Encodable>(id: RemoteID, method: String, params: P) throws {
        self.id = id
        self.method = method
        self.params = try JSONValue(encoding: params)
    }

    /// The params read as the method's type; a missing params reads as an empty object.
    public func params<P: Decodable>(as type: P.Type) throws -> P {
        try (params ?? .object([:])).decode(type)
    }
}

public struct RemoteResponse: Equatable, Sendable {
    /// Nil only when the request could not be read far enough to find its id.
    public var id: RemoteID?
    public var outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case result(JSONValue)
        case error(RemoteError)
    }

    public init(id: RemoteID?, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }

    public static func result<R: Encodable>(_ result: R, id: RemoteID) throws -> RemoteResponse {
        RemoteResponse(id: id, outcome: .result(try JSONValue(encoding: result)))
    }

    public static func error(_ error: RemoteError, id: RemoteID?) -> RemoteResponse {
        RemoteResponse(id: id, outcome: .error(error))
    }

    /// The result read as the method's type, or the error thrown.
    public func result<R: Decodable>(as type: R.Type) throws -> R {
        switch outcome {
        case .result(let value): return try value.decode(type)
        case .error(let error): throw error
        }
    }
}

/// An event: something changed, nothing is expected back.
public struct RemoteNotification: Equatable, Sendable {
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }

    public init<P: Encodable>(method: String, params: P) throws {
        self.method = method
        self.params = try JSONValue(encoding: params)
    }

    public func params<P: Decodable>(as type: P.Type) throws -> P {
        try (params ?? .object([:])).decode(type)
    }
}

/// Why a request failed. The protocol's own failures (a message that cannot be read, a method that
/// does not exist) have JSON-RPC's codes; PrompTTY's have codes of its own in the range JSON-RPC
/// leaves to servers. A control command that runs and fails is not an error: its result carries
/// the status `promptty` would exit with (`ControlResponse`).
public struct RemoteError: Codable, Equatable, Sendable, Error {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// The peer speaks a protocol version this side does not; `data` lists the ones it does.
    public static let unsupportedVersion = -32001
    /// The caller is not allowed in: not the Mac's owner on the tailnet.
    public static let notAllowed = -32002
    /// A request before `hello`.
    public static let notIntroduced = -32003
}

extension RemoteMessage: Codable {
    private enum Keys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == "2.0" else {
            throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: container, debugDescription: "not JSON-RPC 2.0")
        }
        let id = try container.decodeIfPresent(RemoteID.self, forKey: .id)
        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
            if let id {
                self = .request(RemoteRequest(id: id, method: method, params: params))
            } else {
                self = .notification(RemoteNotification(method: method, params: params))
            }
        } else if let error = try container.decodeIfPresent(RemoteError.self, forKey: .error) {
            self = .response(RemoteResponse(id: id, outcome: .error(error)))
        } else if container.contains(.result) {
            self = .response(RemoteResponse(id: id, outcome: .result(try container.decode(JSONValue.self, forKey: .result))))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .method, in: container, debugDescription: "neither a request, a notification nor a response")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        switch self {
        case .request(let request):
            try container.encode(request.id, forKey: .id)
            try container.encode(request.method, forKey: .method)
            try container.encodeIfPresent(request.params, forKey: .params)
        case .notification(let notification):
            try container.encode(notification.method, forKey: .method)
            try container.encodeIfPresent(notification.params, forKey: .params)
        case .response(let response):
            // JSON-RPC answers an unreadable request with a null id.
            if let id = response.id { try container.encode(id, forKey: .id) } else { try container.encodeNil(forKey: .id) }
            switch response.outcome {
            case .result(let value): try container.encode(value, forKey: .result)
            case .error(let error): try container.encode(error, forKey: .error)
            }
        }
    }
}
