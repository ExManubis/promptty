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

    /// The pinned tabs are always the first `pinnedCount` tabs.
    public var pinnedCount: Int { tabs.prefix { $0.pin != nil }.count }

    /// Opened after the selected tab, but never among the pinned tabs.
    @discardableResult
    public func addTab(title: String, workingDirectory: String, id: TabID = TabID(), customTitle: String? = nil) -> Tab {
        let tab = Tab(id: id, title: title, customTitle: customTitle, workingDirectory: workingDirectory)
        let insertAt: Int
        if let selectedTabID, let i = index(of: selectedTabID) {
            insertAt = max(i + 1, pinnedCount)
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
        return index(of: selectedTabID) != from
    }

    /// Moves a tab within its group: pinned tabs among the pinned tabs, others after them.
    public func moveTab(id: TabID, to newIndex: Int) {
        guard let from = index(of: id) else { return }
        let pinned = pinnedCount
        let range = tabs[from].pin != nil ? 0...(pinned - 1) : pinned...(tabs.count - 1)
        let clamped = min(max(newIndex, range.lowerBound), range.upperBound)
        guard clamped != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
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

    /// Unpins a tab and places it among the other tabs: at `index`, or first after the pinned tabs.
    public func unpin(_ id: TabID, at index: Int? = nil) {
        guard let from = self.index(of: id), tabs[from].pin != nil else { return }
        let tab = tabs.remove(at: from)
        tab.pin = nil
        let pinned = pinnedCount
        tabs.insert(tab, at: min(max(index ?? pinned, pinned), tabs.count))
    }

    /// The command a pinned tab runs on relaunch and reset; blank for none.
    public func setPinnedCommand(_ id: TabID, _ command: String?) {
        guard let tab = tab(id: id), let pin = tab.pin else { return }
        tab.pin = TabPin(directory: pin.directory, command: command)
    }
}
