import Foundation
import RemoteProtocol
import Synchronization

/// A chunk of a pane's output, numbered (`TerminalOutput.Chunk` in the app).
public struct MirrorChunk: Sendable, Equatable {
    public var stream: String
    /// The position of the first byte in the stream.
    public var offset: Int
    public var data: Data

    public init(stream: String, offset: Int, data: Data) {
        self.stream = stream
        self.offset = offset
        self.data = data
    }

    public var end: Int { offset + data.count }
}

/// One pane's output on its way to the clients attached to it: the newest bytes kept, so a client
/// that attaches gets what came after its snapshot and one that reconnects what it missed, and each
/// live client sent every chunk from where it got to. Chunks arrive off the main thread, in order;
/// clients go live on the server's queue (`activate`), after their `attach` was answered.
final class MirrorFeed: Sendable {
    /// The bytes kept: a client further behind than this takes a fresh snapshot.
    static let capacity = 2 << 20
    /// The most one `output` event carries.
    static let eventSize = 64 << 10

    let pane: String
    private let send: @Sendable (UUID, RemoteNotification) -> Void
    private let state = Mutex(State())

    private struct State {
        var stream: String?
        /// The newest bytes, `start` the position of the first.
        var buffer = Data()
        var start = 0
        /// Each live client and the position it got to.
        var live: [UUID: Int] = [:]

        var end: Int { start + buffer.count }
    }

    /// `send` hands an event to a client (on any thread; the server queues it).
    init(pane: String, send: @escaping @Sendable (UUID, RemoteNotification) -> Void) {
        self.pane = pane
        self.send = send
    }

    /// The stream kept and the positions from which a client can resume.
    var kept: (stream: String?, range: ClosedRange<Int>) {
        state.withLock { ($0.stream, $0.start...$0.end) }
    }

    /// Whether a client at `position` can go on from there.
    func canResume(from position: MirrorPosition) -> Bool {
        let kept = kept
        return kept.stream == position.stream && kept.range.contains(position.seq)
    }

    /// A chunk read from the pane: kept, and sent to every live client.
    func receive(_ chunk: MirrorChunk) {
        let sends: [(UUID, MirrorOutput)] = state.withLock { state in
            if state.stream != chunk.stream {
                // A new stream (the output lost its subscribers in between): nobody can go on.
                state.stream = chunk.stream
                state.buffer = Data()
                state.start = chunk.offset
            }
            if chunk.offset > state.end {
                // Bytes missing (none should be): start over at this chunk.
                state.buffer = Data()
                state.start = chunk.offset
            }
            if chunk.end > state.end {
                state.buffer.append(chunk.data.suffix(chunk.end - state.end))
            }
            if state.buffer.count > Self.capacity {
                let drop = state.buffer.count - Self.capacity
                state.buffer = Data(state.buffer.dropFirst(drop))
                state.start += drop
            }
            var sends: [(UUID, MirrorOutput)] = []
            for (client, next) in state.live where next < state.end {
                sends += Self.events(pane: pane, stream: chunk.stream, buffer: state.buffer, start: state.start, from: next).map { (client, $0) }
                state.live[client] = state.end
            }
            return sends
        }
        for (client, output) in sends { emit(output, to: client) }
    }

    /// The client goes live from `seq` on (its snapshot's position, or where it resumes): the
    /// events for the bytes kept from there, to send before any other. Nil when those bytes are
    /// gone (the stream changed, or fell out of the buffer): it has to attach again.
    func activate(_ client: UUID, stream: String, from seq: Int) -> [RemoteNotification]? {
        let events: [MirrorOutput]? = state.withLock { state in
            guard state.stream == nil || state.stream == stream, seq >= state.start else { return nil }
            if state.stream == nil {
                // Nothing read yet: the stream starts at the snapshot.
                state.stream = stream
                state.start = seq
            }
            state.live[client] = max(seq, state.end)
            guard seq < state.end else { return [] }
            return Self.events(pane: pane, stream: stream, buffer: state.buffer, start: state.start, from: seq)
        }
        return events?.compactMap { try? RemoteNotification(method: RemoteProtocol.Event.output, params: $0) }
    }

    func deactivate(_ client: UUID) {
        _ = state.withLock { $0.live.removeValue(forKey: client) }
    }

    var hasLiveClients: Bool { state.withLock { !$0.live.isEmpty } }

    private func emit(_ output: MirrorOutput, to client: UUID) {
        guard let event = try? RemoteNotification(method: RemoteProtocol.Event.output, params: output) else { return }
        send(client, event)
    }

    /// The bytes from `from` to the end of the buffer, in events of at most `eventSize`.
    private static func events(pane: String, stream: String, buffer: Data, start: Int, from: Int) -> [MirrorOutput] {
        var events: [MirrorOutput] = []
        var position = max(from, start)
        let end = start + buffer.count
        while position < end {
            let length = min(eventSize, end - position)
            let lower = buffer.startIndex + (position - start)
            events.append(MirrorOutput(pane: pane, stream: stream, seq: position, data: Data(buffer[lower..<lower + length])))
            position += length
        }
        return events
    }
}
