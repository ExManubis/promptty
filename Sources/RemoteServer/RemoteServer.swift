import Foundation
import Network
import RemoteControl
import RemoteProtocol

/// The remote API: a WebSocket server on the Mac's Tailscale address, speaking `RemoteProtocol`.
/// Tailscale names each caller and only the Mac's owner is let in (`TailnetIdentity`); the control
/// socket's commands are answered by the control socket's own handler. Like the control socket it
/// caps its connections, the size of a message and the time a caller has to introduce itself.
public final class RemoteServer: @unchecked Sendable {
    /// A device connected to the remote API, for Settings' list.
    public struct Client: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// What it called itself in `hello`, once it has.
        public var name: String?
        public var user: String
        public var address: String
        public var since: Date
    }

    /// Answers a control command; called on the main queue, it must call its completion once.
    public typealias Handler = @Sendable (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void
    /// Who is at an address on the tailnet.
    public typealias Identify = @Sendable (String) async -> TailnetIdentity.Caller?

    /// What subscribers see, read on the main queue.
    public struct Workspace: Sendable {
        public var snapshot: @MainActor @Sendable () -> RemoteWorkspace
        public var blocks: @MainActor @Sendable (BlocksParams) -> Result<BlocksResult, RemoteError>
        /// Presses the key in a pane that waits for permission, or says why not.
        public var answer: @MainActor @Sendable (AnswerParams) -> Result<AnswerResult, RemoteError>
        /// The terminal config a client draws mirrored panes with.
        public var appearance: @MainActor @Sendable () -> RemoteAppearance

        public init(snapshot: @escaping @MainActor @Sendable () -> RemoteWorkspace,
                    blocks: @escaping @MainActor @Sendable (BlocksParams) -> Result<BlocksResult, RemoteError>,
                    answer: @escaping @MainActor @Sendable (AnswerParams) -> Result<AnswerResult, RemoteError>,
                    appearance: @escaping @MainActor @Sendable () -> RemoteAppearance = { RemoteAppearance(config: "") }) {
            self.snapshot = snapshot
            self.blocks = blocks
            self.answer = answer
            self.appearance = appearance
        }
    }

    public static let defaultPort: UInt16 = 7445
    /// Connections at once.
    static let maxConnections = 64
    /// A request is a command and a few words; a capture answer can be the whole scrollback.
    static let maxMessage = 1 << 20
    /// The time a caller has to say hello.
    static let helloTimeout: TimeInterval = 10

    public let host: String
    public let port: UInt16
    private let owner: Int64
    private let server: String
    private let mac: String
    private let identify: Identify
    private let handler: Handler
    private let workspace: Workspace?
    /// The panes mirrored to clients (`attach`, `input`, …); nil answers those as unknown methods.
    let mirror: MirrorHub?
    private let onClients: @Sendable ([Client]) -> Void
    private let onFailure: @Sendable (String) -> Void

    /// Everything below is touched only on this queue.
    let queue = DispatchQueue(label: "dev.promptty.remote", qos: .userInitiated)
    private var listener: NWListener?
    var connections: [UUID: Connection] = [:]

    final class Connection {
        let connection: NWConnection
        var session: RemoteSession?
        var client: Client
        /// Subscribed: the snapshot it last got, so only a change is sent.
        var lastWorkspace: RemoteWorkspace?
        /// Mirrored output handed to the network and not yet sent (`RemoteServer+Mirror`).
        var outputQueued = 0
        /// Panes whose output it fell behind on: none sent until it attaches again.
        var behind: Set<String> = []
        init(connection: NWConnection, client: Client) { self.connection = connection; self.client = client }
    }

    /// `onClients` is called on the main queue whenever a client comes, introduces itself or goes.
    public init(host: String, port: UInt16 = RemoteServer.defaultPort, owner: Int64, server: String, mac: String,
                identify: @escaping Identify, handler: @escaping Handler, workspace: Workspace? = nil, mirror: MirrorHub? = nil,
                onClients: @escaping @Sendable ([Client]) -> Void,
                onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.host = host
        self.port = port
        self.owner = owner
        self.server = server
        self.mac = mac
        self.identify = identify
        self.handler = handler
        self.workspace = workspace
        self.mirror = mirror
        self.onClients = onClients
        self.onFailure = onFailure
        mirror?.outbox.connect { [weak self] client, event in self?.sendMirrorEvent(event, to: client) }
    }

    public enum Failure: Error, Equatable {
        case badAddress
    }

    /// Listens on `host` alone: on the Tailscale address, nothing outside the tailnet can reach it.
    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw Failure.badAddress }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = Self.maxMessage
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // The address taken, or gone (Tailscale down): told on the main queue.
        let onFailure = onFailure
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { DispatchQueue.main.async { onFailure("\(error)") } }
        }
        listener.start(queue: queue)
        queue.sync { self.listener = listener }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.connection.cancel() }
            connections.removeAll()
            publishClients()
        }
        if let mirror { DispatchQueue.main.async { MainActor.assumeIsolated { mirror.reset() } } }
    }

    /// Sends subscribers the workspace if it changed since they last got it.
    public func publish(_ snapshot: RemoteWorkspace) {
        queue.async { [weak self] in
            guard let self, let event = try? RemoteNotification(method: RemoteProtocol.Event.workspace, params: snapshot) else { return }
            for (id, entry) in self.connections where entry.lastWorkspace != nil && entry.lastWorkspace != snapshot {
                entry.lastWorkspace = snapshot
                self.send(.notification(event), on: id)
            }
        }
    }

    /// Tells subscribers a command ended.
    public func publish(_ finished: CommandFinished) {
        queue.async { [weak self] in
            guard let self, let event = try? RemoteNotification(method: RemoteProtocol.Event.commandFinished, params: finished) else { return }
            for (id, entry) in self.connections where entry.lastWorkspace != nil {
                self.send(.notification(event), on: id)
            }
        }
    }

    /// Hangs up on a client (Settings' Disconnect).
    public func disconnect(_ id: UUID) {
        queue.async { [weak self] in self?.close(id) }
    }

    // MARK: On the queue

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else { return connection.cancel() }
        let id = UUID()
        let address = Self.address(of: connection.endpoint)
        connections[id] = Connection(connection: connection, client: Client(id: id, user: "", address: address, since: Date()))
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
            guard let self, let entry = self.connections[id], entry.session?.state ?? .awaitingHello == .awaitingHello else { return }
            self.close(id)
        }
        let identify = identify
        Task { [weak self] in
            let caller = await identify(address)
            guard let self else { return }
            self.queue.async { self.admit(id, caller: caller) }
        }
    }

    /// Lets the caller in, or tells it why not and hangs up. Nothing it sends is read before.
    private func admit(_ id: UUID, caller: TailnetIdentity.Caller?) {
        guard let entry = connections[id] else { return }
        switch TailnetIdentity.decide(caller, owner: owner) {
        case .refused(let reason):
            let refusal = RemoteMessage.response(.error(RemoteError(code: RemoteError.notAllowed, message: reason), id: nil))
            send(refusal, on: id) { [weak self] in self?.close(id) }
        case .allowed(let login):
            entry.session = RemoteSession(server: server, mac: mac, user: login)
            entry.client.user = login
            publishClients()
            receive(on: id)
        }
    }

    private func receive(on id: UUID) {
        guard let entry = connections[id] else { return }
        entry.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { return self.close(id) }
            if let data, !data.isEmpty { self.handle(data, on: id) }
            self.receive(on: id)
        }
    }

    private func handle(_ data: Data, on id: UUID) {
        guard let entry = connections[id], var session = entry.session else { return }
        let actions = session.receive(data)
        entry.session = session
        if case .introduced(let client) = session.state, entry.client.name != client {
            entry.client.name = client
            publishClients()
        }
        for action in actions {
            switch action {
            case .send(let message):
                send(message, on: id)
            case .close:
                // The final message: the connection ends after what was sent before it.
                entry.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.close(id) }
                })
            case .subscribe(let replyID):
                answerOnMain(replyID, on: id) { workspace in
                    .success(workspace.snapshot())
                } then: { [weak self] snapshot in
                    self?.connections[id]?.lastWorkspace = snapshot
                }
            case .unsubscribe(let replyID):
                entry.lastWorkspace = nil
                send(.response(RemoteResponse(id: replyID, outcome: .result(.object([:])))), on: id)
            case .blocks(let params, let replyID):
                answerOnMain(replyID, on: id) { workspace in workspace.blocks(params) }
            case .answer(let params, let replyID):
                answerOnMain(replyID, on: id) { workspace in workspace.answer(params) }
            case .appearance(let replyID):
                answerOnMain(replyID, on: id) { workspace in .success(workspace.appearance()) }
            case .mirror(let call, let replyID):
                handleMirror(call, replyID: replyID, on: id)
            case .control(let request, let replyID):
                // Held until the command answers (`wait` can take minutes).
                let handler = handler, server = self
                DispatchQueue.main.async {
                    handler(request) { response in
                        server.queue.async {
                            guard case .send(let message) = RemoteSession.reply(response, to: replyID) else { return }
                            server.send(message, on: id)
                        }
                    }
                }
            }
        }
    }

    /// Answers a request from the workspace, read on the main queue; `then` runs on the queue
    /// before the answer is sent.
    private func answerOnMain<R: Encodable & Sendable>(_ replyID: RemoteID, on id: UUID,
                                                       _ read: @escaping @MainActor @Sendable (Workspace) -> Result<R, RemoteError>,
                                                       then: (@Sendable (R) -> Void)? = nil) {
        guard let workspace else {
            return send(.response(.error(RemoteError(code: RemoteError.methodNotFound, message: "no workspace here"), id: replyID)), on: id)
        }
        let server = self
        DispatchQueue.main.async {
            let result = read(workspace)
            server.queue.async {
                switch result {
                case .success(let value):
                    then?(value)
                    guard case .send(let message) = RemoteSession.reply(value, to: replyID) else { return }
                    server.send(message, on: id)
                case .failure(let error):
                    guard case .send(let message) = RemoteSession.reply(error, to: replyID) else { return }
                    server.send(message, on: id)
                }
            }
        }
    }

    /// Sends a message as one text frame.
    func send(_ message: RemoteMessage, on id: UUID, then: (@Sendable () -> Void)? = nil) {
        guard let entry = connections[id], let data = try? message.encoded() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        entry.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let then else { return }
            self?.queue.async { then() }
        })
    }

    private func close(_ id: UUID) {
        guard let entry = connections.removeValue(forKey: id) else { return }
        entry.connection.cancel()
        publishClients()
        mirrorClientGone(id)
    }

    /// On the queue.
    private func publishClients() {
        let clients = queueClients()
        let onClients = onClients
        DispatchQueue.main.async { onClients(clients) }
    }

    /// The clients let in, oldest first.
    private func queueClients() -> [Client] {
        connections.values.filter { $0.session != nil }.map(\.client).sorted { $0.since < $1.since }
    }

    static func address(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }
}
