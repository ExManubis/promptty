import Foundation
import Observation
import PaneActivity
import Preferences

/// A Mac running PrompTTY, as the phone knows it.
struct PhoneMac: Identifiable, Equatable {
    let id = UUID()
    var name: String
    /// Its Tailscale name.
    var host: String
    /// An SF Symbol for the kind of Mac.
    var symbol: String
    var online: Bool
    /// What waits for the user on it.
    var waiting = 0
    var status: String
}

/// A command waiting for the user's answer.
struct PermissionRequest: Equatable {
    var agent: String
    var tool: String
    var command: String
}

/// A pane's shell at a prompt: what the input bar shows.
struct ShellState: Equatable {
    var folder: String
    var branch: String?
    var dirty = false
    /// The last command's exit code and how long it ran.
    var lastExit: (code: Int, duration: TimeInterval)?
    var draft = ""

    static func == (a: ShellState, b: ShellState) -> Bool {
        a.folder == b.folder && a.branch == b.branch && a.dirty == b.dirty && a.draft == b.draft
            && a.lastExit?.code == b.lastExit?.code && a.lastExit?.duration == b.lastExit?.duration
    }
}

/// One pane: what runs in it, its state, and what its screen shows.
struct PhonePane: Identifiable, Equatable {
    let id = UUID()
    var program: Program?
    var title: String
    var folder: String
    var display: PaneActivity.Display = .idle
    /// The agent's tool, while it works or asks.
    var tool: String?
    /// When its agent's state last changed.
    var since = Date()
    var screen: [TerminalLine]
    var shell: ShellState?
    var permission: PermissionRequest?
}

struct PhoneTab: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var panes: [PhonePane]
    var focusedPane: UUID
    /// Something happened while it was out of sight.
    var unseen = false

    init(title: String, panes: [PhonePane], unseen: Bool = false) {
        self.title = title
        self.panes = panes
        focusedPane = panes[0].id
        self.unseen = unseen
    }

    var focused: PhonePane { panes.first { $0.id == focusedPane } ?? panes[0] }
    /// The pane its row stands for: its agent's, if it runs one, else the focused one.
    var lead: PhonePane { panes.first { $0.program?.isAgent == true } ?? focused }
    /// The most urgent of its panes' states.
    var display: PaneActivity.Display { panes.map(\.display).max() ?? .idle }
    var permission: PermissionRequest? { panes.lazy.compactMap(\.permission).first }
    var isAgent: Bool { panes.contains { $0.program?.isAgent == true } }
}

struct PhoneProject: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var folded = false
    var tabs: [PhoneTab]
}

/// What the phone shows: the Macs, and the selected one's projects and tabs. The demo fills it with
/// scripted state; the remote API (PTY-71) will fill it from the Mac.
@MainActor
@Observable
final class PhoneModel {
    var macs: [PhoneMac]
    var macID: UUID
    var projects: [PhoneProject]
    var selectedTab: UUID?
    /// On a phone-width screen, the pane is open over the sidebar.
    var paneOpen = false
    /// The sidebar lists only the tabs running agents (the eye).
    var showsActivity = false
    var switchingMac = false
    /// The Mac's terminal theme.
    let theme: ThemeSwatch
    /// The modifier keys latched on the key row.
    var latched: Set<String> = []

    init(macs: [PhoneMac], projects: [PhoneProject], theme: ThemeSwatch) {
        self.macs = macs
        macID = macs[0].id
        self.projects = projects
        self.theme = theme
        selectedTab = projects.first?.tabs.first?.id
    }

    var mac: PhoneMac { macs.first { $0.id == macID } ?? macs[0] }

    var tab: PhoneTab? { selectedTab.flatMap(tab(_:)) }

    var allTabs: [PhoneTab] { projects.flatMap(\.tabs) }

    func tab(_ id: UUID) -> PhoneTab? { allTabs.first { $0.id == id } }

    func project(of tab: UUID) -> PhoneProject? { projects.first { $0.tabs.contains { $0.id == tab } } }

    func select(_ tab: UUID) {
        selectedTab = tab
        update(tab) { $0.unseen = false }
        paneOpen = true
    }

    func focus(_ pane: UUID, in tab: UUID) {
        update(tab) { $0.focusedPane = pane }
    }

    func toggleFold(_ project: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == project }) else { return }
        projects[index].folded.toggle()
    }

    func toggleLatch(_ key: String) {
        if latched.contains(key) { latched.remove(key) } else { latched.insert(key) }
    }

    enum Answer { case yes, always, no }

    /// Answers the tab's waiting prompt. The demo's agent then works for a moment and finishes.
    func answer(_ answer: Answer, tab id: UUID) {
        guard let pane = tab(id)?.panes.first(where: { $0.permission != nil }) else { return }
        update(id, pane: pane.id) { pane in
            let command = pane.permission?.command ?? ""
            pane.permission = nil
            pane.since = Date()
            switch answer {
            case .yes, .always:
                pane.display = .working
                pane.screen.append(contentsOf: [
                    TerminalLine(""),
                    TerminalLine("● Bash(\(command))"),
                    TerminalLine("{8:  ⎿  Running…}"),
                ])
            case .no:
                pane.display = .attention
                pane.tool = nil
                pane.screen.append(contentsOf: [TerminalLine(""), TerminalLine("{8:  ⎿  Not run. Tell Claude what to do instead.}")])
            }
        }
        guard answer != .no else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.finishDemoRun(tab: id, pane: pane.id)
        }
    }

    private func finishDemoRun(tab: UUID, pane: UUID) {
        update(tab, pane: pane) { pane in
            pane.display = .finished
            pane.tool = nil
            pane.since = Date()
            pane.screen.removeLast()
            pane.screen.append(contentsOf: [
                TerminalLine("{2:  ⎿  Executed 18 tests, with 0 failures}"),
                TerminalLine(""),
                TerminalLine("● RemoteProtocol's tests pass. The snapshot now carries each pane's size."),
            ])
        }
        if selectedTab != tab { update(tab) { $0.unseen = true } }
    }

    /// Runs the input bar's command: the demo prints it as a block.
    func run(_ command: String, tab: UUID, pane: UUID) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update(tab, pane: pane) { pane in
            let words = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            pane.screen.append(TerminalLine(""))
            pane.screen.append(TerminalLine("{2:\(words[0])}" + (words.count > 1 ? " " + words[1] : "")))
            pane.screen.append(TerminalLine("{8:(demo: not connected to a Mac)}"))
            pane.shell?.draft = ""
            pane.shell?.lastExit = (0, 0.4)
        }
    }

    func setDraft(_ text: String, tab: UUID, pane: UUID) {
        update(tab, pane: pane) { $0.shell?.draft = text }
    }

    private func update(_ tab: UUID, _ change: (inout PhoneTab) -> Void) {
        for p in projects.indices {
            if let t = projects[p].tabs.firstIndex(where: { $0.id == tab }) {
                change(&projects[p].tabs[t])
                return
            }
        }
    }

    private func update(_ tab: UUID, pane: UUID, _ change: (inout PhonePane) -> Void) {
        update(tab) { tab in
            if let index = tab.panes.firstIndex(where: { $0.id == pane }) { change(&tab.panes[index]) }
        }
    }
}
