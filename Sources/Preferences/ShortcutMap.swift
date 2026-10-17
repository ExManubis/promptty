import Foundation

public enum ShortcutGroup: String, CaseIterable, Sendable {
    case window, tabs, panes, terminal

    public var title: String {
        switch self {
        case .window: return "Window"
        case .tabs: return "Tabs"
        case .panes: return "Panes"
        case .terminal: return "Terminal"
        }
    }
}

/// Every app command that has an editable shortcut.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case newWindow, closeWindow, commandPalette
    case newTab, closeTab, nextTab, previousTab
    case gotoTab1, gotoTab2, gotoTab3, gotoTab4, gotoTab5, gotoTab6, gotoTab7, gotoTab8, gotoTab9
    case toggleSidebar, toggleTabLayout
    case splitRight, splitDown, closePane
    case focusPaneLeft, focusPaneUp, focusPaneRight, focusPaneDown, equalizePanes, zoomPane
    case copy, paste, selectAll, clear, biggerFont, smallerFont, actualSizeFont
    case selectPreviousCommand, selectNextCommand, selectPreviousFailed, selectNextFailed
    case copyOutput, copyCommand, rerunCommand
    case find, findNext, findPrevious, useSelectionForFind

    public var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .closeWindow: return "Close Window"
        case .commandPalette: return "Command Palette"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .gotoTab1, .gotoTab2, .gotoTab3, .gotoTab4, .gotoTab5, .gotoTab6, .gotoTab7, .gotoTab8, .gotoTab9:
            return "Go to Tab \(tabNumber!)"
        case .toggleSidebar: return "Toggle Sidebar"
        case .toggleTabLayout: return "Toggle Tab Layout"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .closePane: return "Close Pane"
        case .focusPaneLeft: return "Focus Pane Left"
        case .focusPaneUp: return "Focus Pane Above"
        case .focusPaneRight: return "Focus Pane Right"
        case .focusPaneDown: return "Focus Pane Below"
        case .equalizePanes: return "Equalize Panes"
        case .zoomPane: return "Zoom Pane"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .clear: return "Clear"
        case .biggerFont: return "Bigger"
        case .smallerFont: return "Smaller"
        case .actualSizeFont: return "Actual Size"
        case .selectPreviousCommand: return "Select Previous Command"
        case .selectNextCommand: return "Select Next Command"
        case .copyOutput: return "Copy Output"
        case .copyCommand: return "Copy Command"
        case .selectPreviousFailed: return "Select Previous Failed Command"
        case .selectNextFailed: return "Select Next Failed Command"
        case .rerunCommand: return "Rerun Command"
        case .find: return "Find"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .useSelectionForFind: return "Use Selection for Find"
        }
    }

    public var group: ShortcutGroup {
        switch self {
        case .newWindow, .closeWindow, .commandPalette: return .window
        case .newTab, .closeTab, .nextTab, .previousTab, .toggleSidebar, .toggleTabLayout,
             .gotoTab1, .gotoTab2, .gotoTab3, .gotoTab4, .gotoTab5, .gotoTab6, .gotoTab7, .gotoTab8, .gotoTab9:
            return .tabs
        case .splitRight, .splitDown, .closePane, .focusPaneLeft, .focusPaneUp, .focusPaneRight, .focusPaneDown, .equalizePanes, .zoomPane:
            return .panes
        case .copy, .paste, .selectAll, .clear, .biggerFont, .smallerFont, .actualSizeFont,
             .selectPreviousCommand, .selectNextCommand, .copyOutput, .copyCommand,
             .selectPreviousFailed, .selectNextFailed, .rerunCommand, .find, .findNext, .findPrevious, .useSelectionForFind:
            return .terminal
        }
    }

    /// 1–9 for the Go to Tab actions.
    public var tabNumber: Int? {
        let all: [ShortcutAction] = [.gotoTab1, .gotoTab2, .gotoTab3, .gotoTab4, .gotoTab5, .gotoTab6, .gotoTab7, .gotoTab8, .gotoTab9]
        return all.firstIndex(of: self).map { $0 + 1 }
    }
}

/// The effective shortcut for every action: defaults, with the user's valid overrides applied.
/// Invariants: every shortcut contains ⌘, none is reserved, no two actions share one.
public struct ShortcutMap: Equatable, Sendable {
    private static func s(_ string: String) -> Shortcut { Shortcut(string: string)! }

    public static let defaults: [ShortcutAction: Shortcut] = [
        .newWindow: s("cmd+n"),
        .closeWindow: s("shift+cmd+w"),
        .commandPalette: s("shift+cmd+p"),
        .newTab: s("cmd+t"),
        .closeTab: s("opt+cmd+w"),
        .nextTab: s("shift+cmd+]"),
        .previousTab: s("shift+cmd+["),
        .gotoTab1: s("cmd+1"), .gotoTab2: s("cmd+2"), .gotoTab3: s("cmd+3"),
        .gotoTab4: s("cmd+4"), .gotoTab5: s("cmd+5"), .gotoTab6: s("cmd+6"),
        .gotoTab7: s("cmd+7"), .gotoTab8: s("cmd+8"), .gotoTab9: s("cmd+9"),
        .toggleSidebar: s("cmd+b"),
        .toggleTabLayout: s("ctrl+cmd+s"),
        .splitRight: s("cmd+d"),
        .splitDown: s("shift+cmd+d"),
        .closePane: s("cmd+w"),
        .focusPaneLeft: s("opt+cmd+left"),
        .focusPaneUp: s("opt+cmd+up"),
        .focusPaneRight: s("opt+cmd+right"),
        .focusPaneDown: s("opt+cmd+down"),
        .equalizePanes: s("ctrl+cmd+="),
        .zoomPane: s("shift+cmd+return"),
        .copy: s("cmd+c"),
        .paste: s("cmd+v"),
        .selectAll: s("cmd+a"),
        .clear: s("cmd+k"),
        .biggerFont: s("cmd+="),
        .smallerFont: s("cmd+-"),
        .actualSizeFont: s("cmd+0"),
        .selectPreviousCommand: s("cmd+up"),
        .selectNextCommand: s("cmd+down"),
        .copyOutput: s("opt+cmd+c"),
        .copyCommand: s("shift+cmd+c"),
        .selectPreviousFailed: s("ctrl+cmd+up"),
        .selectNextFailed: s("ctrl+cmd+down"),
        .rerunCommand: s("shift+cmd+r"),
        .find: s("cmd+f"),
        .findNext: s("cmd+g"),
        .findPrevious: s("shift+cmd+g"),
        .useSelectionForFind: s("cmd+e"),
    ]

    /// Fixed menu shortcuts that cannot be assigned: Quit, Hide, Hide Others, Minimize, Settings, Full Screen.
    public static let reserved: Set<Shortcut> = [
        s("cmd+q"), s("cmd+h"), s("opt+cmd+h"), s("cmd+m"), s("cmd+,"), s("ctrl+cmd+f"),
    ]

    private var map: [ShortcutAction: Shortcut]

    public init(overrides: [String: Shortcut]) {
        var map = Self.defaults
        // Apply overrides in a stable order; drop any that break an invariant.
        for action in ShortcutAction.allCases {
            guard let candidate = overrides[action.rawValue],
                  candidate.containsCommand,
                  !Self.reserved.contains(candidate) else { continue }
            map[action] = candidate
        }
        // Resolve duplicates (only possible with a hand-edited file): an action whose override
        // collides with another action's shortcut goes back to its default.
        var changed = true
        while changed {
            changed = false
            for action in ShortcutAction.allCases where map[action] != Self.defaults[action] {
                let mine = map[action]
                if ShortcutAction.allCases.contains(where: { $0 != action && map[$0] == mine }) {
                    map[action] = Self.defaults[action]
                    changed = true
                }
            }
        }
        self.map = map
    }

    public func shortcut(for action: ShortcutAction) -> Shortcut { map[action]! }

    public func action(for shortcut: Shortcut) -> ShortcutAction? {
        ShortcutAction.allCases.first { map[$0] == shortcut }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case missingCommand
        case reserved
        case conflict(ShortcutAction)
    }

    public func validate(_ shortcut: Shortcut, for action: ShortcutAction) -> ValidationError? {
        if !shortcut.containsCommand { return .missingCommand }
        if Self.reserved.contains(shortcut) { return .reserved }
        if let owner = self.action(for: shortcut), owner != action { return .conflict(owner) }
        return nil
    }

    /// Assigns `shortcut` to `action`. If another action has it, that action takes `action`'s
    /// previous shortcut (a swap). Invalid shortcuts change nothing.
    public func assigning(_ shortcut: Shortcut, to action: ShortcutAction) -> ShortcutMap {
        switch validate(shortcut, for: action) {
        case .missingCommand, .reserved:
            return self
        case .conflict(let owner):
            var copy = self
            copy.map[owner] = map[action]
            copy.map[action] = shortcut
            return copy
        case nil:
            var copy = self
            copy.map[action] = shortcut
            return copy
        }
    }

    /// Restores `action`'s default, swapping with whichever action currently has it.
    public func resetting(_ action: ShortcutAction) -> ShortcutMap {
        assigning(Self.defaults[action]!, to: action)
    }

    /// Only the entries that differ from the defaults, keyed by action raw value.
    public var overrides: [String: Shortcut] {
        var out: [String: Shortcut] = [:]
        for action in ShortcutAction.allCases where map[action] != Self.defaults[action] {
            out[action.rawValue] = map[action]
        }
        return out
    }
}
