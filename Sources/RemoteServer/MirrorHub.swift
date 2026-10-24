import Foundation
import RemoteProtocol
import Synchronization

/// A pane as the mirror sees it: the app's terminal behind it.
@MainActor
public protocol MirrorPane: AnyObject {
    /// Numbered output from now on, in order, off the main thread, until the returned
    /// subscription is released.
    func subscribe(_ handler: @escaping @Sendable (MirrorChunk) -> Void) -> AnyObject
    /// The terminal as VT bytes, lined up with the output subscribed to before.
    func snapshot(scrollback: Int) -> MirrorSnapshot?
    /// The grid now, and the output position now (about).
    var grid: (cols: Int, rows: Int)? { get }
    var seq: Int { get }
    /// The program reads a password: the terminal does not echo.
    var password: Bool { get }
    /// Types, pastes or presses a key; false for a key it does not know.
    func input(_ params: InputParams) -> Bool
    /// The size a controlling client asks for, or nil for the Mac's own.
    func setControlledGrid(_ grid: (cols: Int, rows: Int)?)
}

public struct MirrorSnapshot: Sendable, Equatable {
    public var vt: Data
    public var cols: Int
    public var rows: Int
    public var position: MirrorPosition

    public init(vt: Data, cols: Int, rows: Int, position: MirrorPosition) {
        self.vt = vt
        self.cols = cols
        self.rows = rows
        self.position = position
    }
}

/// A connected client, as `hello` named it.
public struct MirrorClient: Sendable, Hashable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A mirror request from a client (`RemoteSession`'s `.mirror` action).
public enum MirrorCall: Equatable, Sendable {
    case attach(AttachParams)
    case detach(PaneParams)
    case input(InputParams)
    case takeControl(ControlTake)
    case resize(ControlTake)
    case releaseControl(PaneParams)

    /// The pane it names.
    public var pane: String {
        switch self {
        case .attach(let params): params.pane
        case .detach(let params), .releaseControl(let params): params.pane
        case .input(let params): params.pane
        case .takeControl(let params), .resize(let params): params.pane
        }
    }
}

/// What a mirror request is answered with; an attach also has the client go live once the answer
/// is sent (on the server's queue): the output it missed since its snapshot, then the rest.
public struct MirrorReply: Sendable {
    public var result: Result<JSONValue, RemoteError>
    public var activate: (@Sendable () -> [RemoteNotification]?)?
}

/// The panes mirrored to remote clients (PTY-75): each pane's output fanned out to the clients
/// attached to it, their input, and which of them has control of its size. Lives on the main
/// actor with the panes; output goes to the clients off it (`MirrorFeed`).
@MainActor
public final class MirrorHub {
    /// Finds a pane by id, id suffix or label: its id and the pane.
    public typealias Resolve = @MainActor (String) -> Result<(id: String, pane: MirrorPane), RemoteError>

    /// Where events go: set by the server it belongs to.
    public nonisolated let outbox = Outbox()

    /// Remote clients may type (Settings › Remote access); attached ones are told when it changes.
    public var typing: Bool {
        didSet { if typing != oldValue { for pane in panes.keys { publishState(pane) } } }
    }
    /// The panes attached to, their viewers and controller changed: for the Mac's badges.
    public var onAttachmentsChange: (() -> Void)?
    /// How long a pane's output is still kept after its last client went, for one that comes back.
    public var keepFor: Duration = .seconds(60)

    private let resolve: Resolve
    private var panes: [String: Mirrored] = [:]

    private final class Mirrored {
        weak var pane: MirrorPane?
        let feed: MirrorFeed
        var subscription: AnyObject?
        var clients: [UUID: MirrorClient] = [:]
        var controller: MirrorClient?
        /// What each client was last told (its seq left out).
        var told: [UUID: MirrorState] = [:]
        var expiry: Task<Void, Never>?

        init(pane: MirrorPane, feed: MirrorFeed) {
            self.pane = pane
            self.feed = feed
        }
    }

    /// Hands events to the server; any thread.
    public final class Outbox: Sendable {
        private let handler = Mutex<(@Sendable (UUID, RemoteNotification) -> Void)?>(nil)

        public func connect(_ send: @escaping @Sendable (UUID, RemoteNotification) -> Void) {
            handler.withLock { $0 = send }
        }

        func send(_ event: RemoteNotification, to client: UUID) {
            handler.withLock { $0 }?(client, event)
        }
    }

    public init(typing: Bool, resolve: @escaping Resolve) {
        self.typing = typing
        self.resolve = resolve
    }

    /// Who is attached to each pane, by pane id: the viewers' names and the controller's.
    public var attachments: [String: (viewers: [String], controller: String?)] {
        panes.filter { !$0.value.clients.isEmpty }.mapValues { mirrored in
            (mirrored.clients.values.map(\.name).sorted(), mirrored.controller?.name)
        }
    }

    public func handle(_ call: MirrorCall, from client: MirrorClient) -> MirrorReply {
        switch call {
        case .attach(let params):
            return attach(params, client: client)
        case .detach(let params):
            return reply {
                let (id, _) = try self.attached(params.pane, client)
                self.detach(client.id, from: id)
                return JSONValue.object([:])
            }
        case .input(let params):
            return reply {
                let (_, mirrored) = try self.attached(params.pane, client)
                guard self.typing else { throw RemoteError(code: RemoteError.typingOff, message: "typing from other devices is off on the Mac") }
                guard let pane = mirrored.pane, pane.input(params) else {
                    throw RemoteError(code: RemoteError.invalidParams, message: "input takes text, paste or a known key")
                }
                return JSONValue.object([:])
            }
        case .takeControl(let params):
            return reply {
                let (id, mirrored) = try self.attached(params.pane, client)
                let previous = mirrored.controller
                mirrored.controller = client
                mirrored.pane?.setControlledGrid((params.cols, params.rows))
                if previous?.id != client.id { self.onAttachmentsChange?() }
                let value = try self.stateValue(id, for: client.id)
                // The others (one of them may have had control) see who has it now.
                self.publishState(id)
                return value
            }
        case .resize(let params):
            return reply {
                let (id, mirrored) = try self.attached(params.pane, client)
                guard mirrored.controller?.id == client.id else {
                    throw RemoteError(code: RemoteError.notInControl, message: "take control of the pane to resize it")
                }
                mirrored.pane?.setControlledGrid((params.cols, params.rows))
                return try self.stateValue(id, for: client.id)
            }
        case .releaseControl(let params):
            return reply {
                let (id, mirrored) = try self.attached(params.pane, client)
                if mirrored.controller?.id == client.id { self.release(id) }
                return try self.stateValue(id, for: client.id)
            }
        }
    }

    /// A client disconnected: it leaves every pane, and gives back control it had.
    public func clientGone(_ client: UUID) {
        for (id, mirrored) in panes where mirrored.clients[client] != nil { detach(client, from: id) }
    }

    /// The server fell behind sending a pane's output to a client: it is detached and told.
    public func clientBehind(_ client: UUID, pane: String) {
        guard panes[pane]?.clients[client] != nil else { return }
        detach(client, from: pane)
        tell(client, Detached(pane: pane, reason: .behind))
    }

    /// The pane was clicked on the Mac: it gets the Mac's size back from the device that had
    /// control, which is told.
    public func takeBack(_ id: String) { release(id) }

    /// A pane's size or password prompt may have changed: its clients are told what did.
    public func paneChanged(_ id: String) { publishState(id) }

    /// A pane closed: its clients are told, its output let go.
    public func paneClosed(_ id: String) {
        guard let mirrored = panes.removeValue(forKey: id) else { return }
        mirrored.expiry?.cancel()
        for client in mirrored.clients.keys { tell(client, Detached(pane: id, reason: .closed)) }
        if !mirrored.clients.isEmpty { onAttachmentsChange?() }
    }

    /// Remote access stopped: every pane gets its own size back and its output is let go.
    public func reset() {
        for mirrored in panes.values {
            mirrored.expiry?.cancel()
            if mirrored.controller != nil { mirrored.pane?.setControlledGrid(nil) }
        }
        let had = panes.values.contains { !$0.clients.isEmpty }
        panes.removeAll()
        if had { onAttachmentsChange?() }
    }

    // MARK: Attaching

    private func attach(_ params: AttachParams, client: MirrorClient) -> MirrorReply {
        let id: String, pane: MirrorPane
        switch resolve(params.pane) {
        case .failure(let error): return MirrorReply(result: .failure(error))
        case .success(let found): (id, pane) = found
        }
        let mirrored = mirror(id, pane)
        mirrored.expiry?.cancel()
        mirrored.expiry = nil
        // Attached again (a reconnect the server had not noticed yet): starts over.
        mirrored.feed.deactivate(client.id)

        let position: MirrorPosition, snapshot: Data?
        let grid: (cols: Int, rows: Int)
        if let resume = params.resume, mirrored.feed.canResume(from: resume), let now = pane.grid {
            position = resume
            snapshot = nil
            grid = now
        } else {
            guard let taken = pane.snapshot(scrollback: min(max(params.scrollback ?? 1000, 0), 100_000)) else {
                return MirrorReply(result: .failure(RemoteError(code: RemoteError.internalError, message: "the pane has no terminal")))
            }
            position = taken.position
            snapshot = taken.vt
            grid = (taken.cols, taken.rows)
        }
        let wasNew = mirrored.clients[client.id] == nil
        mirrored.clients[client.id] = client
        let state = state(id, mirrored, for: client.id, grid: grid, seq: position.seq)
        mirrored.told[client.id] = state.withoutSeq
        if wasNew { onAttachmentsChange?() }
        let attached = Attached(pane: id, position: position, snapshot: snapshot, state: state)
        guard let value = try? JSONValue(encoding: attached) else {
            return MirrorReply(result: .failure(RemoteError(code: RemoteError.internalError, message: "could not encode the snapshot")))
        }
        let feed = mirrored.feed, clientID = client.id
        return MirrorReply(result: .success(value), activate: { feed.activate(clientID, stream: position.stream, from: position.seq) })
    }

    /// The pane's mirror, subscribed to its output.
    private func mirror(_ id: String, _ pane: MirrorPane) -> Mirrored {
        if let mirrored = panes[id], mirrored.pane === pane, mirrored.subscription != nil { return mirrored }
        let outbox = outbox
        let feed = MirrorFeed(pane: id) { client, event in outbox.send(event, to: client) }
        let mirrored = Mirrored(pane: pane, feed: feed)
        // Clients of a terminal the pane no longer has (it restarted) start over.
        if let old = panes[id] {
            for client in old.clients.keys { tell(client, Detached(pane: id, reason: .closed)) }
        }
        mirrored.subscription = pane.subscribe { feed.receive($0) }
        panes[id] = mirrored
        return mirrored
    }

    private func detach(_ client: UUID, from id: String) {
        guard let mirrored = panes[id], mirrored.clients.removeValue(forKey: client) != nil else { return }
        mirrored.feed.deactivate(client)
        mirrored.told[client] = nil
        if mirrored.controller?.id == client { release(id) }
        onAttachmentsChange?()
        guard mirrored.clients.isEmpty else { return }
        // Kept a while for a client that reconnects, then let go.
        let keepFor = keepFor
        mirrored.expiry = Task { [weak self, weak mirrored] in
            try? await Task.sleep(for: keepFor)
            guard !Task.isCancelled, let self, let mirrored, mirrored.clients.isEmpty, self.panes[id] === mirrored else { return }
            self.panes[id] = nil
        }
    }

    private func release(_ id: String) {
        guard let mirrored = panes[id], mirrored.controller != nil else { return }
        mirrored.controller = nil
        mirrored.pane?.setControlledGrid(nil)
        onAttachmentsChange?()
        publishState(id)
    }

    // MARK: State

    private func attached(_ pane: String, _ client: MirrorClient) throws -> (String, Mirrored) {
        // By the id `attach` answered with, or by whatever named the pane then.
        if let mirrored = panes[pane], mirrored.clients[client.id] != nil { return (pane, mirrored) }
        if case .success(let found) = resolve(pane), let mirrored = panes[found.id], mirrored.clients[client.id] != nil {
            return (found.id, mirrored)
        }
        throw RemoteError(code: RemoteError.notAttached, message: "attach to \(pane) first")
    }

    private func state(_ id: String, _ mirrored: Mirrored, for client: UUID, grid: (cols: Int, rows: Int)? = nil, seq: Int? = nil) -> MirrorState {
        let grid = grid ?? mirrored.pane?.grid ?? (0, 0)
        return MirrorState(pane: id, cols: grid.cols, rows: grid.rows, seq: seq ?? mirrored.pane?.seq ?? 0,
                           controller: mirrored.controller?.name, inControl: mirrored.controller?.id == client,
                           password: mirrored.pane?.password ?? false, typing: typing)
    }

    private func stateValue(_ id: String, for client: UUID) throws -> JSONValue {
        guard let mirrored = panes[id] else { throw RemoteError(code: RemoteError.notAttached, message: "attach to \(id) first") }
        let state = state(id, mirrored, for: client)
        mirrored.told[client] = state.withoutSeq
        return try JSONValue(encoding: state)
    }

    /// Tells each client of the pane its state, if it changed since it was last told.
    private func publishState(_ id: String) {
        guard let mirrored = panes[id] else { return }
        for client in mirrored.clients.keys {
            let state = state(id, mirrored, for: client)
            guard mirrored.told[client] != state.withoutSeq else { continue }
            mirrored.told[client] = state.withoutSeq
            tell(client, state, method: RemoteProtocol.Event.paneState)
        }
    }

    private func tell(_ client: UUID, _ detached: Detached) {
        tell(client, detached, method: RemoteProtocol.Event.detached)
    }

    private func tell<P: Encodable>(_ client: UUID, _ params: P, method: String) {
        guard let event = try? RemoteNotification(method: method, params: params) else { return }
        outbox.send(event, to: client)
    }

    private func reply(_ body: () throws -> JSONValue) -> MirrorReply {
        do {
            return MirrorReply(result: .success(try body()))
        } catch let error as RemoteError {
            return MirrorReply(result: .failure(error))
        } catch {
            return MirrorReply(result: .failure(RemoteError(code: RemoteError.internalError, message: "\(error)")))
        }
    }
}

extension MirrorState {
    /// For telling whether anything but the position changed.
    fileprivate var withoutSeq: MirrorState {
        var state = self
        state.seq = 0
        return state
    }
}
