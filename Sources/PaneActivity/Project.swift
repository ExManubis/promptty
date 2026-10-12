import Foundation

/// What `Project.find` needs of the file system.
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

/// The project a folder belongs to: its git repository (all worktrees of one repository are one
/// project), or the folder itself outside git.
public struct Project: Equatable, Hashable, Sendable {
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

    public static func find(for directory: String, in files: FileLookup) -> Project {
        var folder = directory
        while true {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            switch files.isFolder(dotGit) {
            case true?:
                return Project(root: folder, branch: branch(in: dotGit, files))
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
                    return Project(root: String(gitDir[..<range.lowerBound]), branch: branch)
                }
                return Project(root: folder, branch: branch)
            case nil:
                break
            }
            guard folder != "/", !folder.isEmpty else { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return Project(root: directory, branch: nil)
    }

    private static func branch(in gitDir: String, _ files: FileLookup) -> String? {
        guard let head = files.read((gitDir as NSString).appendingPathComponent("HEAD")) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }
        return String(line.dropFirst("ref: refs/heads/".count))
    }
}

/// The sidebar's agents, by project: the most urgent project first, then by name; in each, the
/// most urgent agent first.
public enum AgentGroups {
    public struct Item<ID: Hashable>: Equatable {
        public let id: ID
        public let root: String
        public let display: PaneActivity.Display

        public init(id: ID, root: String, display: PaneActivity.Display) {
            self.id = id
            self.root = root
            self.display = display
        }
    }

    public struct Group<ID: Hashable>: Equatable {
        public let root: String
        public let items: [Item<ID>]
        /// The group's most urgent agent.
        public let display: PaneActivity.Display
    }

    public static func group<ID: Hashable>(_ items: [Item<ID>]) -> [Group<ID>] {
        var order: [String] = []
        var byRoot: [String: [Item<ID>]] = [:]
        for item in items {
            if byRoot[item.root] == nil { order.append(item.root) }
            byRoot[item.root, default: []].append(item)
        }
        let groups = order.map { root -> Group<ID> in
            // Stable: equally urgent agents keep their tab order.
            let sorted = byRoot[root]!.enumerated()
                .sorted { a, b in a.element.display != b.element.display ? a.element.display > b.element.display : a.offset < b.offset }
                .map(\.element)
            return Group(root: root, items: sorted, display: sorted.map(\.display).max() ?? .idle)
        }
        return groups.sorted { a, b in
            if a.display != b.display { return a.display > b.display }
            return (a.root as NSString).lastPathComponent.localizedStandardCompare((b.root as NSString).lastPathComponent) == .orderedAscending
        }
    }
}
