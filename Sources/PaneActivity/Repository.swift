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
/// itself outside git. A tab row shows its branch beside the tab's agent.
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
