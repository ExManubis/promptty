import Foundation
import Observation

public struct WindowID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum GotoTabTarget: Equatable, Sendable {
    /// 1-based, matching Ghostty's `goto_tab:N` keybind.
    case index(Int)
    case previous
    case next
    case last
}

@MainActor
@Observable
public final class WindowState {
    public let id: WindowID
    public var frame: WindowFrame?
    /// In the order shown: the pinned tabs, then each project's tabs in `projectOrder`, then the
    /// tabs in no project. Every change keeps it so, which is why going to tab N, the next tab or
    /// the previous one just follows the array.
    public private(set) var tabs: [Tab] = []
    public var selectedTabID: TabID?
    /// The workspace's projects in sidebar order, kept by `Workspace`. A tab whose project is not
    /// here counts as in no project.
    public internal(set) var projectOrder: [ProjectID] = [] {
        didSet { if projectOrder != oldValue { regroup() } }
    }

    public init(id: WindowID = WindowID(), frame: WindowFrame? = nil) {
        self.id = id
        self.frame = frame
    }

    public var isEmpty: Bool { tabs.isEmpty }

    public var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tab(id: selectedTabID)
    }

    public func tab(id: TabID) -> Tab? { tabs.first { $0.id == id } }

    public func index(of id: TabID) -> Int? { tabs.firstIndex { $0.id == id } }

    public func tab(containing pane: PaneID) -> Tab? { tabs.first { $0.pane(pane) != nil } }

    /// The pinned tabs are always the first `pinnedCount` tabs.
    public var pinnedCount: Int { tabs.prefix { $0.pin != nil }.count }

    /// Opened in `project` (nil for none): after the selected tab when that is in the same
    /// project and not pinned, else first among the project's tabs. Never among the pinned tabs.
    @discardableResult
    public func addTab(title: String, workingDirectory: String, id: TabID = TabID(), customTitle: String? = nil, project: ProjectID? = nil) -> Tab {
        let tab = Tab(id: id, title: title, customTitle: customTitle, workingDirectory: workingDirectory)
        tab.projectID = project
        let group = bounds(of: rank(of: tab))
        let insertAt: Int
        if let selectedTabID, let i = index(of: selectedTabID), group.contains(i) {
            insertAt = i + 1
        } else if selectedTabID == nil {
            insertAt = group.upperBound
        } else {
            insertAt = group.lowerBound
        }
        tabs.insert(tab, at: insertAt)
        self.selectedTabID = tab.id
        return tab
    }

    /// Removes the tab and, if it was selected, selects the right neighbor, else the left.
    @discardableResult
    public func closeTab(id: TabID) -> Tab? {
        guard let i = index(of: id) else { return nil }
        let removed = tabs.remove(at: i)
        if selectedTabID == id {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                let next = min(i, tabs.count - 1)
                selectedTabID = tabs[next].id
            }
        }
        return removed
    }

    public func select(id: TabID) {
        guard tab(id: id) != nil else { return }
        selectedTabID = id
    }

    @discardableResult
    public func gotoTab(_ target: GotoTabTarget) -> Bool {
        guard !tabs.isEmpty else { return false }
        let current = selectedTabID.flatMap(index(of:)) ?? 0
        let destination: Int
        switch target {
        case .index(let n):
            guard n >= 1, n <= tabs.count else { return false }
            destination = n - 1
        case .previous:
            guard tabs.count > 1 else { return false }
            destination = (current - 1 + tabs.count) % tabs.count
        case .next:
            guard tabs.count > 1 else { return false }
            destination = (current + 1) % tabs.count
        case .last:
            destination = tabs.count - 1
        }
        selectedTabID = tabs[destination].id
        return true
    }

    /// Moves the selected tab by `amount` positions; returns false if nothing moved.
    @discardableResult
    public func moveSelectedTab(by amount: Int) -> Bool {
        guard let selectedTabID, let from = index(of: selectedTabID) else { return false }
        let (to, overflow) = from.addingReportingOverflow(amount)
        guard !overflow, to >= 0, to < tabs.count, to != from else { return false }
        moveTab(id: selectedTabID, to: to)
        return index(of: selectedTabID) != from
    }

    /// Moves a tab within its group: pinned tabs among the pinned tabs, a project's tabs among
    /// that project's, the others among the others.
    public func moveTab(id: TabID, to newIndex: Int) {
        guard let from = index(of: id) else { return }
        let range = bounds(of: rank(of: tabs[from]))
        let clamped = min(max(newIndex, range.lowerBound), range.upperBound - 1)
        guard clamped != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
    }

    // MARK: Projects

    /// Puts a tab in `project` (nil: in none), at `index` among that project's tabs (a drop) or
    /// after them. A pinned tab stays among the pinned tabs; its project only groups its agents.
    public func setProject(_ id: TabID, _ project: ProjectID?, at index: Int? = nil) {
        guard let from = self.index(of: id) else { return }
        let tab = tabs[from]
        if tab.pin != nil {
            tab.projectID = project
            return
        }
        tabs.remove(at: from)
        tab.projectID = project
        let group = bounds(of: rank(of: tab))
        tabs.insert(tab, at: min(max(index ?? group.upperBound, group.lowerBound), group.upperBound))
    }

    /// The project a tab counts as in: its own, when the workspace still has it.
    public func project(of tab: Tab) -> ProjectID? {
        guard let id = tab.projectID, projectOrder.contains(id) else { return nil }
        return id
    }

    /// The pinned tabs are 0, the projects 1…n in order, the tabs in no project n + 1.
    private func rank(of tab: Tab) -> Int {
        if tab.pin != nil { return 0 }
        if let id = tab.projectID, let i = projectOrder.firstIndex(of: id) { return i + 1 }
        return projectOrder.count + 1
    }

    /// Where the tabs of `rank` are, or would go: an empty range for a group without tabs.
    private func bounds(of rank: Int) -> Range<Int> {
        let start = tabs.firstIndex { self.rank(of: $0) >= rank } ?? tabs.count
        let end = tabs.firstIndex { self.rank(of: $0) > rank } ?? tabs.count
        return start..<max(start, end)
    }

    /// Restores the order after the projects change: groups in rank order, each keeping its own.
    func regroup() {
        let ordered = tabs.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank(of: a.element), rank(of: b.element))
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
        if ordered.map(\.id) != tabs.map(\.id) { tabs = ordered }
    }

    // MARK: Pinned tabs

    /// Pins a tab (or changes its pin) and places it among the pinned tabs: at `index`, or after
    /// the last one.
    public func pin(_ id: TabID, _ pin: TabPin, at index: Int? = nil) {
        guard let from = self.index(of: id) else { return }
        let tab = tabs.remove(at: from)
        let pinned = pinnedCount
        tab.pin = pin
        tabs.insert(tab, at: min(max(index ?? pinned, 0), pinned))
    }

    /// Unpins a tab and places it among its project's tabs (or the tabs in no project): at
    /// `index`, or first among them.
    public func unpin(_ id: TabID, at index: Int? = nil) {
        guard let from = self.index(of: id), tabs[from].pin != nil else { return }
        let tab = tabs.remove(at: from)
        tab.pin = nil
        let group = bounds(of: rank(of: tab))
        tabs.insert(tab, at: min(max(index ?? group.lowerBound, group.lowerBound), group.upperBound))
    }

    /// The command a pinned tab runs on relaunch and reset; blank for none.
    public func setPinnedCommand(_ id: TabID, _ command: String?) {
        guard let tab = tab(id: id), let pin = tab.pin else { return }
        tab.pin = TabPin(directory: pin.directory, command: command, icon: pin.icon)
    }

    /// A pinned tab's own icon; nil goes back to its programs' logos.
    public func setPinnedIcon(_ id: TabID, _ icon: PinIcon?) {
        guard let tab = tab(id: id), tab.pin != nil else { return }
        tab.pin?.icon = icon
    }
}
