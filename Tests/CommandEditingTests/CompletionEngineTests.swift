import XCTest
@testable import CommandEditing

private struct FakeSources: CompletionSources {
    var commands: Set<String> = ["git", "grep", "gzip", "ls", "ll", "make"]
    var exports: Set<String> = ["PATH", "PAGER", "HOME"]
    var tree: [String: [(String, Bool)]] = [
        "/repo": [("Sources", true), ("Package.swift", false), ("README.md", false), (".git", true), ("My File.txt", false)],
        "/repo/Sources": [("CommandEditing", true), ("CoreThing", true)],
        "/Users/me": [("Developer", true), ("Desktop", true), ("Documents", true)],
        "/work": [("fixtures", true), ("Firefox", true), ("fx.txt", false), ("lefty", true), ("misc", true), (".fx", true), ("graphics", true)],
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
        XCTAssertEqual(complete("ls ~/De|")?.candidates, ["~/Desktop/", "~/Developer/"])
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

final class DirectoryListingTests: XCTestCase {
    func testSymlinksToFoldersAreFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DirectoryListingTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let listed = root.appendingPathComponent("listed")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: listed, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.txt"))
        try fm.createDirectory(at: listed.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: listed.appendingPathComponent("linked").path, withDestinationPath: target.path)
        try fm.createSymbolicLink(atPath: listed.appendingPathComponent("linkedFile").path,
                                  withDestinationPath: root.appendingPathComponent("file.txt").path)
        try fm.createSymbolicLink(atPath: listed.appendingPathComponent("dangling").path, withDestinationPath: root.appendingPathComponent("gone").path)

        let entries = Dictionary(uniqueKeysWithValues: DirectoryListing.entries(inDirectory: listed.path).map { ($0.name, $0.isDirectory) })
        XCTAssertEqual(entries, ["sub": true, "linked": true, "linkedFile": false, "dangling": false])

        var snapshot = CompletionSnapshot(commands: [], exports: [])
        snapshot.store(DirectoryListing.entries(inDirectory: listed.path), forDirectory: listed.path)
        let complete = { (text: String) in
            CompletionEngine.complete(text: text, cursor: (text as NSString).length, directory: listed.path, home: "/Users/me", sources: snapshot)
        }
        XCTAssertEqual(complete("cd l")?.candidates, ["linked/"])
        XCTAssertEqual(complete("ls linked")?.candidates, ["linked/", "linkedFile"])
        XCTAssertEqual(complete("ls linkedF")?.singleInsertion, "linkedFile ")
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

    private func complete(_ marked: String, _ snapshot: CompletionSnapshot, in directory: String = "/repo") -> [String]? {
        let cursor = (marked as NSString).range(of: "|", options: .backwards).location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        return CompletionEngine.complete(text: text, cursor: cursor, directory: directory, home: "/Users/me", sources: snapshot)?.candidates
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
        snapshot.store([("Sources", true), ("Package.swift", false), ("Podfile", false), (".git", true)], forDirectory: "/repo")
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

    // MARK: cd's folders

    private func folders(_ marked: String, in directory: String = "/work") -> Completion? {
        let cursor = (marked as NSString).range(of: "|", options: .backwards).location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        return CompletionEngine.complete(text: text, cursor: cursor, directory: directory, home: "/Users/me", sources: FakeSources())
    }

    func testCdOffersFoldersOnlyStartingThenContainingThenLettersInOrder() {
        let c = folders("cd f|")
        XCTAssertEqual(c?.candidates, ["Firefox/", "fixtures/", "lefty/"])
        XCTAssertEqual(c?.folders, true)
        XCTAssertEqual(folders("cd fx|")?.candidates, ["Firefox/", "fixtures/"])
    }

    func testSnapshotSortsFoldersOnceWhenStored() {
        var snapshot = CompletionSnapshot(commands: [], exports: [])
        snapshot.store([("zeta", true), ("Alpha", true), ("beta", true), ("alpha.txt", false), (".hidden", true)], forDirectory: "/work")
        XCTAssertEqual(snapshot.sortedFolders(inDirectory: "/work").map(\.name), [".hidden", "Alpha", "beta", "zeta"])
        XCTAssertEqual(snapshot.sortedFolders(inDirectory: "/work").map(\.lower), [".hidden", "alpha", "beta", "zeta"])
        XCTAssertEqual(complete("cd |", snapshot, in: "/work"), ["Alpha/", "beta/", "zeta/"])
        XCTAssertEqual(complete("cd al|", snapshot, in: "/work"), ["Alpha/"])
        // Folders sorted elsewhere (off the main thread) are used as given.
        snapshot.store([("b", true), ("a", true)], folders: [FolderEntry(name: "b"), FolderEntry(name: "a")], forDirectory: "/x")
        XCTAssertEqual(snapshot.sortedFolders(inDirectory: "/x").map(\.name), ["b", "a"])
    }

    func testCdHidesDotFoldersUnlessTypedWithADot() {
        XCTAssertFalse(folders("cd |")?.candidates.contains(".fx/") ?? true)
        XCTAssertEqual(folders("cd .f|")?.candidates, [".fx/"])
    }

    func testCdCompletesInsideATypedFolder() {
        let c = folders("cd Sources/C|", in: "/repo")
        XCTAssertEqual(c?.candidates, ["Sources/CommandEditing/", "Sources/CoreThing/"])
    }

    func testTheFolderPickerIsForCdsArgumentOnly() {
        XCTAssertTrue(CompletionEngine.picksFolder(text: "cd fx", cursor: 5))
        XCTAssertTrue(CompletionEngine.picksFolder(text: "cd ", cursor: 3))
        XCTAssertTrue(CompletionEngine.picksFolder(text: "ls && pushd sr", cursor: 14))
        XCTAssertFalse(CompletionEngine.picksFolder(text: "cd", cursor: 2))
        XCTAssertFalse(CompletionEngine.picksFolder(text: "ls fx", cursor: 5))
        XCTAssertFalse(CompletionEngine.picksFolder(text: "cd -", cursor: 4))
        XCTAssertFalse(CompletionEngine.picksFolder(text: "cd a b", cursor: 6))
    }
}
