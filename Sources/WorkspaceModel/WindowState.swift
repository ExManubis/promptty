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
    public private(set) var tabs: [Tab] = []
    public var selectedTabID: TabID?

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

    @discardableResult
    public func addTab(title: String, workingDirectory: String, id: TabID = TabID(), customTitle: String? = nil) -> Tab {
        let tab = Tab(id: id, title: title, customTitle: customTitle, workingDirectory: workingDirectory)
        let insertAt: Int
        if let selectedTabID, let i = index(of: selectedTabID) {
            insertAt = i + 1
        } else {
            insertAt = tabs.count
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
        return true
    }

    public func moveTab(id: TabID, to newIndex: Int) {
        guard let from = index(of: id) else { return }
        let clamped = max(0, min(newIndex, tabs.count - 1))
        guard clamped != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
    }
}
