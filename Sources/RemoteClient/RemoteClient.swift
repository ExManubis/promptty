import Foundation
import Network
import RemoteProtocol

/// The phone's side of the remote API: a WebSocket to a Mac's PrompTTY, `hello` first, then
/// requests answered by id and the Mac's events as they come. On Network.framework rather than
/// URLSession, for a TCP connection without Nagle: a key's echo is a few bytes, and waiting to
/// bundle them with the next is what made typing feel slow.
public final class RemoteClient: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// The connection closed before the answer came.
        case closed
        /// The Mac answered `hello` with something other than a welcome.
        case unexpected(String)
        /// The Mac could not be reached: no route, or nothing listening.
        case unreachable
        /// Connecting took longer than `connectTimeout`.
        case timedOut
    }

    /// How long connecting may take before it is given up.
    static let connectTimeout: TimeInterval = 10

    public let url: URL
    private let clientName: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.promptty.remote-client", qos: .userInitiated)

    /// Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [RemoteID: CheckedContinuation<RemoteResponse, Error>] = [:]
    private var closed = false
    private var ready: CheckedContinuation<Void, Error>?
    private var eventHandler: (@Sendable (RemoteNotification) -> Void)?
    private var closeHandler: (@Sendable (Error?) -> Void)?

    public init(url: URL, clientName: String) {
        self.url = url
        self.clientName = clientName
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: url.scheme == "wss" ? NWProtocolTLS.Options() : nil, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 16 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    /// The Mac's events (`workspace`, `command.finished`), on a background thread, in order.
    public func onEvent(_ handler: @escaping @Sendable (RemoteNotification) -> Void) {
        lock.withLock { eventHandler = handler }
    }

    /// Called once when the connection ends, with why if it was not closed on purpose.
    public func onClose(_ handler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { closeHandler = handler }
    }

    /// Opens the connection and says hello.
    public func connect() async throws -> Welcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { ready = continuation }
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
                self?.becameReady(throwing: Failure.timedOut)
            }
        }
        receiveNext()
        return try await call(RemoteProtocol.Method.hello, Hello(client: clientName), as: Welcome.self)
    }

    /// A request and its typed answer; a `RemoteError` when the Mac answers with one.
    public func call<P: Encodable, R: Decodable>(_ method: String, _ params: P, as type: R.Type) async throws -> R {
        let id: RemoteID = .number(lock.withLock {
            defer { nextID += 1 }
            return nextID
        })
        let message = RemoteMessage.request(try RemoteRequest(id: id, method: method, params: params))
        let response = try await send(message, awaiting: id)
        return try response.result(as: type)
    }

    /// A request without params.
    public func call<R: Decodable>(_ method: String, as type: R.Type) async throws -> R {
        try await call(method, [String: String](), as: type)
    }

    public func close() {
        finish(nil)
        connection.cancel()
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            becameReady(throwing: nil)
        case .waiting:
            // No route or refused: Network.framework would keep trying; the app retries itself.
            becameReady(throwing: Failure.unreachable)
        case .failed(let error):
            becameReady(throwing: error)
            finish(error)
        case .cancelled:
            becameReady(throwing: Failure.closed)
            finish(nil)
        default:
            break
        }
    }

    /// Resumes `connect` once: ready, or why not.
    private func becameReady(throwing error: Error?) {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<Void, Error>? in
            defer { ready = nil }
            return ready
        }) else { return }
        if let error {
            continuation.resume(throwing: error)
            finish(error)
        } else {
            continuation.resume()
        }
    }

    private func send(_ message: RemoteMessage, awaiting id: RemoteID) async throws -> RemoteResponse {
        let data = try message.encoded()
        return try await withCheckedThrowingContinuation { continuation in
            let isClosed = lock.withLock {
                if closed { return true }
                pending[id] = continuation
                return false
            }
            if isClosed { return continuation.resume(throwing: Failure.closed) }
            send(data, opcode: .text) { [weak self] error in
                guard let error, let self else { return }
                let waiting = self.lock.withLock { self.pending.removeValue(forKey: id) }
                waiting?.resume(throwing: error)
            }
        }
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, then: (@Sendable (Error?) -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            then?(error)
        })
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { return self.finish(nil) }
            if let data, !data.isEmpty { self.handle(data) }
            self.receiveNext()
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? RemoteMessage.decode(data) else { return }
        switch message {
        case .response(let response):
            guard let id = response.id else {
                // An answer to no request: the Mac turning the connection away (not the owner).
                if case .error(let error) = response.outcome { finish(error) }
                return
            }
            let waiting = lock.withLock { pending.removeValue(forKey: id) }
            waiting?.resume(returning: response)
        case .notification(let event):
            let handler = lock.withLock { eventHandler }
            handler?(event)
        case .request:
            break
        }
    }

    /// Fails every request still waiting, and tells the close handler once.
    private func finish(_ error: Error?) {
        let (waiting, handler) = lock.withLock { () -> ([CheckedContinuation<RemoteResponse, Error>], (@Sendable (Error?) -> Void)?) in
            guard !closed else { return ([], nil) }
            closed = true
            defer { pending.removeAll() }
            return (Array(pending.values), closeHandler)
        }
        for continuation in waiting { continuation.resume(throwing: error ?? Failure.closed) }
        handler?(error)
        connection.cancel()
    }
}
