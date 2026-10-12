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
        for bad in ["a b", "-x", "a..b", "a~1", "a^", "a:b", "a?", "a*", "a[b", "a\\b", "a/", "/a", "a//b", ".a", "a/.b",
                    "a.lock", "a.", "@", "a@{b", "a\u{7}", "a\u{7F}"] {
            XCTAssertFalse(BranchList.isValidName(bad), bad)
            XCTAssertFalse(list(query: bad).rows.contains(.create(bad)), bad)
        }
        for good in ["feature/x", "fix-1", "release_2.0", "ünïcode", "a@b", "$x", "a;b"] {
            XCTAssertTrue(BranchList.isValidName(good), good)
        }
    }

    func testTheCurrentBranchCannotBeChosen() {
        var l = list()
        l.moveSelection(by: 1)
        l.moveSelection(by: 1)
        XCTAssertEqual(l.rows[l.selection ?? -1], .branch("main"))
        XCTAssertNil(l.choice)
        XCTAssertNil(list(query: "mai").choice)
    }

    func testMovingTheSelectionWrapsAround() {
        var l = list()
        l.moveSelection(by: -1)
        XCTAssertEqual(l.selection, 4)
        l.moveSelection(by: 1)
        XCTAssertEqual(l.selection, 0)
        XCTAssertEqual(l.choice, .branch("feature/login"))
    }

    func testCommands() {
        XCTAssertEqual(BranchList.command(for: .branch("feature/login")), "git switch feature/login")
        XCTAssertEqual(BranchList.command(for: .create("new")), "git switch -c new")
        XCTAssertEqual(BranchList.command(for: .branch("$(rm -rf ~)")), #"git switch \$\(rm\ -rf\ \~\)"#)
    }

    /// git allows `$`, `;`, backticks and quotes in branch names: zsh must read them as one word.
    func testZshReadsEachCommandAsGitSwitchAndOneName() throws {
        for name in ["a;b", "$HOME", "`touch /tmp/promptty-branch-pwned`", "it's", "a\"b", "a&b", "a|b", "a>b", "#x", "a!b", "é\u{301}$x"] {
            for row in [BranchList.Row.branch(name), .create(name)] {
                let command = BranchList.command(for: row)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-f", "-c", "setopt extendedglob; x=( \(command) ); print -rn -- \"${#x}:${x[-1]}\""]
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                process.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let words = { if case .create = row { 4 } else { 3 } }()
                XCTAssertEqual(out, "\(words):\(name)", command)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/promptty-branch-pwned"))
    }
}
