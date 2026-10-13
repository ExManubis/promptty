import Foundation
import Observation

public struct TabID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

@MainActor
@Observable
public final class Tab {
    public static let maxDisplayTitleLength = 80
    public static let fallbackTitle = "Terminal"

    public let id: TabID
    /// User rename; blank means none.
    public var customTitle: String?
    /// Set for a pinned tab: it stays at the top, cannot be closed, and comes back on relaunch.
    /// Changed through its window, which keeps the pinned tabs first.
    public internal(set) var pin: TabPin?
    /// The sidebar project the tab is in; nil for none. Changed through its window, which keeps
    /// each project's tabs together.
    public internal(set) var projectID: ProjectID?
    /// The tab's layout. Every leaf has an entry in `panes`.
    public private(set) var root: SplitNode
    public private(set) var panes: [PaneID: Pane]
    /// Always a leaf of `root`.
    public private(set) var focusedPaneID: PaneID

    public init(id: TabID = TabID(), title: String, customTitle: String? = nil, workingDirectory: String, paneID: PaneID = PaneID()) {
        self.id = id
        self.customTitle = customTitle
        let pane = Pane(id: paneID, title: title, workingDirectory: workingDirectory)
        root = .leaf(pane.id)
        panes = [pane.id: pane]
        focusedPaneID = pane.id
    }

    public var focusedPane: Pane { panes[focusedPaneID]! }
    /// Title reported by the focused pane's terminal.
    public var title: String { focusedPane.title }
    /// The focused pane's working directory.
    public var workingDirectory: String { focusedPane.workingDirectory }
    public var hasSplits: Bool { panes.count > 1 }

    public func pane(_ id: PaneID) -> Pane? { panes[id] }

    /// Panes in reading order.
    public var orderedPanes: [Pane] { root.leaves.compactMap { panes[$0] } }

    public func focus(_ pane: PaneID) {
        guard panes[pane] != nil else { return }
        focusedPaneID = pane
    }

    /// Splits `pane`, putting a new pane on the `direction` side, and focuses the new pane.
    @discardableResult
    public func split(_ pane: PaneID, direction: SplitDirection, workingDirectory: String) -> Pane {
        let new = Pane(workingDirectory: workingDirectory)
        guard panes[pane] != nil else { return new }
        root = root.splitting(pane, direction: direction, newPane: new.id)
        panes[new.id] = new
        focusedPaneID = new.id
        return new
    }

    /// Closes `pane`. Returns false, changing nothing, when it is the tab's last pane: closing the
    /// tab is the caller's job.
    @discardableResult
    public func closePane(_ pane: PaneID) -> Bool {
        detach(pane) != nil
    }

    /// Removes `pane` without discarding it (for moves). Nil if it is unknown or the last pane.
    public func detach(_ pane: PaneID) -> Pane? {
        guard let removed = panes[pane], let newRoot = root.removing(pane) else { return nil }
        if focusedPaneID == pane {
            focusedPaneID = Self.replacement(for: pane, in: root) ?? newRoot.leaves[0]
        }
        root = newRoot
        panes[pane] = nil
        return removed
    }

    /// Inserts `pane` on `edge` of `target` and focuses it.
    public func attach(_ pane: Pane, at target: PaneID, edge: PaneEdge) {
        guard panes[target] != nil, panes[pane.id] == nil else { return }
        root = root.inserting(pane.id, at: target, edge: edge)
        panes[pane.id] = pane
        focusedPaneID = pane.id
    }

    @discardableResult
    public func moveFocus(_ direction: SplitDirection) -> Bool {
        guard let next = root.neighbor(of: focusedPaneID, direction: direction) else { return false }
        focusedPaneID = next
        return true
    }

    public func setRatio(at path: SplitPath, _ ratio: Double) {
        root = root.resizing(at: path, ratio: ratio)
    }

    public func equalize() { root = root.equalized() }

    /// Replaces every pane with one fresh pane in `workingDirectory` (a pinned tab going back to
    /// its pin). Returns the panes removed, whose terminals the caller frees.
    @discardableResult
    public func reset(workingDirectory: String, startupCommand: String?) -> [PaneID] {
        let removed = orderedPanes.map(\.id)
        let pane = Pane(workingDirectory: workingDirectory, startupCommand: startupCommand)
        root = .leaf(pane.id)
        panes = [pane.id: pane]
        focusedPaneID = pane.id
        return removed
    }

    /// The pane nearest to `pane` in the subtree that takes its place when it is removed from `tree`:
    /// the sibling side's leaf adjacent to the removed pane.
    private static func replacement(for pane: PaneID, in tree: SplitNode) -> PaneID? {
        guard case .split(_, _, let first, let second) = tree else { return nil }
        if case .leaf(let id) = first, id == pane { return second.leaves.first }
        if case .leaf(let id) = second, id == pane { return first.leaves.last }
        if first.contains(pane) { return replacement(for: pane, in: first) }
        if second.contains(pane) { return replacement(for: pane, in: second) }
        return nil
    }

    public var displayTitle: String {
        let custom = Tab.sanitize(customTitle ?? "")
        if !custom.isEmpty { return custom }
        let shell = Tab.sanitize(title)
        return shell.isEmpty ? Tab.fallbackTitle : shell
    }

    /// The tab list's first line. An idle shell titles itself with its directory; showing the
    /// folder name there (and the path below) reads better than the same path twice.
    public var listTitle: String {
        let custom = Tab.sanitize(customTitle ?? "")
        if !custom.isEmpty { return custom }
        let shell = Tab.sanitize(title)
        guard shell.isEmpty || shell == abbreviatedDirectory || shell == workingDirectory else { return shell }
        let dir = abbreviatedDirectory
        if dir == "~" || dir == "/" { return dir }
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty ? dir : name
    }

    /// The tab list's second line, or nil when it would repeat the first.
    public var listSubtitle: String? {
        let dir = abbreviatedDirectory
        return dir == listTitle ? nil : dir
    }

    public var abbreviatedDirectory: String {
        Tab.abbreviate(workingDirectory)
    }

    /// Makes a terminal- or user-supplied title safe to show on one line:
    /// drops line/paragraph separators, control and format scalars (escapes,
    /// bidi overrides, zero-width characters); maps any other whitespace
    /// (tabs, newlines, Unicode spaces) to a single ASCII space, collapsing runs
    /// and trimming both ends; then truncates to `maxDisplayTitleLength` characters.
    static func sanitize(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in s.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .lineSeparator || category == .paragraphSeparator { continue }
            if scalar.properties.isWhitespace || category == .spaceSeparator {
                pendingSpace = !out.isEmpty
                continue
            }
            if category == .control || category == .format { continue }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.unicodeScalars.append(scalar)
        }
        guard out.count > maxDisplayTitleLength else { return out }
        return String(out.prefix(maxDisplayTitleLength))
            .trimmingCharacters(in: .whitespaces)
    }

    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
