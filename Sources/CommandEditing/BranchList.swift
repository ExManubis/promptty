import Foundation

/// The input bar's branch picker: the repository's local branches, newest commit first, filtered
/// by what was typed, with a row to create the typed name when no branch has it.
public struct BranchList: Sendable {
    public enum Row: Hashable, Sendable {
        case branch(String)
        /// `git switch -c` the typed name.
        case create(String)
        /// `git switch --track` a remote branch (`origin/topic`) that has no local branch: offered
        /// when the typed name is exactly its name, in place of creating it from the wrong commit.
        case track(String)
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
    /// Remote branches by their local name (`topic` → `origin/topic`), `origin` preferred.
    private var remote: [String: String] = [:]
    /// Checked out in another worktree: git refuses to switch to them here.
    private var elsewhere: Set<String> = []

    public init(current: String?) {
        self.current = current
    }

    /// The branch names, newest commit first; nil when git could not list them. `remote` names
    /// the remote branches (`origin/topic`); `elsewhere` the branches other worktrees have out.
    public mutating func loaded(_ names: [String]?, remote remoteNames: [String] = [], elsewhere: Set<String> = []) {
        branches = names ?? []
        listing = names == nil ? .unreadable : .loaded
        remote = [:]
        for full in remoteNames {
            guard let slash = full.firstIndex(of: "/") else { continue }
            let name = String(full[full.index(after: slash)...])
            guard name != "HEAD", !name.isEmpty else { continue }
            if remote[name] == nil || full.hasPrefix("origin/") { remote[name] = full }
        }
        self.elsewhere = elsewhere
        refilter()
    }

    public func isCheckedOutElsewhere(_ name: String) -> Bool {
        elsewhere.contains(name)
    }

    /// What ⏎ does: the selected row, if it can be chosen.
    public var choice: Row? {
        selection.flatMap { choice(row: $0) }
    }

    /// Nil for the branch already checked out, and one checked out in another worktree.
    public func choice(row: Int) -> Row? {
        guard rows.indices.contains(row) else { return nil }
        if case .branch(let name) = rows[row], name == current || elsewhere.contains(name) { return nil }
        return rows[row]
    }

    /// Moves to the next row that can be chosen, wrapping around.
    public mutating func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let step = delta >= 0 ? 1 : -1
        var index = selection ?? (step > 0 ? -1 : rows.count)
        for _ in rows.indices {
            index = ((index + step) % rows.count + rows.count) % rows.count
            if choice(row: index) != nil {
                selection = index
                return
            }
        }
    }

    /// The command the bar runs for a row, the name quoted for zsh.
    public static func command(for row: Row) -> String {
        switch row {
        case .branch(let name):
            // Only `git update-ref` makes a name like `-x`; it must not read as an option.
            "git switch " + (name.hasPrefix("-") ? "-- " : "") + ShellQuoting.escape(name, keepLeadingTilde: false)
        case .create(let name): "git switch -c " + ShellQuoting.escape(name, keepLeadingTilde: false)
        case .track(let name): "git switch --track " + ShellQuoting.escape(name, keepLeadingTilde: false)
        }
    }

    /// Whether git accepts `name` for a new branch (the rules of `git check-ref-format --branch`).
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", name != "HEAD", !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
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
        if listing == .loaded, canCreate(query) {
            rows.append(remote[query].map(Row.track) ?? .create(query))
        }
        selection = rows.indices.first { choice(row: $0) != nil }
    }

    /// Whether git can make a branch `name` next to the ones there: on macOS's file system names
    /// differing only in case collide, and `a` cannot be a branch while `a/b` is (or the reverse).
    private func canCreate(_ name: String) -> Bool {
        guard Self.isValidName(name) else { return false }
        let lower = name.lowercased()
        return !branches.contains { branch in
            let other = branch.lowercased()
            return other == lower || other.hasPrefix(lower + "/") || lower.hasPrefix(other + "/")
        }
    }
}

/// The branch picker's listing: `git for-each-ref --sort=-committerdate
/// --format=%(refname)%09%(worktreepath) refs/heads refs/remotes`.
public struct BranchListing: Sendable {
    /// Newest commit first.
    public private(set) var local: [String] = []
    /// `origin/topic`.
    public private(set) var remote: [String] = []
    /// Local branches some worktree has checked out (this one's included), with its path.
    public private(set) var checkedOut: [String: String] = [:]

    public init(forEachRef output: String) {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let ref = String(parts[0])
            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst("refs/heads/".count))
                local.append(name)
                if parts.count > 1, !parts[1].isEmpty { checkedOut[name] = String(parts[1]) }
            } else if ref.hasPrefix("refs/remotes/") {
                remote.append(String(ref.dropFirst("refs/remotes/".count)))
            }
        }
    }

    /// Branches another worktree has out: all checked-out ones but the one here.
    public func checkedOutElsewhere(current: String?) -> Set<String> {
        Set(checkedOut.keys).subtracting(current.map { [$0] } ?? [])
    }
}
