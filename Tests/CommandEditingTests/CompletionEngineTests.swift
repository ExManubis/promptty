import XCTest
@testable import CommandEditing

private struct FakeSources: CompletionSources {
    var commands: Set<String> = ["git", "grep", "gzip", "ls", "ll", "make"]
    var exports: Set<String> = ["PATH", "PAGER", "HOME"]
    var tree: [String: [(String, Bool)]] = [
        "/repo": [("Sources", true), ("Package.swift", false), ("README.md", false), (".git", true), ("My File.txt", false)],
        "/repo/Sources": [("CommandEditing", true), ("CoreThing", true)],
        "/Users/me": [("Developer", true), ("Desktop", true), ("Documents", true)],
    ]
    var branches: [String] = ["main", "mvp", "input-bar"]

    func commandNames() -> Set<String> { commands }
    func exportNames() -> Set<String> { exports }
    func entries(inDirectory path: String) -> [(name: String, isDirectory: Bool)] { (tree[path] ?? []).map { (name: $0.0, isDirectory: $0.1) } }
    func gitBranches(in directory: String) -> [String] { branches }
}

final class CompletionEngineTests: XCTestCase {
    private func complete(_ marked: String, sources: FakeSources = FakeSources()) -> Completion? {
        // The last `|` is the caret (a command may contain pipes).
        let cursor = (marked as NSString).range(of: "|", options: .backwards).location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        return CompletionEngine.complete(text: text, cursor: cursor, directory: "/repo", home: "/Users/me", sources: sources)
    }

    func testCommandNamesInCommandPosition() {
        let c = complete("g|")
        XCTAssertEqual(c?.candidates, ["git", "grep", "gzip"])
        XCTAssertEqual(c?.replacement, 0..<1)
        XCTAssertEqual(c?.commonPrefix, "g")
        XCTAssertEqual(complete("ls | ma|")?.candidates, ["make"])
        XCTAssertEqual(complete("FOO=1 ma|")?.candidates, ["make"])
    }

    func testSingleMatchInsertsWithASpaceUnlessItIsADirectory() {
        XCTAssertEqual(complete("mak|")?.singleInsertion, "make ")
        XCTAssertEqual(complete("cat Sou|")?.singleInsertion, "Sources/")
    }

    func testVariables() {
        XCTAssertEqual(complete("echo $PA|")?.candidates, ["$PAGER", "$PATH"])
        XCTAssertEqual(complete("echo $PA|")?.commonPrefix, "$PA")
    }

    func testGitSubcommands() {
        let c = complete("git ch|")
        XCTAssertEqual(c?.candidates, ["checkout", "cherry", "cherry-pick"])
        XCTAssertEqual(c?.commonPrefix, "che")
    }

    func testGitBranches() {
        XCTAssertEqual(complete("git checkout m|")?.candidates, ["main", "mvp"])
        XCTAssertEqual(complete("git switch inp|")?.candidates, ["input-bar"])
        XCTAssertEqual(complete("git branch -D m|")?.candidates, ["main", "mvp"])
        XCTAssertEqual(complete("git rebase |")?.candidates, ["input-bar", "main", "mvp"])
    }

    func testPathsRelativeToThePaneDirectory() {
        XCTAssertEqual(complete("cat P|")?.candidates, ["Package.swift"])
        XCTAssertEqual(complete("cd Sources/Co|")?.candidates, ["Sources/CommandEditing/", "Sources/CoreThing/"])
        XCTAssertEqual(complete("cd Sources/Co|")?.commonPrefix, "Sources/Co")
        XCTAssertEqual(complete("cd Sources/Co|")?.replacement, 3..<13)
    }

    func testHomeExpansionKeepsTheTilde() {
        XCTAssertEqual(complete("cd ~/De|")?.candidates, ["~/Desktop/", "~/Developer/"])
    }

    func testHiddenEntriesOnlyWithADot() {
        XCTAssertFalse(complete("ls |")?.candidates.contains(".git/") ?? true)
        XCTAssertEqual(complete("ls .g|")?.candidates, [".git/"])
    }

    func testSpacesAreEscaped() {
        XCTAssertEqual(complete("cat My|")?.candidates, [#"My\ File.txt"#])
        XCTAssertEqual(complete(#"cat My\ F|"#)?.candidates, [#"My\ File.txt"#])
    }

    func testNamesWithControlCharactersAreQuotedSoTheyCannotRunAsCommands() {
        var sources = FakeSources()
        sources.tree["/repo"] = [("evil\nrm -rf ~", false), ("tab\there", false), ("bell\u{7}", false)]
        let candidates = complete("cat e|", sources: sources)?.candidates
        XCTAssertEqual(candidates, [#"$'evil\nrm -rf ~'"#])
        XCTAssertEqual(complete("cat t|", sources: sources)?.candidates, [#"$'tab\there'"#])
        XCTAssertEqual(complete("cat b|", sources: sources)?.candidates, [#"$'bell\x07'"#])
        for candidate in [candidates, complete("cat t|", sources: sources)?.candidates].compactMap({ $0 }).flatMap({ $0 }) {
            XCTAssertFalse(candidate.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, candidate)
        }
    }

    func testCompletesTheWordUpToTheCursorOnly() {
        let c = complete("mak| foo")
        XCTAssertEqual(c?.replacement, 0..<3)
    }

    func testNoMatchIsNil() {
        XCTAssertNil(complete("zz|"))
        XCTAssertNil(complete("cat nothing|"))
    }
}

final class GitStatusTests: XCTestCase {
    func testCleanBranch() {
        let s = GitStatus.parse(porcelainV2: "# branch.oid 1234567890abcdef\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0\n")
        XCTAssertEqual(s, GitStatus(branch: "main", dirty: false))
    }

    func testDirty() {
        let s = GitStatus.parse(porcelainV2: "# branch.oid abc\n# branch.head feature/x\n1 .M N... 100644 100644 100644 a b file\n")
        XCTAssertEqual(s, GitStatus(branch: "feature/x", dirty: true))
        XCTAssertEqual(GitStatus.parse(porcelainV2: "# branch.head main\n? new.txt\n")?.dirty, true)
    }

    func testDetachedHeadShowsTheShortHash() {
        let s = GitStatus.parse(porcelainV2: "# branch.oid 1234567890abcdef\n# branch.head (detached)\n")
        XCTAssertEqual(s?.branch, "1234567")
        XCTAssertEqual(s?.detached, true)
        XCTAssertEqual(GitStatus.parse(porcelainV2: "# branch.head main\n")?.detached, false)
    }

    func testNotARepository() {
        XCTAssertNil(GitStatus.parse(porcelainV2: ""))
        XCTAssertNil(GitStatus.parse(porcelainV2: "fatal: not a git repository\n"))
    }
}

/// Completion over a snapshot fetched once: the per-keystroke filtering reads memory only.
final class CompletionSnapshotTests: XCTestCase {
    private func need(_ marked: String) -> CompletionNeed? {
        let cursor = (marked as NSString).range(of: "|", options: .backwards).location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        return CompletionEngine.need(text: text, cursor: cursor, directory: "/repo", home: "/Users/me")
    }

    private func complete(_ marked: String, _ snapshot: CompletionSnapshot) -> [String]? {
        let cursor = (marked as NSString).range(of: "|", options: .backwards).location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        return CompletionEngine.complete(text: text, cursor: cursor, directory: "/repo", home: "/Users/me", sources: snapshot)?.candidates
    }

    func testNeeds() {
        XCTAssertEqual(need("cat |"), .directory("/repo"))
        XCTAssertEqual(need("cat Sou|"), .directory("/repo"))
        XCTAssertEqual(need("cat Sources/Co|"), .directory("/repo/Sources"))
        XCTAssertEqual(need("cat ../|"), .directory("/"))
        XCTAssertEqual(need("cat ~/De|"), .directory("/Users/me"))
        XCTAssertEqual(need("cat /etc/ho|"), .directory("/etc"))
        XCTAssertEqual(need("git switch |"), .gitBranches("/repo"))
        XCTAssertEqual(need("git branch -D m|"), .gitBranches("/repo"))
    }

    func testNoNeedForNamesAndSubcommands() {
        XCTAssertNil(need("g|"))
        XCTAssertNil(need("echo $PA|"))
        XCTAssertNil(need("git ch|"))
    }

    func testTypingWithinOneDirectoryNeedsTheSameListing() {
        XCTAssertEqual(need("cat S|"), need("cat Sour|"))
        XCTAssertNotEqual(need("cat Sources|"), need("cat Sources/|"))
    }

    func testFiltersCachedEntriesPerKeystroke() {
        var snapshot = CompletionSnapshot(commands: [], exports: [])
        XCTAssertFalse(snapshot.has(.directory("/repo")))
        snapshot.listings["/repo"] = [("Sources", true), ("Package.swift", false), ("Podfile", false), (".git", true)]
        XCTAssertTrue(snapshot.has(.directory("/repo")))
        XCTAssertEqual(complete("cat |", snapshot), ["Package.swift", "Podfile", "Sources/"])
        XCTAssertEqual(complete("cat P|", snapshot), ["Package.swift", "Podfile"])
        XCTAssertEqual(complete("cat Pa|", snapshot), ["Package.swift"])
        XCTAssertEqual(complete("cat .|", snapshot), [".git/"])
        XCTAssertNil(complete("cat Z|", snapshot))
    }

    func testBranchesFromTheSnapshot() {
        var snapshot = CompletionSnapshot(commands: ["git"], exports: [])
        XCTAssertNil(complete("git switch m|", snapshot))
        snapshot.branches["/repo"] = ["main", "mvp", "input-bar"]
        XCTAssertTrue(snapshot.has(.gitBranches("/repo")))
        XCTAssertEqual(complete("git switch m|", snapshot), ["main", "mvp"])
    }
}
