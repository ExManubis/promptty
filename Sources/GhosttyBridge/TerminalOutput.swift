import Foundation
import GhosttyKit
import Synchronization

/// A terminal's pty output, byte for byte as the program wrote it (escape sequences included),
/// handed to whoever subscribed: for mirroring a pane elsewhere. libghostty reports each chunk on
/// its read thread with the terminal locked, so a chunk is only copied there; subscribers get the
/// chunks gathered since the last delivery, in order, on a queue of their own, never the main one.
public final class TerminalOutput: Sendable {
    /// One subscriber's handle: output stops reaching it once cancelled (or released).
    public final class Subscription: Sendable {
        fileprivate let id: Int
        private weak let output: TerminalOutput?

        fileprivate init(id: Int, output: TerminalOutput) {
            self.id = id
            self.output = output
        }

        deinit { cancel() }

        /// Stops delivery: a delivery already running finishes, none starts after it.
        public func cancel() {
            output?.remove(id)
        }
    }

    private struct State {
        var subscribers: [Int: @Sendable (Data) -> Void] = [:]
        var lastID = 0
        /// Copied on the read thread, waiting for the next delivery.
        var pending = Data()
        var deliveryQueued = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "PrompTTY.terminal-output", qos: .userInitiated)
    /// Told (on any thread) when the first subscriber arrives or the last one leaves, so the
    /// surface turns libghostty's tap on or off.
    private let subscribersChanged: @Sendable (_ any: Bool) -> Void

    init(subscribersChanged: @escaping @Sendable (_ any: Bool) -> Void = { _ in }) {
        self.subscribersChanged = subscribersChanged
    }

    /// Whether anyone is subscribed.
    public var hasSubscribers: Bool { state.withLock { !$0.subscribers.isEmpty } }

    /// Calls `handler` with the output from about now on, in order, on a private serial queue.
    /// It must not block: output gathers while it runs. Keep the subscription for as long as
    /// output should arrive.
    public func subscribe(_ handler: @escaping @Sendable (Data) -> Void) -> Subscription {
        let (id, first) = state.withLock { state in
            state.lastID += 1
            state.subscribers[state.lastID] = handler
            return (state.lastID, state.subscribers.count == 1)
        }
        if first { subscribersChanged(true) }
        return Subscription(id: id, output: self)
    }

    private func remove(_ id: Int) {
        let last = state.withLock { state in
            guard state.subscribers.removeValue(forKey: id) != nil else { return false }
            if state.subscribers.isEmpty { state.pending = Data() }
            return state.subscribers.isEmpty
        }
        if last { subscribersChanged(false) }
    }

    /// A chunk read from the pty. Called on libghostty's read thread with the terminal locked:
    /// copies and returns.
    func receive(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        let queueDelivery = state.withLock { state in
            guard !state.subscribers.isEmpty else { return false }
            state.pending.append(contentsOf: bytes)
            guard !state.deliveryQueued else { return false }
            state.deliveryQueued = true
            return true
        }
        if queueDelivery { queue.async { self.deliver() } }
    }

    private func deliver() {
        let (bytes, handlers) = state.withLock { state in
            let bytes = state.pending
            state.pending = Data()
            state.deliveryQueued = false
            return (bytes, state.subscribers.sorted { $0.key < $1.key }.map(\.value))
        }
        guard !bytes.isEmpty else { return }
        for handler in handlers { handler(bytes) }
    }

    /// libghostty's tap callback; its userdata is the unretained `TerminalOutput`, which the
    /// surface's view keeps for longer than the tap is set.
    static let tapCallback: ghostty_surface_output_tap_cb = { userdata, bytes, len in
        guard let userdata, let bytes else { return }
        Unmanaged<TerminalOutput>.fromOpaque(userdata).takeUnretainedValue()
            .receive(UnsafeRawBufferPointer(start: bytes, count: len))
    }
}

extension TerminalSurfaceView {
    /// Turns libghostty's tap on while the output has subscribers and the surface exists, off
    /// otherwise. Once it is off no callback runs, so the view may then go.
    func updateOutputTap() {
        let wanted = surface != nil && output.hasSubscribers
        guard let surface, wanted != outputTapSet else { return }
        if wanted {
            ghostty_surface_set_output_tap(surface, TerminalOutput.tapCallback, Unmanaged.passUnretained(output).toOpaque())
        } else {
            ghostty_surface_set_output_tap(surface, nil, nil)
        }
        outputTapSet = wanted
    }
}
