import Foundation

/// A tab's panes as they were laid out: each pane's folder and label, and which one had focus. A
/// closed tab keeps it for ⇧⌘T; the session file keeps it, with each pane's scrollback file, for
/// relaunch.
public indirect enum ClosedLayout: Equatable, Sendable {
    case pane(workingDirectory: String, focused: Bool, label: String? = nil, scrollback: String? = nil)
    case split(axis: SplitAxis, ratio: Double, first: ClosedLayout, second: ClosedLayout)

    /// The panes' folders in reading order.
    public var directories: [String] {
        switch self {
        case .pane(let dir, _, _, _): return [dir]
        case .split(_, _, let a, let b): return a.directories + b.directories
        }
    }
}

/// A pane is `{"workingDirectory", "focused", "label"?, "scrollback"?}`, a split
/// `{"axis", "ratio", "first", "second"}`.
extension ClosedLayout: Codable {
    private enum CodingKeys: String, CodingKey { case workingDirectory, focused, label, scrollback, axis, ratio, first, second }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let axis = try c.decodeIfPresent(SplitAxis.self, forKey: .axis) {
            self = .split(axis: axis, ratio: try c.decode(Double.self, forKey: .ratio),
                          first: try c.decode(ClosedLayout.self, forKey: .first), second: try c.decode(ClosedLayout.self, forKey: .second))
        } else {
            self = .pane(workingDirectory: try c.decode(String.self, forKey: .workingDirectory),
                         focused: try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false,
                         label: try c.decodeIfPresent(String.self, forKey: .label),
                         scrollback: try c.decodeIfPresent(String.self, forKey: .scrollback))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let dir, let focused, let label, let scrollback):
            try c.encode(dir, forKey: .workingDirectory)
            try c.encode(focused, forKey: .focused)
            try c.encodeIfPresent(label, forKey: .label)
            try c.encodeIfPresent(scrollback, forKey: .scrollback)
        case .split(let axis, let ratio, let first, let second):
            try c.encode(axis, forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

/// What reopening a closed tab brings back: its name, project, place, panes and pin. Not its
/// output.
public struct ClosedTab: Equatable, Sendable {
    public var customTitle: String?
    public var project: ProjectID?
    /// The window it was in, and where among its tabs.
    public var window: WindowID
    public var index: Int
    public var layout: ClosedLayout
    /// A pinned tab's pin (it was closed with its window): it comes back as its pin.
    public var pin: TabPin?

    public init(customTitle: String?, project: ProjectID?, window: WindowID, index: Int, layout: ClosedLayout, pin: TabPin? = nil) {
        self.customTitle = customTitle; self.project = project; self.window = window; self.index = index; self.layout = layout
        self.pin = pin
    }
}

/// The most recently closed tabs, newest last; ⇧⌘T takes them back in reverse order.
public struct ClosedTabStack: Sendable {
    public static let limit = 10
    private var tabs: [ClosedTab] = []

    public init() {}

    public var isEmpty: Bool { tabs.isEmpty }
    public var count: Int { tabs.count }

    public mutating func push(_ tab: ClosedTab) {
        tabs.append(tab)
        if tabs.count > Self.limit { tabs.removeFirst(tabs.count - Self.limit) }
    }

    public mutating func pop() -> ClosedTab? { tabs.popLast() }
}

extension WindowState {
    /// What reopening `tab` would need; nil for a tab not in this window.
    public func closedTab(_ tab: Tab) -> ClosedTab? {
        guard let index = index(of: tab.id) else { return nil }
        return ClosedTab(customTitle: tab.customTitle, project: project(of: tab), window: id, index: index, layout: tab.closedLayout,
                         pin: tab.pin)
    }

    /// Opens `closed` again in this window, at its old place as near as the groups allow, selected.
    /// A folder that is gone opens `fallbackDirectory`. A project that is gone leaves it in none. A
    /// pinned tab comes back as on relaunch: one pane in its pinned folder, running its command.
    @discardableResult
    public func reopen(
        _ closed: ClosedTab,
        projectExists: (ProjectID) -> Bool,
        directoryExists: (String) -> Bool,
        fallbackDirectory: String = NSHomeDirectory()
    ) -> Tab {
        let project = closed.project.flatMap { projectExists($0) ? $0 : nil }
        if let pin = closed.pin {
            let exists = directoryExists(pin.directory)
            let tab = addTab(title: "", workingDirectory: exists ? pin.directory : fallbackDirectory,
                             customTitle: closed.customTitle, project: project)
            if exists { tab.focusedPane.startupCommand = pin.command }
            self.pin(tab.id, pin, at: closed.index)
            select(id: tab.id)
            return tab
        }
        let first = closed.layout.directories.first ?? fallbackDirectory
        let tab = addTab(title: "", workingDirectory: directoryExists(first) ? first : fallbackDirectory,
                         customTitle: closed.customTitle, project: project)
        tab.restore(closed.layout) { directoryExists($0) ? $0 : fallbackDirectory }
        moveTab(id: tab.id, to: closed.index)
        select(id: tab.id)
        return tab
    }
}
