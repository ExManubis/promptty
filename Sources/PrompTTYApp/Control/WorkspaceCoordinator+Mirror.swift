import Foundation
import GhosttyBridge
import RemoteControl
import RemoteProtocol
import RemoteServer
import WorkspaceModel

/// Who mirrors a pane over Remote access, for its badge.
struct PaneRemote: Equatable {
    /// The devices' names, as they introduced themselves.
    var viewers: [String]
    /// The one that has control of the pane's size.
    var controller: String?

    var text: String {
        if let controller { return "\(controller) has control" }
        return viewers.count == 1 ? "On \(viewers[0])" : "On \(viewers.count) devices"
    }

    var help: String {
        if let controller { return "\(controller) has control: the pane has its size until it lets go or disconnects." }
        return "Shown on \(viewers.joined(separator: ", ")) over Remote access."
    }
}

/// Mirroring panes to remote clients (`MirrorHub`): the pane's terminal behind each, found as
/// `promptty` finds one, the badges on the panes they mirror, and typing as Settings allows.
extension WorkspaceCoordinator {
    func configureRemoteMirror(typing: Bool) {
        if let hub = RemoteAccess.shared.mirror {
            hub.typing = typing
            return
        }
        let mirrors = SurfaceMirrors()
        let hub = MirrorHub(typing: typing) { [weak self] name in
            guard let self else { return .failure(RemoteError(code: RemoteError.internalError, message: "PrompTTY is quitting")) }
            return self.mirrorPane(named: name, in: mirrors)
        }
        hub.onAttachmentsChange = { [weak self, weak hub] in
            guard let self, let hub else { return }
            self.showRemoteAttachments(hub.attachments)
            PasswordWatch.update(hub)
        }
        RemoteAccess.shared.mirror = hub
    }

    /// Password prompts came or went: the panes mirrored are looked at again.
    func remoteSecureInputChanged() {
        guard let hub = RemoteAccess.shared.mirror else { return }
        for pane in hub.attachments.keys { hub.paneChanged(pane) }
    }

    private func mirrorPane(named name: String, in mirrors: SurfaceMirrors) -> Result<(id: String, pane: MirrorPane), RemoteError> {
        switch resolvePane(ControlRequest(command: RemoteProtocol.Method.attach, target: name)) {
        case .failure(let response):
            return .failure(RemoteError(code: RemoteError.invalidParams, message: response.text))
        case .success(let pane):
            guard let (window, _) = workspace.tab(containing: pane),
                  let view = controller(for: window.id)?.existingSurface(for: pane), !view.isTornDown else {
                return .failure(RemoteError(code: RemoteError.invalidParams, message: "the pane's terminal has not started yet: show its tab on the Mac"))
            }
            let id = pane.rawValue.uuidString
            if let mirror = mirrors.byPane[id], mirror.view === view { return .success((id, mirror)) }
            let mirror = SurfaceMirror(view: view, pane: pane, secureInput: { [weak self] in self?.secureInput.isRequested(pane) ?? false })
            mirrors.byPane[id] = mirror
            return .success((id, mirror))
        }
    }

    private func showRemoteAttachments(_ attachments: [String: (viewers: [String], controller: String?)]) {
        for pane in workspace.windows.flatMap(\.paneIDs) {
            let attached = attachments[pane.rawValue.uuidString]
            activity.status(for: pane).setRemote(attached.map { PaneRemote(viewers: $0.viewers, controller: $0.controller) })
        }
    }
}

/// While panes are mirrored, their password prompts are looked for four times a second: libghostty
/// looks only in the focused pane, and the one on the phone seldom is.
@MainActor
private enum PasswordWatch {
    static var task: Task<Void, Never>?

    static func update(_ hub: MirrorHub) {
        if hub.attachments.isEmpty {
            task?.cancel()
            task = nil
        } else if task == nil {
            task = Task { [weak hub] in
                while !Task.isCancelled, let hub {
                    for pane in hub.attachments.keys { hub.paneChanged(pane) }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }
}

/// The pane mirrors made, one per terminal.
@MainActor
private final class SurfaceMirrors {
    var byPane: [String: SurfaceMirror] = [:]
}

/// A pane's terminal as the mirror sees it.
@MainActor
private final class SurfaceMirror: MirrorPane {
    weak var view: TerminalSurfaceView?
    let pane: PaneID
    let secureInput: () -> Bool

    init(view: TerminalSurfaceView, pane: PaneID, secureInput: @escaping () -> Bool) {
        self.view = view
        self.pane = pane
        self.secureInput = secureInput
    }

    func subscribe(_ handler: @escaping @Sendable (MirrorChunk) -> Void) -> AnyObject {
        guard let view else { return NSObject() }
        return view.output.subscribeNumbered { chunk in
            handler(MirrorChunk(stream: chunk.stream.uuidString, offset: chunk.offset, data: chunk.data))
        }
    }

    func snapshot(scrollback: Int) -> MirrorSnapshot? {
        guard let snapshot = view?.vtSnapshot(scrollback: scrollback) else { return nil }
        return MirrorSnapshot(vt: snapshot.vt, cols: snapshot.grid.cols, rows: snapshot.grid.rows,
                              position: MirrorPosition(stream: snapshot.position.stream.uuidString, seq: snapshot.position.offset))
    }

    var grid: (cols: Int, rows: Int)? { view?.grid.map { ($0.cols, $0.rows) } }
    var seq: Int { view?.output.position.offset ?? 0 }
    var password: Bool { secureInput() || view?.readsPassword == true }

    func input(_ params: InputParams) -> Bool {
        guard let view else { return false }
        if let text = params.text { view.typeText(text) }
        if let paste = params.paste { view.pasteText(paste) }
        if let key = params.key {
            guard key.isValid else { return false }
            let mods = Set(key.mods)
            return view.pressKey(key.key, shift: mods.contains(.shift), control: mods.contains(.ctrl),
                                 option: mods.contains(.alt), command: mods.contains(.super))
        }
        return params.text != nil || params.paste != nil
    }

    func setControlledGrid(_ grid: (cols: Int, rows: Int)?) {
        view?.gridOverride = grid.map { TerminalGrid(cols: $0.cols, rows: $0.rows).clamped }
    }
}
