import CoreGraphics
import GhosttyBridge
import Observation
import PaneActivity
import WorkspaceModel

/// What the SwiftUI chrome can ask its window to do. Implemented by `TerminalWindowController`.
@MainActor
protocol ChromeActions: AnyObject {
    func surfaceView(for pane: Pane) -> TerminalSurfaceView?
    func shell(for pane: PaneID) -> PaneShell?
    /// What runs in a pane and what happened there unseen (observes that pane alone).
    func activity(for pane: PaneID) -> PaneActivity.Visible
    /// The link under the pointer in a pane (observes that pane alone).
    func hoveredLink(for pane: PaneID) -> String?
    /// What a program in a pane waits to do with the clipboard (observes that pane alone).
    func clipboardRequest(for pane: PaneID) -> ClipboardTicket?
    func answerClipboardRequest(_ decision: ClipboardDecision, id: Int, in pane: PaneID)
    /// Allows the request, and this kind of request from `program` in any pane from now on.
    func alwaysAllowClipboard(_ ticket: ClipboardTicket, for program: String, in pane: PaneID)
    /// A pane's progress report, if it has one (observes that pane alone).
    func progress(for pane: PaneID) -> PaneProgress?
    /// The ports a pane's programs listen on (observes that pane alone).
    func ports(for pane: PaneID) -> [Int]
    /// Opens http://localhost:<port> in the browser.
    func openPort(_ port: Int)
    /// A pane's find bar, nil while closed (observes that pane alone).
    func findState(for pane: PaneID) -> PaneFind?
    func setFindText(_ text: String, in pane: PaneID)
    func findNavigate(in pane: PaneID, forward: Bool)
    func closeFind(in pane: PaneID)
    /// Whether secure keyboard input is on for a pane (observes that pane alone).
    func isSecure(_ pane: PaneID) -> Bool
    /// The agents of every tab, in every window (observable).
    var agentList: AgentList { get }
    /// Brings a pane forward, in whichever window it is.
    func reveal(_ pane: PaneID)
    /// Shows a tab's preview beside its sidebar row (`row` in the window's top-left coordinates),
    /// `titled` for a pinned tile, which shows no title itself.
    func showPreview(of tab: TabID, beside row: CGRect, titled: Bool)
    func hidePreview(of tab: TabID)
    /// A pane's visible text, from its terminal if it has one already (a preview never starts a
    /// shell).
    func screenText(for pane: PaneID) -> String?
    func selectTab(_ id: TabID)
    func requestCloseTab(_ id: TabID)
    func newTab()
    func renameTab(_ id: TabID, to title: String)
    func endRenaming()
    func moveTab(_ id: TabID, to index: Int)
    /// Pins a tab, at `index` among the pinned tabs (a drop) or after them.
    func pinTab(_ id: TabID, at index: Int?)
    /// Unpins a tab, at `index` among the other tabs (a drop) or first after the pinned tabs.
    func unpinTab(_ id: TabID, at index: Int?)
    /// Back to the pinned folder, running the pinned command.
    func resetPinnedTab(_ id: TabID)
    func editPinnedCommand(_ id: TabID)
    /// A pinned tab's own icon; nil shows its programs' logos again.
    func setPinnedIcon(_ id: TabID, _ icon: PinIcon?)
    // Projects
    /// The workspace's projects, in sidebar order (observable).
    var projects: [Project] { get }
    /// Asks for a name and makes a project; `tab` (if any, in any window) moves into it.
    func newProject(adding tab: TabID?)
    /// A new tab in the project (in the folder of one of its tabs); nil: a tab in no project (the
    /// "+ New Tab" row), where ⌘T would join the selected tab's project.
    func newTab(inProject project: ProjectID?)
    /// Puts a tab in a project (nil: in none), at `index` (a drop) or after the project's tabs.
    /// A pinned tab is unpinned when it has an index (dropped among a project's rows). Without an
    /// index the tab may be in any window.
    func placeTab(_ id: TabID, inProject project: ProjectID?, at index: Int?)
    func renameProject(_ id: ProjectID)
    func setProjectIcon(_ id: ProjectID, _ icon: PinIcon?)
    func setProjectFolded(_ id: ProjectID, _ folded: Bool)
    /// Moves a project up (-1) or down (+1) among the projects.
    func moveProject(_ id: ProjectID, by offset: Int)
    /// Moves a project to `index` among the projects (a drop on another project's header).
    func moveProject(_ id: ProjectID, to index: Int)
    /// Removes a project after asking; its tabs stay, in no project.
    func requestRemoveProject(_ id: ProjectID)
    func toggleSidebar()
    /// Closes the command palette, then runs what was picked in it.
    func closePalette(running entry: PaletteEntry?)
    /// The window's traffic lights, which go with the sidebar when it collapses.
    func setTrafficLightsShown(_ shown: Bool)
    func split(_ pane: PaneID, direction: SplitDirection)
    func requestClosePane(_ pane: PaneID)
    func focusPane(_ pane: PaneID)
    func setRatio(in tab: TabID, at path: SplitPath, _ ratio: Double)
    func movePane(_ pane: PaneID, to target: PaneID, edge: PaneEdge)
    func movePane(_ pane: PaneID, intoTab tab: TabID)
}

/// The agents on the sidebar's tab rows, worked out by the coordinator when panes, what runs in
/// them or their repositories change, not by the views that show them.
@MainActor
@Observable
final class AgentList {
    /// Every tab running an agent, in every window.
    var tabs: [TabID: TabAgentSummary] = [:]

    func summary(for tab: TabID) -> TabAgentSummary? { tabs[tab] }
}

/// What a tab row shows of the agents in its tab: the most urgent one, and how many others.
struct TabAgentSummary: Equatable {
    let entry: AgentEntry
    /// The tab's other agents.
    let others: Int
}

/// An agent pane.
struct AgentEntry: Equatable {
    let pane: PaneID
    /// What the agent shows, for choosing the tab's most urgent; its row reads the rest from
    /// `status`.
    let display: PaneActivity.Display
    /// The repository (or folder) the agent works in.
    let repository: Repository
    /// The pane's box, which its row observes.
    let status: PaneStatus

    nonisolated static func == (a: AgentEntry, b: AgentEntry) -> Bool {
        a.pane == b.pane && a.display == b.display && a.repository == b.repository
            && a.status === b.status
    }
}
