import AppKit
import Observation
import WorkspaceModel

/// A message strip above the panes. Persistent (settings/config problems) or transient.
struct BannerContent {
    let id = UUID()
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
}

/// Per-window state the SwiftUI chrome shows that is not part of the workspace model.
@MainActor
@Observable
final class WindowChromeModel {
    var tint: NSColor = ChromeTint.fallback
    var banner: BannerContent?
    /// Panes whose shell exited, with the exit code, until they are closed.
    var exitedPanes: [PaneID: UInt32] = [:]
    var renamingTab: TabID?
    /// The pane a dragged pane would land on, and where.
    var dropTarget: (pane: PaneID, edge: PaneEdge)?
    /// The tab row a dragged pane hovers over.
    var dropTargetTab: TabID?
    /// A pane is being dragged (drop zones only appear then).
    var draggingPane: PaneID?
    /// Shows every pane header without hover (debug driver snapshots).
    var forceHeaders = false
}
