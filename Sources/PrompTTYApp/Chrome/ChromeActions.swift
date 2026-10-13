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
    /// Every pane running an agent, in every window (observable).
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
    /// A new tab in the project (in the folder of one of its tabs); nil: a tab in no project
    /// (⌘T would join the selected tab's).
    func newTab(inProject project: ProjectID?)
    /// Puts a tab, in any window, in a project (nil: in none). It keeps its place in the tab list.
    func placeTab(_ id: TabID, inProject project: ProjectID?)
    /// Asks for a tab's name in a sheet; the tab may be in any window (an agent's).
    func requestRenameTab(_ id: TabID)
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
    /// The window's traffic lights, which go with the sidebar when it collapses.
    func setTrafficLightsShown(_ shown: Bool)
    func split(_ pane: PaneID, direction: SplitDirection)
    func requestClosePane(_ pane: PaneID)
    func focusPane(_ pane: PaneID)
    func setRatio(in tab: TabID, at path: SplitPath, _ ratio: Double)
    func movePane(_ pane: PaneID, to target: PaneID, edge: PaneEdge)
    func movePane(_ pane: PaneID, intoTab tab: TabID)
}

/// The sidebar's agents, worked out by the coordinator when panes, what runs in them or their
/// repositories change, not by the view that shows them.
@MainActor
@Observable
final class AgentList {
    /// Window by window, tab by tab.
    var entries: [AgentEntry] = []
}

/// An agent pane, for the sidebar's Agents section.
struct AgentEntry: Identifiable, Equatable {
    let pane: PaneID
    /// The tab the agent's pane is in, in whichever window.
    let tab: TabID
    let program: Program
    let title: String
    /// What the agent shows, for grouping and ordering; its row reads the rest from `status`.
    let display: PaneActivity.Display
    /// The repository (or folder) the agent works in.
    let repository: Repository
    /// The sidebar project of the agent's tab; nil when it is in none.
    let projectID: ProjectID?
    /// The pane's box, which its row observes.
    let status: PaneStatus
    var id: PaneID { pane }

    nonisolated static func == (a: AgentEntry, b: AgentEntry) -> Bool {
        a.pane == b.pane && a.tab == b.tab && a.program == b.program && a.title == b.title && a.display == b.display
            && a.repository == b.repository && a.projectID == b.projectID && a.status === b.status
    }
}
