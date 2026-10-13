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
    /// The tint over the window's blurred backdrop: Dia's neutral gray, or a theme-tinted color.
    var tint: NSColor = ChromeTint.fallback
    /// The content panel's fill: the terminal theme background, so the toolbar and the
    /// terminal read as one surface.
    var panelColor: NSColor = .textBackgroundColor
    var panelIsDark: Bool { ChromeTint.isDark(panelColor) }
    var banner: BannerContent?
    /// Panes whose shell exited, with the exit code, until they are closed.
    var exitedPanes: [PaneID: UInt32] = [:]
    var renamingTab: TabID?
    /// The pinned tab whose icon picker is open.
    var iconPickerTab: TabID?
    /// The pane a dragged pane would land on, and where.
    var dropTarget: (pane: PaneID, edge: PaneEdge)?
    /// The tab row a dragged pane hovers over.
    var dropTargetTab: TabID?
    /// A pane is being dragged (drop zones only appear then).
    var draggingPane: PaneID?
    /// A tab is being dragged: the pinned tabs' drop zone shows even with none pinned.
    var draggingTab: TabID?
    /// Debug driver: the tab whose preview shows without hovering.
    var forcedPreview: TabID?
    /// Debug driver: the collapsed sidebar peeks in without hovering.
    var forcedPeek = false
    /// A split divider is being dragged: panes follow it without animating.
    var resizingSplit = false
    /// Panes just closed whose terminals stay alive while their cards shrink away.
    var closingPanes: [PaneID: ClosingPane] = [:]

    @ObservationIgnored private var tabDragWatch: Task<Void, Never>?

    /// A tab drag started. A drop ends it; a drag let go anywhere else (or cancelled) ends with
    /// the mouse button, which is watched for since SwiftUI does not say.
    func beginTabDrag(_ tab: TabID) {
        draggingTab = tab
        tabDragWatch?.cancel()
        tabDragWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                guard self.draggingTab == nil || NSEvent.pressedMouseButtons == 0 else { continue }
                // A drop is delivered just after the button comes up; let it read the drag first.
                try? await Task.sleep(for: .milliseconds(50))
                self.draggingTab = nil
                return
            }
        }
    }
}
