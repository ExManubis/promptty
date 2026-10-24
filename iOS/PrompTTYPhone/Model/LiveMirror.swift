import Foundation
import GhosttyMirror
import os
import RemoteClient
import RemoteProtocol
import UIKit

/// A pane on the Mac, live on the phone: attached over the remote API (`attach`), its snapshot and
/// then every byte its programs write fed to a terminal of its own (`MirrorSurfaceView`) at the
/// Mac's grid, so it shows what the Mac's does; scrolling it moves nothing on the Mac. What is typed
/// goes to the pane as keys (`input`). "Take control" sizes the pane to the phone until it lets go.
@MainActor
@Observable
final class LiveMirror {
    let pane: UUID
    /// The terminal, once the Mac's config has come.
    private(set) var view: MirrorSurfaceView?
    /// The pane's grid, controller and whether this phone may type.
    private(set) var state: MirrorState?
    /// Why it shows nothing ("The pane closed").
    private(set) var failure: String?
    /// The terminal's size for the pane's grid, once its cells are known: its frame.
    private(set) var fit: CGSize?
    /// The room the pane card has for the terminal: the grid taken with control.
    var available: CGSize = .zero {
        didSet {
            takePendingControl()
            if state?.inControl == true, available != oldValue { resizeControlled() }
        }
    }

    /// Once, after the first attach: a tab the phone opened takes control and runs its command.
    var onFirstAttach: (() -> Void)?

    private weak var connection: MacConnection?
    private var position: MirrorPosition?
    /// Output that came before the terminal had the pane's grid: fed once it has.
    private var pending: [Data] = []
    private var gridMatches = false
    private var attaching = false
    /// Output handled before the attach's answer (they arrive in that order, but each is its own
    /// task on the main actor): played once the answer says where the output starts.
    private var early: [MirrorOutput] = []
    private static let log = Logger(subsystem: "dev.promptty.PrompTTY2.phone", category: "mirror")

    /// The phone's terminal font, smaller than the Mac's: a pane's grid fits more of the screen.
    static let fontSize: Float = 11
    /// Padding around the cells, in points: the config's (`phoneConfig`).
    static let padding: CGFloat = 4

    init(pane: UUID, connection: MacConnection) {
        self.pane = pane
        self.connection = connection
    }

    /// The Mac's terminal config, made for the phone: an opaque background, a little padding.
    static func phoneConfig(_ macConfig: String) -> String {
        macConfig + "\nbackground-opacity = 1\nwindow-padding-x = 4\nwindow-padding-y = 4\nwindow-padding-balance = false\n"
    }

    func start(config: String) {
        guard view == nil else { return }
        do {
            let view = MirrorSurfaceView(engine: try MirrorEngines.engine(config: Self.phoneConfig(config)), fontSize: Self.fontSize)
            view.accessibilityIdentifier = "live.terminal"
            view.onResize = { [weak self] columns, rows in self?.resized(columns: columns, rows: rows) }
            view.onInput = { [weak self] input in self?.connection?.typed(input, in: self) }
            // Its replies to the program's queries: the Mac's own terminal has made them.
            view.onWrite = { _ in }
            self.view = view
            attach()
        } catch {
            failure = "Can't draw a terminal here: \(error)"
        }
    }

    /// Attaches, or again after a reconnect: from where it got to, or (`fresh`) from a snapshot.
    func attach(fresh: Bool = false) {
        guard let client = connection?.client, !attaching else { return }
        if fresh { position = nil }
        attaching = true
        early = []
        let params = AttachParams(pane: pane.uuidString, resume: position, scrollback: 2000)
        Task {
            do {
                let attached = try await client.call(RemoteProtocol.Method.attach, params, as: Attached.self)
                attaching = false
                failure = nil
                position = attached.position
                if let snapshot = attached.snapshot {
                    pending = [snapshot]
                    gridMatches = false
                }
                apply(attached.state)
                // At the grid it has already (attached again): the snapshot plays now.
                fitToGrid()
                let waiting = early
                early = []
                for output in waiting { received(output) }
                if let first = onFirstAttach {
                    onFirstAttach = nil
                    pendingControl = first
                    takePendingControl()
                }
            } catch {
                attaching = false
                early = []
                failure = MacConnection.describe(error)
            }
        }
    }

    func detach() {
        guard let client = connection?.client else { return }
        let params = PaneParams(pane: pane.uuidString)
        Task { _ = try? await client.call(RemoteProtocol.Method.detach, params, as: JSONValue.self) }
    }

    // MARK: From the Mac

    func received(_ output: MirrorOutput) {
        if attaching { return early.append(output) }
        guard let position, output.stream == position.stream else { return attach(fresh: true) }
        if output.seq > position.seq { return attach(fresh: true) }
        // Bytes it has already (a resume overlapping): only the new ones.
        let skip = position.seq - output.seq
        guard skip < output.data.count else { return }
        let data = skip > 0 ? output.data.dropFirst(skip) : output.data
        self.position?.seq += data.count
        feed(Data(data))
    }

    func apply(_ state: MirrorState) {
        let gridChanged = self.state.map { $0.cols != state.cols || $0.rows != state.rows } ?? true
        self.state = state
        if gridChanged {
            gridMatches = false
            fitToGrid()
        }
    }

    func detached(_ reason: Detached.Reason) {
        switch reason {
        case .behind: attach(fresh: true)
        case .closed: failure = "The pane closed."
        case .stopped: failure = "The Mac stopped remote access."
        }
    }

    // MARK: Control

    func takeControl() {
        guard let grid = phoneGrid(), let client = connection?.client else { return }
        let params = ControlTake(pane: pane.uuidString, cols: grid.cols, rows: grid.rows)
        Task {
            if let state = try? await client.call(RemoteProtocol.Method.takeControl, params, as: MirrorState.self) { apply(state) }
        }
    }

    func releaseControl() {
        guard let client = connection?.client else { return }
        let params = PaneParams(pane: pane.uuidString)
        Task {
            if let state = try? await client.call(RemoteProtocol.Method.releaseControl, params, as: MirrorState.self) { apply(state) }
        }
    }

    private func resizeControlled() {
        guard let grid = phoneGrid(), let state, grid.cols != state.cols || grid.rows != state.rows,
              let client = connection?.client else { return }
        let params = ControlTake(pane: pane.uuidString, cols: grid.cols, rows: grid.rows)
        Task {
            if let state = try? await client.call(RemoteProtocol.Method.resize, params, as: MirrorState.self) { apply(state) }
        }
    }

    /// Control wanted before the terminal knew its cells: taken once it does.
    private var pendingControl: (() -> Void)?

    private func takePendingControl() {
        guard pendingControl != nil, phoneGrid() != nil else { return }
        let action = pendingControl
        pendingControl = nil
        action?()
    }

    /// The grid that fits the pane card at the phone's font.
    private func phoneGrid() -> (cols: Int, rows: Int)? {
        guard let cell = view?.cellSize, cell.width > 0, cell.height > 0, available.width > 0 else { return nil }
        let cols = Int((available.width - 2 * Self.padding) / cell.width - 0.5)
        let rows = Int((available.height - 2 * Self.padding) / cell.height - 0.5)
        return (max(20, min(cols, 500)), max(5, min(rows, 300)))
    }

    // MARK: The terminal

    /// The frame that makes the terminal's grid the pane's: the padding, the cells and half a cell
    /// spare (the grid is what fits whole).
    private func fitToGrid() {
        guard let state, let cell = view?.cellSize, cell.width > 0 else { return }
        fit = CGSize(width: 2 * Self.padding + (CGFloat(state.cols) + 0.5) * cell.width,
                     height: 2 * Self.padding + (CGFloat(state.rows) + 0.5) * cell.height)
        if let grid = view?.gridSize, grid.columns == state.cols, grid.rows == state.rows { gridReady() }
    }

    private func resized(columns: Int, rows: Int) {
        takePendingControl()
        guard let state else { return }
        if columns == state.cols, rows == state.rows { gridReady() } else if fit == nil || !gridMatches { fitToGrid() }
    }

    private func gridReady() {
        guard !gridMatches else { return }
        gridMatches = true
        let queued = pending
        pending = []
        for data in queued { view?.feed(data) }
    }

    private func feed(_ data: Data) {
        if gridMatches { view?.feed(data) } else { pending.append(data) }
    }
}

/// The phone's libghostty app, one per config: a Mac with other fonts or colors gets its own.
@MainActor
enum MirrorEngines {
    private static var engines: [String: MirrorEngine] = [:]

    static func engine(config: String) throws -> MirrorEngine {
        if let engine = engines[config] { return engine }
        let engine = try MirrorEngine(configText: config)
        engines[config] = engine
        return engine
    }
}
