import AppKit
import Observation
import WorkspaceModel

/// A message strip above the panes. Persistent (settings/config problems) or transient.
struct BannerContent {
    let id = UUID()
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var symbol = "exclamationmark.triangle.fill"
    /// Further buttons, shown before the main one.
    var extraActions: [(title: String, action: () -> Void)] = []
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
    /// The sidebar lists only the tabs running agents, with what each does and since when (Rex's
    /// Activity).
    var showsActivity = false
    /// How many times each pane's selection was copied: each copy plays its card's `CopyShine`.
    var copyShines: [PaneID: Int] = [:]
    var banner: BannerContent?
    /// Panes whose shell exited, with the exit code, until they are closed.
    var exitedPanes: [PaneID: UInt32] = [:]
    var renamingTab: TabID?
    /// The pinned tab whose icon picker is open.
    var iconPickerTab: TabID?
    /// The project whose icon picker is open.
    var iconPickerProject: ProjectID?
    /// The project whose header is being dragged.
    var draggingProject: ProjectID?
    /// The pane a dragged pane would land on, and where.
    var dropTarget: (pane: PaneID, edge: PaneEdge)?
    /// The tab row a dragged pane hovers over.
    var dropTargetTab: TabID?
    /// A pane is being dragged (drop zones only appear then).
    var draggingPane: PaneID?
    /// A tab is being dragged: the pinned tabs' drop zone shows even with none pinned.
    var draggingTab: TabID?
    /// Debug driver: the collapsed sidebar peeks in without hovering.
    var forcedPeek = false
    /// A split divider is being dragged: panes follow it without animating.
    var resizingSplit = false
    /// Tabs whose panes all get what is typed in any of them.
    var broadcastTabs: Set<TabID> = []
    /// The open command palette.
    var palette: PaletteModel?
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

    @ObservationIgnored private var paneDragWatch: Task<Void, Never>?

    /// A pane drag started (from its header); it ends like a tab drag (`beginTabDrag`).
    func beginPaneDrag(_ pane: PaneID) {
        draggingPane = pane
        paneDragWatch?.cancel()
        paneDragWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                guard self.draggingPane == nil || NSEvent.pressedMouseButtons == 0 else { continue }
                try? await Task.sleep(for: .milliseconds(50))
                self.draggingPane = nil
                return
            }
        }
    }

    @ObservationIgnored private var projectDragWatch: Task<Void, Never>?

    /// A project header drag started; it ends like a tab drag (`beginTabDrag`).
    func beginProjectDrag(_ project: ProjectID) {
        draggingProject = project
        projectDragWatch?.cancel()
        projectDragWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                guard self.draggingProject == nil || NSEvent.pressedMouseButtons == 0 else { continue }
                try? await Task.sleep(for: .milliseconds(50))
                self.draggingProject = nil
                return
            }
        }
    }
}
