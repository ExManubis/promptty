import Foundation

/// What `Repository.find` needs of the file system.
public protocol FileLookup {
    /// True for a folder, false for a file, nil when nothing is there.
    func isFolder(_ path: String) -> Bool?
    func read(_ path: String) -> String?
}

/// The real file system.
public struct DiskFiles: FileLookup {
    public init() {}

    public func isFolder(_ path: String) -> Bool? {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) ? folder.boolValue : nil
    }

    public func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}

/// The repository a folder belongs to (all worktrees of one repository are one), or the folder
/// itself outside git. Agents in tabs outside any sidebar project are grouped by it.
public struct Repository: Equatable, Hashable, Sendable {
    public let root: String
    /// The branch checked out where the folder is; nil when detached or outside git.
    public let branch: String?

    public init(root: String, branch: String?) {
        self.root = root
        self.branch = branch
    }

    public var name: String { (root as NSString).lastPathComponent }

    /// The branch, unless it is the usual one (`main`, `master`): worth showing beside an agent.
    public var notableBranch: String? {
        guard let branch, branch != "main", branch != "master" else { return nil }
        return branch
    }

    public static func find(for directory: String, in files: FileLookup) -> Repository {
        var folder = directory
        while true {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            switch files.isFolder(dotGit) {
            case true?:
                return Repository(root: folder, branch: branch(in: dotGit, files))
            case false?:
                // A worktree or a submodule: `.git` names the real git folder.
                guard let line = files.read(dotGit), line.hasPrefix("gitdir:") else { break }
                var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !gitDir.hasPrefix("/") { gitDir = (folder as NSString).appendingPathComponent(gitDir) }
                // `..` resolved, nothing else: `standardizingPath` would also turn `/private/tmp`
                // into `/tmp` when that exists, and the worktree would not match its repository.
                gitDir = URL(fileURLWithPath: gitDir).standardized.path
                let branch = branch(in: gitDir, files)
                if let range = gitDir.range(of: "/.git/worktrees/") {
                    return Repository(root: String(gitDir[..<range.lowerBound]), branch: branch)
                }
                return Repository(root: folder, branch: branch)
            case nil:
                break
            }
            guard folder != "/", !folder.isEmpty else { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return Repository(root: directory, branch: nil)
    }

    private static func branch(in gitDir: String, _ files: FileLookup) -> String? {
        guard let head = files.read((gitDir as NSString).appendingPathComponent("HEAD")) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }
        return String(line.dropFirst("ref: refs/heads/".count))
    }
}

/// The sidebar's agents, grouped: first under the projects the user made, in their sidebar order
/// (so the list does not reorder under the pointer); then the agents in no project, by
/// repository, the most urgent repository first, then by name. In each group the most urgent agent
/// comes first.
public enum AgentGroups {
    public enum Key: Hashable, Sendable {
        /// A sidebar project, by an ID the caller chooses (`projectOrder` uses the same).
        case project(String)
        /// A repository, by its root.
        case repository(String)
    }

    public struct Item<ID: Hashable>: Equatable {
        public let id: ID
        public let key: Key
        public let display: PaneActivity.Display

        public init(id: ID, key: Key, display: PaneActivity.Display) {
            self.id = id
            self.key = key
            self.display = display
        }
    }

    public struct Group<ID: Hashable>: Equatable {
        public let key: Key
        public let items: [Item<ID>]
        /// The group's most urgent agent.
        public let display: PaneActivity.Display
    }

    public static func group<ID: Hashable>(_ items: [Item<ID>], projectOrder: [String] = []) -> [Group<ID>] {
        var order: [Key] = []
        var byKey: [Key: [Item<ID>]] = [:]
        for item in items {
            if byKey[item.key] == nil { order.append(item.key) }
            byKey[item.key, default: []].append(item)
        }
        let groups = order.map { key -> Group<ID> in
            // Stable: equally urgent agents keep their tab order.
            let sorted = byKey[key]!.enumerated()
                .sorted { a, b in a.element.display != b.element.display ? a.element.display > b.element.display : a.offset < b.offset }
                .map(\.element)
            return Group(key: key, items: sorted, display: sorted.map(\.display).max() ?? .idle)
        }
        // A project the order does not name (it should not happen) goes after the others.
        let position = Dictionary(projectOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ key: Key) -> Int? {
            guard case .project(let id) = key else { return nil }
            return position[id] ?? projectOrder.count
        }
        let projects = groups.enumerated()
            .filter { rank($0.element.key) != nil }
            .sorted { a, b in rank(a.element.key)! != rank(b.element.key)! ? rank(a.element.key)! < rank(b.element.key)! : a.offset < b.offset }
            .map(\.element)
        let repositories = groups
            .filter { rank($0.key) == nil }
            .sorted { a, b in
                if a.display != b.display { return a.display > b.display }
                return name(a.key).localizedStandardCompare(name(b.key)) == .orderedAscending
            }
        return projects + repositories
    }

    private static func name(_ key: Key) -> String {
        switch key {
        case .project(let id): return id
        case .repository(let root): return (root as NSString).lastPathComponent
        }
    }
}
