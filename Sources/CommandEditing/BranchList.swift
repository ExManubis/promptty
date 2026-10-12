import Foundation

/// The input bar's branch picker: the repository's local branches, newest commit first, filtered
/// by what was typed, with a row to create the typed name when no branch has it.
public struct BranchList: Sendable {
    public enum Row: Hashable, Sendable {
        case branch(String)
        /// `git switch -c` the typed name.
        case create(String)
    }

    public enum Listing: Equatable, Sendable {
        case loading
        case loaded
        case unreadable
    }

    /// The checked-out branch: marked, and not a choice.
    public let current: String?
    public private(set) var listing: Listing = .loading
    /// Typing filters the branches and selects the best match.
    public var query = "" {
        didSet { refilter() }
    }
    public private(set) var rows: [Row] = []
    /// An index into `rows`; nil when nothing is selected.
    public private(set) var selection: Int?

    private var branches: [String] = []

    public init(current: String?) {
        self.current = current
    }

    /// The branch names, newest commit first; nil when git could not list them.
    public mutating func loaded(_ names: [String]?) {
        branches = names ?? []
        listing = names == nil ? .unreadable : .loaded
        refilter()
    }

    /// What ⏎ does: the selected row, unless that is the branch already checked out.
    public var choice: Row? {
        guard let selection, rows.indices.contains(selection) else { return nil }
        let row = rows[selection]
        return row == .branch(current ?? "") && current != nil ? nil : row
    }

    public func choice(row: Int) -> Row? {
        guard rows.indices.contains(row) else { return nil }
        if let current, rows[row] == .branch(current) { return nil }
        return rows[row]
    }

    public mutating func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        guard let selection else {
            self.selection = delta >= 0 ? 0 : rows.count - 1
            return
        }
        self.selection = ((selection + delta) % rows.count + rows.count) % rows.count
    }

    /// The command the bar runs for a row, the name quoted for zsh.
    public static func command(for row: Row) -> String {
        switch row {
        case .branch(let name): "git switch " + ShellQuoting.escape(name, keepLeadingTilde: false)
        case .create(let name): "git switch -c " + ShellQuoting.escape(name, keepLeadingTilde: false)
        }
    }

    /// Whether git accepts `name` for a new branch (the rules of `git check-ref-format --branch`).
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.contains(".."), !name.contains("//"), !name.contains("@{") else { return false }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || " ~^:?*[\\".unicodeScalars.contains($0) }) {
            return false
        }
        return !name.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
    }

    private mutating func refilter() {
        guard !query.isEmpty else {
            rows = branches.map(Row.branch)
            selection = nil
            return
        }
        rows = PickerFilter.filter(branches, query: query).map(Row.branch)
        if listing == .loaded, !branches.contains(query), Self.isValidName(query) {
            rows.append(.create(query))
        }
        selection = rows.isEmpty ? nil : 0
    }
}
