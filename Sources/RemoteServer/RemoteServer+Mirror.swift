import Foundation
import Network
import RemoteProtocol

/// Mirroring panes (`MirrorHub`): requests answered on the main queue, where the panes are, and
/// their output sent as it comes, as long as the client keeps up.
extension RemoteServer {
    /// Mirrored output a client may have waiting to go out before it is taken to have fallen
    /// behind: it is detached from the pane and attaches again for a fresh snapshot.
    static let maxOutputQueued = 8 << 20

    /// On the queue.
    func handleMirror(_ call: MirrorCall, replyID: RemoteID, on id: UUID) {
        guard let mirror, let entry = connections[id], case .introduced(let name) = entry.session?.state else {
            return send(.response(.error(RemoteError(code: RemoteError.methodNotFound, message: "no mirroring here"), id: replyID)), on: id)
        }
        let client = MirrorClient(id: id, name: name)
        if case .attach = call { entry.behind.remove(call.pane) }
        let server = self
        DispatchQueue.main.async {
            let reply = MainActor.assumeIsolated { mirror.handle(call, from: client) }
            server.queue.async {
                switch reply.result {
                case .success(let value):
                    server.send(.response(RemoteResponse(id: replyID, outcome: .result(value))), on: id)
                case .failure(let error):
                    server.send(.response(.error(error, id: replyID)), on: id)
                }
                // Sent after the answer, before any output that follows.
                guard let activate = reply.activate else { return }
                guard let backlog = activate() else {
                    return server.fellBehind(id, pane: call.pane)
                }
                for event in backlog { server.sendMirrorEventOnQueue(event, to: id) }
            }
        }
    }

    /// An event for a client from the hub or a pane's feed, from any thread.
    func sendMirrorEvent(_ event: RemoteNotification, to client: UUID) {
        queue.async { [weak self] in self?.sendMirrorEventOnQueue(event, to: client) }
    }

    /// On the queue: output counts against what the client may have waiting.
    private func sendMirrorEventOnQueue(_ event: RemoteNotification, to client: UUID) {
        guard let entry = connections[client] else { return }
        guard event.method == RemoteProtocol.Event.output else { return send(.notification(event), on: client) }
        guard let pane = event.params?.objectValue?["pane"]?.stringValue, !entry.behind.contains(pane),
              let data = try? RemoteMessage.notification(event).encoded() else { return }
        if entry.outputQueued + data.count > Self.maxOutputQueued {
            return fellBehind(client, pane: pane)
        }
        entry.outputQueued += data.count
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "output", metadata: [metadata])
        let size = data.count
        entry.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.connections[client]?.outputQueued -= size }
        })
    }

    /// On the queue: no more of the pane's output for the client until it attaches again.
    private func fellBehind(_ client: UUID, pane: String) {
        guard let entry = connections[client], let mirror else { return }
        entry.behind.insert(pane)
        DispatchQueue.main.async { MainActor.assumeIsolated { mirror.clientBehind(client, pane: pane) } }
    }

    /// On the queue: a client went; the hub lets go of what it had.
    func mirrorClientGone(_ client: UUID) {
        guard let mirror else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { mirror.clientGone(client) } }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
