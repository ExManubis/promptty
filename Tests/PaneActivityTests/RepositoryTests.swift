import PaneActivity
import XCTest

final class RepositoryTests: XCTestCase {
    /// A fake file system: paths that are folders, and files with their contents.
    private struct FakeFiles: FileLookup {
        var folders: Set<String> = []
        var files: [String: String] = [:]
        func isFolder(_ path: String) -> Bool? {
            if folders.contains(path) { return true }
            if files[path] != nil { return false }
            return nil
        }
        func read(_ path: String) -> String? { files[path] }
    }

    private let fs = FakeFiles(
        folders: ["/src/app", "/src/app/.git", "/src/app/Sources", "/src/app/vendor/lib", "/tmp/plain"],
        files: [
            "/src/app/.git/HEAD": "ref: refs/heads/main\n",
            // A worktree: its .git is a file pointing into the main repository.
            "/src/app-wt/.git": "gitdir: /src/app/.git/worktrees/app-wt\n",
            "/src/app/.git/worktrees/app-wt/HEAD": "ref: refs/heads/feature/login\n",
            // A submodule: its own project.
            "/src/app/vendor/lib/.git": "gitdir: ../../.git/modules/lib\n",
            "/src/app/.git/modules/lib/HEAD": "0123456789abcdef0123456789abcdef01234567\n",
        ]
    )

    func testAFolderInARepositoryBelongsToItsRoot() {
        let p = Repository.find(for: "/src/app/Sources", in: fs)
        XCTAssertEqual(p, Repository(root: "/src/app", branch: "main"))
        XCTAssertEqual(p.name, "app")
    }

    func testAWorktreeBelongsToItsMainRepository() {
        XCTAssertEqual(Repository.find(for: "/src/app-wt/docs", in: fs), Repository(root: "/src/app", branch: "feature/login"))
    }

    /// Paths keep their exact form: `/private/tmp` must not become `/tmp`, or a worktree there
    /// would not group with its repository.
    func testAWorktreeUnderPrivateTmpGroupsWithItsRepository() {
        let files = FakeFiles(
            folders: ["/private/tmp/r", "/private/tmp/r/.git"],
            files: ["/private/tmp/r-wt/.git": "gitdir: /private/tmp/r/.git/worktrees/r-wt\n"]
        )
        XCTAssertEqual(Repository.find(for: "/private/tmp/r-wt", in: files).root, Repository.find(for: "/private/tmp/r", in: files).root)
    }

    func testASubmoduleIsItsOwnProject() {
        XCTAssertEqual(Repository.find(for: "/src/app/vendor/lib", in: fs), Repository(root: "/src/app/vendor/lib", branch: nil))
    }

    func testOutsideGitTheFolderIsTheProject() {
        XCTAssertEqual(Repository.find(for: "/tmp/plain", in: fs), Repository(root: "/tmp/plain", branch: nil))
    }

    func testTheUsualBranchesAreNotWorthShowing() {
        XCTAssertNil(Repository(root: "/a", branch: "main").notableBranch)
        XCTAssertNil(Repository(root: "/a", branch: "master").notableBranch)
        XCTAssertEqual(Repository(root: "/a", branch: "fix-1").notableBranch, "fix-1")
    }
}
