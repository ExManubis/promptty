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
    /// Shows a tab's preview beside its sidebar row (`row` in the window's top-left coordinates).
    func showPreview(of tab: TabID, beside row: CGRect)
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
    let project: Project
    var id: PaneID { pane }
}
