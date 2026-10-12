import CommandEditing
import XCTest

final class BranchListTests: XCTestCase {
    /// Newest commit first, as `git for-each-ref --sort=-committerdate` lists them.
    private let recent = ["feature/login", "main", "fix-typo", "Release-2", "spike"]

    private func list(current: String? = "main", query: String = "") -> BranchList {
        var l = BranchList(current: current)
        l.loaded(recent)
        l.query = query
        return l
    }

    func testListsBranchesNewestFirstWithNothingSelected() {
        let l = list()
        XCTAssertEqual(l.listing, .loaded)
        XCTAssertEqual(l.rows, recent.map(BranchList.Row.branch))
        XCTAssertNil(l.selection)
        XCTAssertNil(l.choice)
    }

    func testUntilTheListingArrivesThereAreNoRows() {
        let l = BranchList(current: "main")
        XCTAssertEqual(l.listing, .loading)
        XCTAssertEqual(l.rows, [])
    }

    func testAFailedListingSaysSo() {
        var l = BranchList(current: "main")
        l.loaded(nil)
        XCTAssertEqual(l.listing, .unreadable)
    }

    func testFilteringPutsPrefixMatchesFirstIgnoresCaseAndSelectsTheBest() {
        let l = list(query: "RE")
        XCTAssertEqual(l.rows, [.branch("Release-2"), .branch("feature/login"), .create("RE")])
        XCTAssertEqual(l.selection, 0)
        XCTAssertEqual(l.choice, .branch("Release-2"))
        XCTAssertEqual(list(query: "i").rows.prefix(4), [.branch("feature/login"), .branch("main"), .branch("fix-typo"), .branch("spike")])
    }

    func testANameNoBranchHasOffersToCreateItLast() {
        let l = list(query: "fix")
        XCTAssertEqual(l.rows, [.branch("fix-typo"), .create("fix")])
    }

    func testAnExactMatchOffersNoCreateRow() {
        XCTAssertEqual(list(query: "spike").rows, [.branch("spike")])
    }

    func testWithNoMatchesTheCreateRowIsSelected() {
        let l = list(query: "new-thing")
        XCTAssertEqual(l.rows, [.create("new-thing")])
        XCTAssertEqual(l.choice, .create("new-thing"))
    }

    func testNamesGitWouldRefuseOfferNoCreateRow() {
        for bad in ["HEAD", "a b", "-x", "a..b", "a~1", "a^", "a:b", "a?", "a*", "a[b", "a\\b", "a/", "/a", "a//b", ".a", "a/.b",
                    "a.lock", "a.", "@", "a@{b", "a\u{7}", "a\u{7F}"] {
            XCTAssertFalse(BranchList.isValidName(bad), bad)
            XCTAssertFalse(list(query: bad).rows.contains(.create(bad)), bad)
        }
        for good in ["feature/x", "fix-1", "release_2.0", "ünïcode", "a@b", "$x", "a;b"] {
            XCTAssertTrue(BranchList.isValidName(good), good)
        }
    }

    func testTheCurrentBranchCannotBeChosenAndTheSelectionSkipsIt() {
        var l = list()
        XCTAssertNil(l.choice(row: 1))
        l.moveSelection(by: 1)
        l.moveSelection(by: 1)
        XCTAssertEqual(l.rows[l.selection ?? -1], .branch("fix-typo"))
        l.moveSelection(by: -1)
        XCTAssertEqual(l.rows[l.selection ?? -1], .branch("feature/login"))
    }

    func testFilteringSelectsTheFirstRowThatCanBeChosen() {
        XCTAssertEqual(list(query: "mai").choice, .create("mai"))
        XCTAssertNil(list(query: "main").selection)
        XCTAssertNil(list(query: "main").choice)
    }

    func testWhenTheCurrentBranchIsFirstTheSelectionStartsBelowIt() {
        var l = list(current: "feature/login")
        l.moveSelection(by: 1)
        XCTAssertEqual(l.choice, .branch("main"))
    }

    func testMovingTheSelectionWrapsAround() {
        var l = list()
        l.moveSelection(by: -1)
        XCTAssertEqual(l.selection, 4)
        l.moveSelection(by: 1)
        XCTAssertEqual(l.selection, 0)
        XCTAssertEqual(l.choice, .branch("feature/login"))
    }

    /// macOS's file system ignores case: git refuses `feature` next to a loose `Feature`, and next
    /// to a packed one makes a pair that shadows each other.
    func testNoCreateRowForANameThatDiffersFromABranchOnlyInCase() {
        XCTAssertFalse(list(query: "release-2").rows.contains(.create("release-2")))
        XCTAssertFalse(list(query: "MAIN").rows.contains(.create("MAIN")))
    }

    /// `refs/heads/main` is a file, so `main/y` cannot be one; nor can `feature` be a file while
    /// `feature/login` needs it as a folder.
    func testNoCreateRowForANameThatClashesWithABranchsPath() {
        XCTAssertFalse(list(query: "main/y").rows.contains(.create("main/y")))
        XCTAssertFalse(list(query: "feature").rows.contains(.create("feature")))
        XCTAssertFalse(list(query: "Feature").rows.contains(.create("Feature")))
        XCTAssertTrue(list(query: "feat").rows.contains(.create("feat")))
    }

    /// A branch only on a remote is tracked, not created afresh from the current commit.
    func testANameOnlyARemoteHasIsTrackedNotCreated() {
        var l = BranchList(current: "main")
        l.loaded(recent, remote: ["upstream/topic", "origin/topic", "origin/main", "origin/HEAD"])
        l.query = "topic"
        XCTAssertEqual(l.rows, [.track("origin/topic")])
        XCTAssertEqual(l.choice, .track("origin/topic"))
        l.query = "top"
        XCTAssertEqual(l.rows, [.create("top")])
        l.query = "main"
        XCTAssertEqual(l.rows, [.branch("main")])
    }

    func testBranchesCheckedOutInAnotherWorktreeCannotBeChosen() {
        var l = BranchList(current: "main")
        l.loaded(recent, elsewhere: ["fix-typo"])
        XCTAssertTrue(l.isCheckedOutElsewhere("fix-typo"))
        XCTAssertNil(l.choice(row: 2))
        l.query = "fix"
        XCTAssertEqual(l.choice, .create("fix"))
    }

    func testCommands() {
        XCTAssertEqual(BranchList.command(for: .branch("feature/login")), "git switch feature/login")
        XCTAssertEqual(BranchList.command(for: .create("new")), "git switch -c new")
        XCTAssertEqual(BranchList.command(for: .track("origin/topic")), "git switch --track origin/topic")
        // Only `git update-ref` makes such a name; it must not read as an option.
        XCTAssertEqual(BranchList.command(for: .branch("-x")), "git switch -- -x")
        XCTAssertEqual(BranchList.command(for: .branch("$(rm -rf ~)")), #"git switch \$\(rm\ -rf\ \~\)"#)
    }

    /// git allows `$`, `;`, backticks and quotes in branch names: zsh must read them as one word.
    func testZshReadsEachCommandAsGitSwitchAndOneName() throws {
        for name in ["a;b", "$HOME", "`touch /tmp/promptty-branch-pwned`", "it's", "a\"b", "a&b", "a|b", "a>b", "#x", "a!b", "é\u{301}$x"] {
            for row in [BranchList.Row.branch(name), .create(name), .track(name)] {
                let command = BranchList.command(for: row)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-f", "-c", "setopt extendedglob; x=( \(command) ); print -rn -- \"${#x}:${x[-1]}\""]
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                process.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let words = { if case .branch = row { 3 } else { 4 } }()
                XCTAssertEqual(out, "\(words):\(name)", command)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/promptty-branch-pwned"))
    }
}

final class BranchListingTests: XCTestCase {
    func testSplitsLocalRemoteAndCheckedOutBranches() {
        let output = """
        refs/heads/feature/login\t/repo
        refs/remotes/origin/topic\t
        refs/heads/fix-typo\t/repo-wt
        refs/heads/main\t
        refs/remotes/origin/HEAD\t

        """
        let l = BranchListing(forEachRef: output)
        XCTAssertEqual(l.local, ["feature/login", "fix-typo", "main"])
        XCTAssertEqual(l.remote, ["origin/topic", "origin/HEAD"])
        XCTAssertEqual(l.checkedOut, ["feature/login": "/repo", "fix-typo": "/repo-wt"])
        XCTAssertEqual(l.checkedOutElsewhere(current: "feature/login"), ["fix-typo"])
    }
}
