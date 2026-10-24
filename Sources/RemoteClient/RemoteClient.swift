import Foundation
import RemoteProtocol

/// The phone's side of the remote API: a WebSocket to a Mac's PrompTTY, `hello` first, then
/// requests answered by id and the Mac's events as they come.
public final class RemoteClient: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// The connection closed before the answer came.
        case closed
        /// The Mac answered `hello` with something other than a welcome.
        case unexpected(String)
    }

    public let url: URL
    private let clientName: String
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    /// Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [RemoteID: CheckedContinuation<RemoteResponse, Error>] = [:]
    private var closed = false
    private var eventHandler: (@Sendable (RemoteNotification) -> Void)?
    private var closeHandler: (@Sendable (Error?) -> Void)?

    public init(url: URL, clientName: String) {
        self.url = url
        self.clientName = clientName
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
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
        task.resume()
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
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func send(_ message: RemoteMessage, awaiting id: RemoteID) async throws -> RemoteResponse {
        let text = String(decoding: try message.encoded(), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            let isClosed = lock.withLock {
                if closed { return true }
                pending[id] = continuation
                return false
            }
            if isClosed { return continuation.resume(throwing: Failure.closed) }
            task.send(.string(text)) { [weak self] error in
                guard let error, let self else { return }
                let waiting = self.lock.withLock { self.pending.removeValue(forKey: id) }
                waiting?.resume(throwing: error)
            }
        }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(error)
            case .success(let frame):
                let data: Data
                switch frame {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = Data()
                }
                self.handle(data)
                self.receiveNext()
            }
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
    }
}
