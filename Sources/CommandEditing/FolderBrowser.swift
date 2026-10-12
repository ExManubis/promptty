import Foundation

/// The input bar's folder picker: the folders of one directory, filtered by what was typed, with
/// a selection to change to or step into.
public struct FolderBrowser {
    public enum Row: Equatable, Sendable {
        /// `..`: the browsed folder's parent.
        case parent
        case folder(String)
    }

    /// The folder being browsed.
    public private(set) var directory: String
    /// Typing filters the folders and selects the best match.
    public var query = "" {
        didSet { refilter() }
    }
    public private(set) var rows: [Row] = []
    /// An index into `rows`; nil means the browsed folder itself.
    public private(set) var selection: Int?

    private let list: (String) -> [String]
    private var folders: [String] = []

    /// `list` gives the names of the folders in a directory.
    public init(directory: String, list: @escaping (String) -> [String]) {
        self.directory = directory
        self.list = list
        load()
    }

    /// Where ⏎ changes to: the selected row, or the browsed folder when nothing is selected.
    public var target: String {
        selection.map { target(row: $0) } ?? directory
    }

    public func target(row: Int) -> String {
        guard rows.indices.contains(row) else { return directory }
        switch rows[row] {
        case .parent: return parent ?? directory
        case .folder(let name): return (directory as NSString).appendingPathComponent(name)
        }
    }

    public mutating func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        guard let selection else {
            self.selection = delta >= 0 ? 0 : rows.count - 1
            return
        }
        self.selection = ((selection + delta) % rows.count + rows.count) % rows.count
    }

    /// Browses the selected row's folder. False when nothing is selected.
    @discardableResult
    public mutating func stepIn() -> Bool {
        guard let selection else { return false }
        return stepIn(row: selection)
    }

    @discardableResult
    public mutating func stepIn(row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if rows[row] == .parent { return goUp() }
        browse(target(row: row))
        return true
    }

    /// Browses the parent, with the folder just left selected. False at the root.
    @discardableResult
    public mutating func goUp() -> Bool {
        guard let parent else { return false }
        let left = (directory as NSString).lastPathComponent
        browse(parent)
        selection = rows.firstIndex(of: .folder(left))
        return true
    }

    private var parent: String? {
        directory == "/" ? nil : (directory as NSString).deletingLastPathComponent
    }

    private mutating func browse(_ path: String) {
        directory = path
        load()
    }

    private mutating func load() {
        folders = list(directory).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if query.isEmpty { refilter() } else { query = "" }
    }

    private mutating func refilter() {
        if query.isEmpty {
            rows = (parent == nil ? [] : [.parent]) + folders.filter { !$0.hasPrefix(".") }.map(Row.folder)
            selection = nil
            return
        }
        let candidates = query.hasPrefix(".") ? folders : folders.filter { !$0.hasPrefix(".") }
        let prefix = candidates.filter { $0.range(of: query, options: [.caseInsensitive, .anchored]) != nil }
        let other = candidates.filter { !prefix.contains($0) && $0.range(of: query, options: .caseInsensitive) != nil }
        rows = (prefix + other).map(Row.folder)
        selection = rows.isEmpty ? nil : 0
    }
}
