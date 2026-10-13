import CoreGraphics
import GhosttyBridge
import PaneActivity
import WorkspaceModel

/// What the SwiftUI chrome can ask its window to do. Implemented by `TerminalWindowController`.
@MainActor
protocol ChromeActions: AnyObject {
    func surfaceView(for pane: Pane) -> TerminalSurfaceView?
    func shell(for pane: PaneID) -> PaneShell?
    /// What runs in a pane and what happened there unseen (observable).
    func activity(for pane: PaneID) -> PaneActivity
    /// Every pane running an agent, in every window.
    func agents() -> [AgentEntry]
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
    /// Asks for a folder and makes a project of it; `tab` (if any) moves into it.
    func newProject(adding tab: TabID?)
    /// A new tab in the project's folder, in the project; nil: a tab in no project (the "+ New
    /// Tab" row), where ⌘T would join the selected tab's project.
    func newTab(inProject project: ProjectID?)
    /// Puts a tab in a project (nil: in none), at `index` (a drop) or after the project's tabs.
    /// A pinned tab is unpinned when it has an index (dropped among a project's rows).
    func placeTab(_ id: TabID, inProject project: ProjectID?, at index: Int?)
    func renameProject(_ id: ProjectID)
    func changeProjectFolder(_ id: ProjectID)
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

/// An agent pane, for the sidebar's Agents section.
struct AgentEntry: Identifiable {
    let pane: PaneID
    let program: Program
    let title: String
    let activity: PaneActivity
    /// The repository (or folder) the agent works in.
    let repository: Repository
    /// The sidebar project of the agent's tab; nil when it is in none.
    let projectID: ProjectID?
    var id: PaneID { pane }
}
