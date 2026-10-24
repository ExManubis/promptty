import CommandBlocks
import Foundation
import PaneActivity
import RemoteControl
import RemoteProtocol
import RemoteServer
import WorkspaceModel

/// What the remote API's subscribers see (`RemoteServer.Workspace`): the windows, projects, tabs
/// and panes as the sidebar shows them, each pane's state and newest commands.
extension WorkspaceCoordinator {
    var remoteWorkspace: RemoteServer.Workspace {
        RemoteServer.Workspace(
            snapshot: { [weak self] in self?.remoteSnapshot() ?? RemoteWorkspace(windows: [], projects: []) },
            blocks: { [weak self] params in self?.remoteBlocks(params) ?? .failure(RemoteError(code: RemoteError.internalError, message: "PrompTTY is quitting")) })
    }

    func remoteSnapshot() -> RemoteWorkspace {
        let windows = workspace.windows.map { window in
            RemoteWindow(id: window.id.rawValue.uuidString, key: controller(for: window.id)?.window?.isKeyWindow == true,
                         selectedTab: window.selectedTabID?.rawValue.uuidString,
                         tabs: window.tabs.map { remoteTab($0, in: window) })
        }
        let projects = workspace.projects.map { RemoteProject(id: $0.id.rawValue.uuidString, name: $0.name, folded: $0.folded) }
        return RemoteWorkspace(windows: windows, projects: projects)
    }

    private func remoteTab(_ tab: WorkspaceModel.Tab, in window: WindowState) -> RemoteTab {
        RemoteTab(id: tab.id.rawValue.uuidString, title: tab.listTitle, project: window.project(of: tab)?.rawValue.uuidString,
                  pinned: tab.pin != nil, focusedPane: tab.focusedPaneID.rawValue.uuidString,
                  panes: tab.orderedPanes.map { remotePane($0, in: window) })
    }

    private func remotePane(_ pane: Pane, in window: WindowState) -> RemotePane {
        let status = activity.status(for: pane.id)
        let visible = status.activity
        let (state, exitCode) = Self.remoteState(visible.display)
        let agent = visible.program?.isAgent == true && [.working, .permission, .attention].contains(state)
            ? RemoteAgent(tool: visible.tool, since: visible.agentSince?.timeIntervalSince1970) : nil
        return RemotePane(id: pane.id.rawValue.uuidString, label: pane.label, title: pane.title, folder: pane.workingDirectory,
                          program: visible.program?.id, state: state, exitCode: exitCode, agent: agent, unseen: status.unseenOutput,
                          ports: status.ports, remote: status.remoteHost,
                          commands: recentCommands(pane.id, in: window, limit: 10))
    }

    func remoteBlocks(_ params: BlocksParams) -> Result<BlocksResult, RemoteError> {
        switch resolvePane(ControlRequest(command: "blocks", target: params.pane)) {
        case .failure(let response):
            return .failure(RemoteError(code: RemoteError.invalidParams, message: response.text))
        case .success(let pane):
            guard let (window, _) = workspace.tab(containing: pane) else { return .failure(RemoteError(code: RemoteError.invalidParams, message: "no pane \(params.pane)")) }
            let limit = max(1, min(params.limit ?? 20, 200))
            return .success(BlocksResult(pane: pane.rawValue.uuidString, commands: recentCommands(pane, in: window, limit: limit)))
        }
    }

    /// Tells subscribers a pane's command ended (its shell has just recorded it).
    func remoteCommandFinished(_ pane: PaneID) {
        guard let (window, tab) = workspace.tab(containing: pane),
              let record = controller(for: window.id)?.shell(for: pane)?.commands.records.last, !record.running else { return }
        RemoteAccess.shared.publish(CommandFinished(pane: pane.rawValue.uuidString, tab: tab.id.rawValue.uuidString, command: Self.remoteCommand(record)))
    }

    private func recentCommands(_ pane: PaneID, in window: WindowState, limit: Int) -> [RemoteCommand] {
        (controller(for: window.id)?.shell(for: pane)?.commands.records.suffix(limit) ?? []).map(Self.remoteCommand)
    }

    static func remoteCommand(_ record: CommandRecord) -> RemoteCommand {
        RemoteCommand(id: record.id, command: record.command, running: record.running, exitCode: record.exitCode,
                      started: record.started.timeIntervalSince1970, finished: record.finished?.timeIntervalSince1970)
    }

    static func remoteState(_ display: PaneActivity.Display) -> (RemotePaneState, Int?) {
        switch display {
        case .idle: (.idle, nil)
        case .running: (.running, nil)
        case .working: (.working, nil)
        case .finished: (.finished, nil)
        case .failed(let code): (.failed, code)
        case .attention: (.attention, nil)
        case .permission: (.permission, nil)
        }
    }
}
