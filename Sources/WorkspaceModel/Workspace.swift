import Foundation
import Observation

@MainActor
@Observable
public final class Workspace {
    public var tabLayout: TabLayout
    public private(set) var windows: [WindowState] = []

    public init(tabLayout: TabLayout = .sidebar) {
        self.tabLayout = tabLayout
    }

    public func toggleTabLayout() { tabLayout = tabLayout.toggled }

    @discardableResult
    public func addWindow(id: WindowID = WindowID(), frame: WindowFrame? = nil) -> WindowState {
        let w = WindowState(id: id, frame: frame)
        windows.append(w)
        return w
    }

    public func removeWindow(id: WindowID) {
        windows.removeAll { $0.id == id }
    }

    public func window(id: WindowID) -> WindowState? { windows.first { $0.id == id } }

    public func window(containing tabID: TabID) -> WindowState? {
        windows.first { $0.tab(id: tabID) != nil }
    }

    public func tab(containing pane: PaneID) -> (WindowState, Tab)? {
        for w in windows {
            if let t = w.tab(containing: pane) { return (w, t) }
        }
        return nil
    }

    /// Moves `pane` to `edge` of `target`, in the same tab or another tab or window, then selects
    /// and focuses it there. A source tab left without panes is closed; a window left without tabs
    /// is the caller's to close. Returns false and changes nothing when `pane == target` or either
    /// is unknown.
    @discardableResult
    public func movePane(_ pane: PaneID, to target: PaneID, edge: PaneEdge) -> Bool {
        guard pane != target,
              let (sourceWindow, sourceTab) = tab(containing: pane),
              let (targetWindow, targetTab) = tab(containing: target),
              let moving = sourceTab.pane(pane) else { return false }
        // A pinned tab cannot be closed, so its last pane stays.
        if sourceTab !== targetTab, sourceTab.pin != nil, !sourceTab.hasSplits { return false }
        if sourceTab === targetTab {
            guard sourceTab.detach(pane) != nil else { return false }
        } else if sourceTab.hasSplits {
            guard sourceTab.detach(pane) != nil else { return false }
        } else {
            sourceWindow.closeTab(id: sourceTab.id)
        }
        targetTab.attach(moving, at: target, edge: edge)
        targetWindow.select(id: targetTab.id)
        return true
    }

    /// Moves `pane` into another tab, to the right of that tab's focused pane.
    @discardableResult
    public func movePane(_ pane: PaneID, intoTab tabID: TabID) -> Bool {
        guard let targetWindow = window(containing: tabID),
              let targetTab = targetWindow.tab(id: tabID),
              let (_, sourceTab) = tab(containing: pane),
              sourceTab !== targetTab else { return false }
        return movePane(pane, to: targetTab.focusedPaneID, edge: .right)
    }
}
