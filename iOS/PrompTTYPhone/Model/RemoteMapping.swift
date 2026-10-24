import Foundation
import PaneActivity
import RemoteProtocol

/// A Mac's workspace (`RemoteWorkspace`) as the phone shows it: its projects and their tabs, the
/// tabs in no project last under no header, as the Mac's sidebar lists them.
enum RemoteMapping {
    /// The tabs in no project: an id that never changes, so their group keeps its place.
    static let ungrouped = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// `outputs` holds the commands' output read so far; `previous` keeps what the phone changed
    /// itself (a folded project, a command half typed).
    static func projects(_ workspace: RemoteWorkspace, outputs: [String: [TerminalLine]], previous: [PhoneProject]) -> [PhoneProject] {
        let tabs = workspace.windows.flatMap(\.tabs)
        let drafts = Dictionary(previous.flatMap(\.tabs).flatMap(\.panes).compactMap { pane in pane.shell.map { (pane.id, $0.draft) } },
                                uniquingKeysWith: { a, _ in a })
        let folded = Dictionary(previous.map { ($0.id, $0.folded) }, uniquingKeysWith: { a, _ in a })
        var projects = workspace.projects.map { project -> PhoneProject in
            let id = uuid(project.id)
            return PhoneProject(id: id, name: project.name, folded: folded[id] ?? project.folded,
                                tabs: tabs.filter { $0.project == project.id }.map { tab($0, outputs: outputs, drafts: drafts) })
        }
        let loose = tabs.filter { tab in tab.project == nil || !workspace.projects.contains { $0.id == tab.project } }
        if !loose.isEmpty {
            projects.append(PhoneProject(id: ungrouped, name: "", folded: false, tabs: loose.map { tab($0, outputs: outputs, drafts: drafts) }))
        }
        return projects.filter { !$0.tabs.isEmpty }
    }

    private static func tab(_ tab: RemoteTab, outputs: [String: [TerminalLine]], drafts: [UUID: String]) -> PhoneTab {
        let panes = tab.panes.map { pane($0, outputs: outputs, drafts: drafts, rowTitle: tab.title) }
        return PhoneTab(id: uuid(tab.id), title: tab.title, folder: tab.folder.map(abbreviate), panes: panes.isEmpty ? [placeholder] : panes,
                        focusedPane: uuid(tab.focusedPane), unseen: tab.panes.contains(where: \.unseen))
    }

    private static func pane(_ pane: RemotePane, outputs: [String: [TerminalLine]], drafts: [UUID: String], rowTitle: String) -> PhonePane {
        let id = uuid(pane.id)
        let program = pane.program.flatMap { programID in ProgramCatalog.all.first { $0.id == programID } }
        let folder = pane.remote ?? abbreviate(pane.folder)
        let atPrompt = program == nil || program?.isShell == true
        let last = pane.commands.last { !$0.running }
        let shell = atPrompt ? ShellState(folder: folder, branch: nil, dirty: false,
                                          lastExit: last.map { ($0.exitCode ?? 0, ($0.finished ?? $0.started) - $0.started) },
                                          draft: drafts[id] ?? "") : nil
        let permission = pane.state == .permission
            ? PermissionRequest(agent: program?.name ?? "The agent", tool: pane.agent?.tool ?? "", command: pane.agent?.tool ?? "a tool") : nil
        // A shell's terminal title is often its folder: the header says what the row says ("zsh").
        let ownTitle = pane.title.isEmpty || pane.title.hasPrefix("/") || pane.title.hasPrefix("~") ? rowTitle : pane.title
        return PhonePane(id: id, program: program, title: program?.isAgent == true ? pane.title : (program?.name ?? ownTitle), label: pane.label,
                         folder: folder, display: display(pane.state, exitCode: pane.exitCode), tool: pane.agent?.tool,
                         since: pane.agent?.since.map(Date.init(timeIntervalSince1970:)) ?? Date(),
                         screen: screen(pane.commands, outputs: outputs), shell: shell, permission: permission,
                         commandIDs: pane.commands.map(\.id))
    }

    /// The pane's newest commands as blocks: each command, then what it printed (once read).
    private static func screen(_ commands: [RemoteCommand], outputs: [String: [TerminalLine]]) -> [TerminalLine] {
        var lines: [TerminalLine] = []
        for command in commands.suffix(5) {
            if !lines.isEmpty { lines.append(TerminalLine("")) }
            let mark = command.running ? " {3:…}" : (command.exitCode ?? 0) == 0 ? "" : " {1:exit \(command.exitCode ?? 0)}"
            lines.append(TerminalLine("{2:\(escaped(command.command))}" + mark))
            lines.append(contentsOf: outputs[command.id] ?? [])
        }
        return lines.isEmpty ? [TerminalLine("{8:No commands yet. The live terminal comes later; the commands run here show.}")] : lines
    }

    static func display(_ state: RemotePaneState, exitCode: Int?) -> PaneActivity.Display {
        switch state {
        case .idle: .idle
        case .running: .running
        case .working: .working
        case .finished: .finished
        case .failed: .failed(exitCode ?? 1)
        case .attention: .attention
        case .permission: .permission
        }
    }

    /// A command's output as screen lines.
    static func lines(_ text: String) -> [TerminalLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).map { TerminalLine(escaped(String($0))) }
    }

    /// Text with no markup in it: braces would read as a color.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
    }

    /// "/Users/someone/Developer/x" as the Mac's sidebar writes it: "~/Developer/x".
    static func abbreviate(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[1] == "Users" else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }

    private static func uuid(_ text: String) -> UUID { UUID(uuidString: text) ?? UUID() }

    private static let placeholder = PhonePane(title: "", folder: "", screen: [])
}
