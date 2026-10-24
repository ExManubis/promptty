import Foundation
import RemoteControl
import RemoteProtocol

/// One connection's conversation, without the network: each message in turns into what to do. The
/// first request must be `hello`; after it, the control socket's commands are answered by the
/// control socket's own handler.
public struct RemoteSession: Sendable {
    public enum State: Equatable, Sendable {
        case awaitingHello
        case introduced(client: String)
    }

    public enum Action: Equatable, Sendable {
        case send(RemoteMessage)
        /// A control command, for the control socket's handler; its `ControlResponse` answers `id`.
        case control(ControlRequest, id: RemoteID)
        /// The workspace now answers `id`; from then on its changes are sent.
        case subscribe(id: RemoteID)
        case unsubscribe(id: RemoteID)
        /// A pane's recent commands answer `id`.
        case blocks(BlocksParams, id: RemoteID)
        /// A key pressed in a pane that waits for permission answers `id`.
        case answer(AnswerParams, id: RemoteID)
        /// Push this device the Mac's notices; forget it (its token). The result answers `id`.
        case pushRegister(PushRegistration, id: RemoteID)
        case pushUnregister(token: String, id: RemoteID)
        /// After the reply: a peer that speaks another version is hung up on.
        case close
    }

    public private(set) var state = State.awaitingHello
    /// What `hello` answers with.
    let server: String
    let mac: String
    /// The tailnet user the caller was let in as.
    let user: String

    public init(server: String, mac: String, user: String) {
        self.server = server
        self.mac = mac
        self.user = user
    }

    public mutating func receive(_ data: Data) -> [Action] {
        guard let message = try? RemoteMessage.decode(data) else {
            return [.send(.response(.error(RemoteError(code: RemoteError.parseError, message: "not a JSON-RPC 2.0 message"), id: nil)))]
        }
        // A client's notifications and responses ask for nothing yet.
        guard case .request(let request) = message else { return [] }
        return receive(request)
    }

    private mutating func receive(_ request: RemoteRequest) -> [Action] {
        if request.method == RemoteProtocol.Method.hello {
            guard let hello = try? request.params(as: Hello.self) else {
                return [fail(request, RemoteError.invalidParams, "hello needs the protocol version and the client's name")]
            }
            switch Welcome.answer(hello, server: server, mac: mac, user: user) {
            case .success(let welcome):
                state = .introduced(client: hello.client)
                return [respond(request) { try .result(welcome, id: request.id) }]
            case .failure(let error):
                return [.send(.response(.error(error, id: request.id))), .close]
            }
        }
        guard case .introduced = state else {
            return [fail(request, RemoteError.notIntroduced, "say hello first")]
        }
        switch request.method {
        case RemoteProtocol.Method.subscribe:
            return [.subscribe(id: request.id)]
        case RemoteProtocol.Method.unsubscribe:
            return [.unsubscribe(id: request.id)]
        case RemoteProtocol.Method.blocks:
            guard let params = try? request.params(as: BlocksParams.self) else {
                return [fail(request, RemoteError.invalidParams, "blocks takes a pane and a limit")]
            }
            return [.blocks(params, id: request.id)]
        case RemoteProtocol.Method.answer:
            guard let params = try? request.params(as: AnswerParams.self), AnswerParams.keys.contains(params.key) else {
                return [fail(request, RemoteError.invalidParams, "answer takes a pane and a key: return, escape, y, n, interrupt or a digit")]
            }
            return [.answer(params, id: request.id)]
        case RemoteProtocol.Method.pushRegister:
            guard let registration = try? request.params(as: PushRegistration.self), registration.isValid else {
                return [fail(request, RemoteError.invalidParams, "push.register takes a device token, an environment, a key and its id")]
            }
            return [.pushRegister(registration, id: request.id)]
        case RemoteProtocol.Method.pushUnregister:
            guard let params = try? request.params(as: PushUnregistration.self) else {
                return [fail(request, RemoteError.invalidParams, "push.unregister takes a device token")]
            }
            return [.pushUnregister(token: params.token, id: request.id)]
        default: break
        }
        guard RemoteProtocol.controlMethods.contains(request.method) else {
            return [fail(request, RemoteError.methodNotFound, "no method \(request.method)")]
        }
        guard let params = try? request.params(as: ControlParams.self) else {
            return [fail(request, RemoteError.invalidParams, "\(request.method) takes a target, arguments, flags and options")]
        }
        return [.control(params.request(command: request.method), id: request.id)]
    }

    /// The answer to a request: its result.
    public static func reply<R: Encodable>(_ result: R, to id: RemoteID) -> Action {
        respond(id: id) { try .result(result, id: id) }
    }

    /// The answer to a request that failed.
    public static func reply(_ error: RemoteError, to id: RemoteID) -> Action {
        .send(.response(.error(error, id: id)))
    }

    private func fail(_ request: RemoteRequest, _ code: Int, _ message: String) -> Action {
        .send(.response(.error(RemoteError(code: code, message: message), id: request.id)))
    }

    private func respond(_ request: RemoteRequest, _ make: () throws -> RemoteResponse) -> Action {
        Self.respond(id: request.id, make)
    }

    private static func respond(id: RemoteID, _ make: () throws -> RemoteResponse) -> Action {
        do {
            return .send(.response(try make()))
        } catch {
            return .send(.response(.error(RemoteError(code: RemoteError.internalError, message: "\(error)"), id: id)))
        }
    }
}
