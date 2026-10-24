import CommandBlocks
import Foundation
import GhosttyBridge
import PaneActivity
import Preferences
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
            blocks: { [weak self] params in self?.remoteBlocks(params) ?? .failure(Self.quitting) },
            answer: { [weak self] params in self?.remoteAnswer(params) ?? .failure(Self.quitting) },
            appearance: { [weak self] in self?.remoteAppearance() ?? RemoteAppearance(config: "") },
            places: { [weak self] in self?.remotePlaces() ?? RemotePlaces(home: "", folders: [], hosts: [], commands: []) })
    }

    private static let quitting = RemoteError(code: RemoteError.internalError, message: "PrompTTY is quitting")

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
        // As the sidebar's row reads (`TabRow`): an agent's task alone, else a title and a folder.
        let agent = agents.list.summary(for: tab.id)
        let lead = agent.flatMap { tab.pane($0.entry.pane) } ?? tab.focusedPane
        let (title, folder) = agent != nil ? (tab.listTitle, nil)
            : PaneTitle.titleAndFolder(pane: lead, program: activity.activity(for: lead.id).program, customTitle: tab.customTitle)
        return RemoteTab(id: tab.id.rawValue.uuidString, title: title, folder: folder, project: window.project(of: tab)?.rawValue.uuidString,
                  pinned: tab.pin != nil, focusedPane: tab.focusedPaneID.rawValue.uuidString,
                  panes: tab.orderedPanes.map { remotePane($0, in: window) })
    }

    private func remotePane(_ pane: Pane, in window: WindowState) -> RemotePane {
        let status = activity.status(for: pane.id)
        let visible = status.activity
        let (state, exitCode) = Self.remoteState(visible.display)
        let agent = visible.program?.isAgent == true && [.working, .permission, .attention].contains(state)
            ? RemoteAgent(tool: visible.tool, since: visible.agentSince?.timeIntervalSince1970) : nil
        // What it asks, read off its screen, while it waits: the phone shows the choices as buttons.
        let prompt = state == .permission
            ? controller(for: window.id)?.existingSurface(for: pane.id)?.activeScreenText().flatMap(PromptReader.read).map(Self.remotePrompt) : nil
        return RemotePane(id: pane.id.rawValue.uuidString, label: pane.label, title: pane.title, folder: pane.workingDirectory,
                          program: visible.program?.id, state: state, exitCode: exitCode, agent: agent, prompt: prompt, unseen: status.unseenOutput,
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

    /// Presses a key in a pane whose agent waits for permission, as the user would at the Mac; a pane
    /// that waits for nothing is refused, so a late tap on the phone types nothing into it.
    func remoteAnswer(_ params: AnswerParams) -> Result<AnswerResult, RemoteError> {
        switch resolvePane(ControlRequest(command: "answer", target: params.pane)) {
        case .failure(let response):
            return .failure(RemoteError(code: RemoteError.invalidParams, message: response.text))
        case .success(let pane):
            guard let key = PromptKey(name: params.key) else {
                return .failure(RemoteError(code: RemoteError.invalidParams, message: "no key \(params.key)"))
            }
            guard activity.status(for: pane).activity.display == .permission else {
                return .failure(RemoteError(code: RemoteError.notWaiting, message: "nothing in that pane waits for an answer"))
            }
            guard let (window, _) = workspace.tab(containing: pane), let surface = controller(for: window.id)?.existingSurface(for: pane) else {
                return .failure(RemoteError(code: RemoteError.invalidParams, message: "no pane \(params.pane)"))
            }
            surface.answerPrompt(key)
            return .success(AnswerResult(pane: pane.rawValue.uuidString))
        }
    }

    /// The terminal config as the Mac writes it, for a phone: the dark theme's file written out in
    /// place of its name (the phone has none), and nothing about the Mac's windows.
    func remoteAppearance() -> RemoteAppearance {
        let settings = preferences.settings
        let themes = preferences.themes
        let name = settings.followSystemAppearance ? settings.darkTheme : settings.theme
        let resolved = themes.contains(name) ? name : ThemeCatalog.fallbackDark
        let themeText = (try? String(contentsOf: themes.directory.appendingPathComponent(resolved), encoding: .utf8)) ?? ""
        let config = TerminalConfigWriter.render(settings, knownThemes: nil).split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let key = line.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? ""
                if key == "theme" { return themeText }
                return key.hasPrefix("macos-") || key.hasPrefix("background-opacity") || key.hasPrefix("background-blur")
                    || key.hasPrefix("window-") ? nil : String(line)
            }
        return RemoteAppearance(config: config.joined(separator: "\n"))
    }

    /// Where the phone can open a tab: ⌘J's folders, the palette's ssh hosts, the saved commands.
    func remotePlaces() -> RemotePlaces {
        RemotePlaces(home: NSHomeDirectory(),
                     folders: FolderHistoryStore.shared.frecentFolders().prefix(20).map(\.directory),
                     hosts: SSHHosts.cached.isEmpty ? SSHHosts.read() : SSHHosts.cached,
                     commands: preferences.settings.savedCommands.map { RemotePlaces.Saved(name: $0.name, command: $0.command) })
    }

    static func remotePrompt(_ prompt: PermissionPrompt) -> RemotePrompt {
        RemotePrompt(title: prompt.title, detail: prompt.detail, question: prompt.question,
                     choices: prompt.choices.map { RemotePrompt.Choice(key: String($0.number), label: $0.label) })
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
