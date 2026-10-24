import Foundation
import Observation
import PaneActivity
import Preferences

/// A Mac running PrompTTY, as the phone knows it: the demo, or one added by its Tailscale name.
struct PhoneMac: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    /// Its Tailscale name ("mikkels-studio"), or a name and port.
    var host: String
    /// An SF Symbol for the kind of Mac.
    var symbol: String
    var online: Bool
    /// What waits for the user on it.
    var waiting = 0
    var status: String
    /// The demo's scripted Macs, not a connection.
    var isDemo = false
}

/// A command waiting for the user's answer.
struct PermissionRequest: Equatable {
    var agent: String
    var tool: String
    var command: String
    /// A real Mac's choices as its agent's screen shows them, each with the key that picks it.
    var choices: [Choice] = []

    struct Choice: Equatable {
        var key: String
        var label: String

        /// "Yes, and don't ask again for swift test" as a button says it: "Always".
        var shortLabel: String {
            if label.localizedCaseInsensitiveContains("don't ask again") || label.localizedCaseInsensitiveContains("always") { return "Always" }
            return label.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
        }
    }
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
    var id = UUID()
    var program: Program?
    var title: String
    /// Its label on the Mac (`promptty --label`).
    var label: String?
    var folder: String
    var display: PaneActivity.Display = .idle
    /// The agent's tool, while it works or asks.
    var tool: String?
    /// When its agent's state last changed.
    var since = Date()
    var screen: [TerminalLine]
    var shell: ShellState?
    var permission: PermissionRequest?
    /// On a Mac, its newest commands' ids, newest last: what `capture` reads the output of.
    var commandIDs: [String] = []
}

struct PhoneTab: Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// The folder its row shows dimmed after the title, as the Mac's; nil for the lead pane's own.
    var folder: String?
    var panes: [PhonePane]
    var focusedPane: UUID
    /// Something happened while it was out of sight.
    var unseen = false

    init(id: UUID = UUID(), title: String, folder: String? = nil, panes: [PhonePane], focusedPane: UUID? = nil, unseen: Bool = false) {
        self.id = id
        self.title = title
        self.folder = folder
        self.panes = panes
        self.focusedPane = focusedPane ?? panes[0].id
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
    var id = UUID()
    /// Empty for the tabs in no project.
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
    /// A tab to open once a Mac's workspace has come (`-open`).
    var pendingOpen: String?
    /// A tapped notification's tab, opened once its Mac's workspace has come.
    var pendingOpenTab: UUID?
    /// The sidebar lists only the tabs running agents (the eye).
    var showsActivity = false
    var switchingMac = false
    /// The Mac's terminal theme.
    let theme: ThemeSwatch
    /// The selected Mac's connection; nil for the demo.
    private(set) var connection: MacConnection?
    /// How the connection to the selected Mac is doing; nil for the demo.
    private(set) var connectionState: MacConnection.State?
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

    /// Connected to a real Mac rather than showing the demo.
    var isRemote: Bool { connection != nil }

    // MARK: Macs

    /// Shows a Mac: the demo's scripted tabs, or a real Mac's, connecting to it.
    func selectMac(_ id: UUID) {
        guard let mac = macs.first(where: { $0.id == id }) else { return }
        connection?.stop()
        connection = nil
        connectionState = nil
        macID = id
        UserDefaults.standard.set(id.uuidString, forKey: "selectedMac")
        paneOpen = false
        if mac.isDemo {
            projects = DemoData.projects
            selectedTab = projects.first?.tabs.first?.id
        } else {
            projects = []
            selectedTab = nil
            let connection = MacConnection(mac: mac, model: self)
            self.connection = connection
            connection.start()
        }
    }

    /// A tapped notification: its Mac, then its tab.
    func openFromNotification(mac: UUID, tab: UUID) {
        if macID != mac { selectMac(mac) }
        if self.tab(tab) != nil { select(tab) } else { pendingOpenTab = tab }
    }

    /// Adds a Mac by its Tailscale name (or name:port) and connects to it.
    func addMac(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MacConnection.url(for: trimmed) != nil else { return }
        let name = trimmed.split(separator: ":").first.map(String.init) ?? trimmed
        let mac = PhoneMac(name: name, host: trimmed, symbol: "laptopcomputer", online: false, status: "Connecting…")
        macs.append(mac)
        SavedMacs.save(macs)
        selectMac(mac.id)
    }

    func removeMac(_ id: UUID) {
        guard let mac = macs.first(where: { $0.id == id }), !mac.isDemo else { return }
        if macID == id { connection?.unregisterPush() }
        PushKeys.forget(mac: id)
        macs.removeAll { $0.id == id }
        SavedMacs.save(macs)
        if macID == id, let demo = macs.first { selectMac(demo.id) }
    }

    /// From the connection: how it is doing, shown in the switcher and the sidebar.
    func connectionChanged(_ state: MacConnection.State, for mac: UUID) {
        guard mac == macID else { return }
        connectionState = state
        guard let index = macs.firstIndex(where: { $0.id == mac }) else { return }
        switch state {
        case .connecting:
            macs[index].status = "Connecting…"
        case .connected(let name):
            macs[index].online = true
            macs[index].status = macs[index].host
            if macs[index].name != name {
                macs[index].name = name
                SavedMacs.save(macs)
            }
        case .failed(let reason):
            macs[index].online = false
            macs[index].status = reason
        }
    }

    /// From the connection: the Mac's tabs now. The selection stays where it was while that tab is
    /// there.
    func applyRemote(_ projects: [PhoneProject]) {
        self.projects = projects
        if let index = macs.firstIndex(where: { $0.id == macID }) {
            macs[index].waiting = allTabs.filter { $0.permission != nil }.count
        }
        if let id = pendingOpenTab, tab(id) != nil {
            pendingOpenTab = nil
            select(id)
        }
        if let title = pendingOpen, let tab = allTabs.first(where: { $0.title == title || $0.panes.contains { $0.label == title } }) {
            pendingOpen = nil
            select(tab.id)
        }
        if selectedTab.flatMap(tab(_:)) == nil {
            selectedTab = allTabs.first?.id
            if paneOpen, selectedTab == nil { paneOpen = false }
        }
    }

    var tab: PhoneTab? { selectedTab.flatMap(tab(_:)) }

    var allTabs: [PhoneTab] { projects.flatMap(\.tabs) }

    func tab(_ id: UUID) -> PhoneTab? { allTabs.first { $0.id == id } }

    func project(of tab: UUID) -> PhoneProject? { projects.first { $0.tabs.contains { $0.id == tab } } }

    func select(_ tab: UUID) {
        selectedTab = tab
        update(tab) { $0.unseen = false }
        paneOpen = true
        if let pane = self.tab(tab)?.focused { connection?.readOutputs(of: pane) }
    }

    func focus(_ pane: UUID, in tab: UUID) {
        update(tab) { $0.focusedPane = pane }
        if let focused = self.tab(tab)?.focused { connection?.readOutputs(of: focused) }
    }

    func toggleFold(_ project: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == project }) else { return }
        projects[index].folded.toggle()
    }

    func toggleLatch(_ key: String) {
        if latched.contains(key) { latched.remove(key) } else { latched.insert(key) }
    }

    enum Answer { case yes, always, no }

    /// Answers a real Mac's waiting prompt with a key, as pressed there: a choice's digit, or
    /// Return and Escape when its choices couldn't be read.
    func answer(key: String, tab id: UUID) {
        guard let connection, let pane = tab(id)?.panes.first(where: { $0.permission != nil }) else { return }
        connection.answer(key, in: pane.id)
    }

    /// Answers the tab's waiting prompt. The demo's agent then works for a moment and finishes.
    func answer(_ answer: Answer, tab id: UUID) {
        guard !isRemote, let pane = tab(id)?.panes.first(where: { $0.permission != nil }) else { return }
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

    /// Runs the input bar's command: in the Mac's pane, or, in the demo, printed as a block.
    func run(_ command: String, tab: UUID, pane: UUID) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let connection {
            connection.run(trimmed, in: pane)
            update(tab, pane: pane) { $0.shell?.draft = "" }
            return
        }
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
