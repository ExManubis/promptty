import Foundation

/// The input bar's folder picker: the folders of one directory, filtered by what was typed, with
/// a selection to change to or step into. Reading the disk is the caller's job (it can be slow: a
/// network share, a huge folder); listings arrive through `loaded(_:for:)`.
public struct FolderBrowser: Sendable {
    public enum Row: Hashable, Sendable {
        /// `..`: the browsed folder's parent.
        case parent
        case folder(String)
    }

    public enum Listing: Equatable, Sendable {
        case loading
        case loaded
        case unreadable
    }

    /// The folder being browsed.
    public private(set) var directory: String
    public private(set) var listing: Listing = .loading
    /// Typing filters the folders and selects the best match.
    public var query = "" {
        didSet { refilter() }
    }
    public private(set) var rows: [Row] = []
    /// An index into `rows`; nil means the browsed folder itself.
    public private(set) var selection: Int?

    private var folders: [String] = []
    /// After going up: the folder just left, selected once the parent is listed.
    private var selectWhenLoaded: String?

    public init(directory: String) {
        self.directory = directory
        refilter()
    }

    /// The names of the folders in `directory`, or nil when it could not be read. Ignored when
    /// another folder is browsed by now.
    public mutating func loaded(_ names: [String]?, for directory: String) {
        guard directory == self.directory else { return }
        folders = (names ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        listing = names == nil ? .unreadable : .loaded
        refilter()
        if let name = selectWhenLoaded, query.isEmpty {
            selection = rows.firstIndex(of: .folder(name))
        }
        selectWhenLoaded = nil
    }

    /// Where ⏎ changes to: the selected row, or the browsed folder when nothing is selected. Nil
    /// when the filter matches nothing: a typo is not a request to stay put.
    public var choice: String? {
        if let selection { return target(row: selection) }
        return query.isEmpty ? directory : nil
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

    /// Browses the parent, with the folder just left selected once listed. False at the root.
    @discardableResult
    public mutating func goUp() -> Bool {
        guard let parent else { return false }
        let left = (directory as NSString).lastPathComponent
        browse(parent)
        selectWhenLoaded = left
        return true
    }

    private var parent: String? {
        directory == "/" ? nil : (directory as NSString).deletingLastPathComponent
    }

    private mutating func browse(_ path: String) {
        directory = path
        folders = []
        listing = .loading
        selectWhenLoaded = nil
        if query.isEmpty { refilter() } else { query = "" }
    }

    private mutating func refilter() {
        if query.isEmpty {
            rows = (parent == nil ? [] : [.parent]) + folders.filter { !$0.hasPrefix(".") }.map(Row.folder)
            selection = nil
            return
        }
        var prefix: [String] = []
        var other: [String] = []
        for name in folders where query.hasPrefix(".") || !name.hasPrefix(".") {
            guard let range = name.range(of: query, options: .caseInsensitive) else { continue }
            if range.lowerBound == name.startIndex { prefix.append(name) } else { other.append(name) }
        }
        rows = (prefix + other).map(Row.folder)
        selection = rows.isEmpty ? nil : 0
    }
}
