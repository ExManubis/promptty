import Foundation
import Observation

@MainActor
@Observable
public final class Workspace {
    public var tabLayout: TabLayout
    public private(set) var windows: [WindowState] = []
    /// The sidebar's projects, in order. Every window shows them all.
    public private(set) var projects: [Project] = [] {
        didSet { syncProjectOrder() }
    }

    public init(tabLayout: TabLayout = .sidebar) {
        self.tabLayout = tabLayout
    }

    public func toggleTabLayout() { tabLayout = tabLayout.toggled }

    @discardableResult
    public func addWindow(id: WindowID = WindowID(), frame: WindowFrame? = nil) -> WindowState {
        let w = WindowState(id: id, frame: frame)
        w.projectOrder = projects.map(\.id)
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

    // MARK: Projects

    public func project(id: ProjectID) -> Project? { projects.first { $0.id == id } }

    /// The project a tab is in, if the workspace still has it.
    public func project(of tab: Tab) -> Project? { tab.projectID.flatMap(project(id:)) }

    /// Adds a project after the others, or at `index`.
    @discardableResult
    public func addProject(name: String, icon: PinIcon? = nil, id: ProjectID = ProjectID(), folded: Bool = false, at index: Int? = nil) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(id: id, name: trimmed.isEmpty ? Project.untitled : trimmed, icon: icon, folded: folded)
        projects.insert(project, at: min(max(index ?? projects.count, 0), projects.count))
        return project
    }

    /// Removes a project. Its tabs stay open, in no project.
    public func removeProject(id: ProjectID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        for w in windows {
            for tab in w.tabs where tab.projectID == id { tab.projectID = nil }
        }
        projects.remove(at: i)
    }

    /// Moves a project to `index` among the projects; its tabs follow in every window.
    public func moveProject(id: ProjectID, to index: Int) {
        guard let from = projects.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), projects.count - 1)
        guard to != from else { return }
        // One assignment: in between, the project's tabs would count as in none.
        var reordered = projects
        reordered.insert(reordered.remove(at: from), at: to)
        projects = reordered
    }

    private func syncProjectOrder() {
        let order = projects.map(\.id)
        for w in windows {
            w.projectOrder = order
            // A tab that left a project (removeProject) while the order stayed the same.
            w.regroup()
        }
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
