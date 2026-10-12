import CommandEditing
import XCTest

final class ShellQuotingTests: XCTestCase {
    func testPathsUnderHomeAreWrittenWithTilde() {
        XCTAssertEqual(ShellQuoting.cdCommand(to: "/Users/me/Developer", home: "/Users/me"), "cd ~/Developer")
        XCTAssertEqual(ShellQuoting.cdCommand(to: "/Users/me", home: "/Users/me"), "cd ~")
    }

    func testAPathThatOnlySharesHomesPrefixIsAbsolute() {
        XCTAssertEqual(ShellQuoting.cdCommand(to: "/Users/meg/x", home: "/Users/me"), "cd /Users/meg/x")
    }

    func testSpecialCharactersAreEscaped() {
        XCTAssertEqual(ShellQuoting.cdCommand(to: "/tmp/a b/$x", home: "/Users/me"), #"cd /tmp/a\ b/\$x"#)
        XCTAssertEqual(ShellQuoting.cdCommand(to: "/Users/me/~odd (1)", home: "/Users/me"), #"cd ~/\~odd\ \(1\)"#)
    }

    func testControlCharactersCannotEndTheCommand() {
        XCTAssertEqual(ShellQuoting.cdCommand(to: "/tmp/a\nrm -rf ~", home: "/Users/me"), #"cd $'/tmp/a\nrm -rf ~'"#)
        XCTAssertEqual(ShellQuoting.cdCommand(to: "/Users/me/a\nb", home: "/Users/me"), #"cd ~/$'a\nb'"#)
    }

    /// zsh itself must read each command as `cd` and the one path.
    func testZshReadsTheCommandAsOnePath() throws {
        let paths = [
            "/tmp/a b", "/tmp/$HOME", "/tmp/a\nb", "/tmp/it's", "/tmp/~x", "/tmp/[a]*", "/tmp/a\\b", "/tmp/!x",
            // A special character in one grapheme cluster with a combining mark or a prepend
            // character is still a bare byte to zsh.
            "/tmp/\u{0600}`touch /tmp/promptty-pwned`\u{301}", "/tmp/\"\u{301}", "/tmp/\u{0600}$HOME",
            "/Users/me/~\u{301}x",
            // Glob operators under the options people turn on.
            "/tmp/^foo", "/tmp/a#b", "/tmp/x~y", "/tmp/=ls", "/tmp/%1",
        ]
        for path in paths {
            let command = ShellQuoting.cdCommand(to: path, home: "/Users/me")
            XCTAssertTrue(command.hasPrefix("cd "))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.environment = ["HOME": "/Users/me"]
            process.arguments = ["-f", "-c", "setopt extendedglob; x=( \(command.dropFirst(3)) ); print -rn -- \"${#x}:${x[1]}\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(out, "1:\(path)", "for \(command)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/promptty-pwned"), "for \(command)")
        }
    }
}

final class FolderBrowserTests: XCTestCase {
    private let tree: [String: [String]] = [
        "/": ["Users", "tmp"],
        "/Users": ["me"],
        "/Users/me": ["Developer", "docs", ".config", "Desktop", "downloads"],
        "/Users/me/Developer": ["promptty", "other"],
    ]

    private func browser(at directory: String = "/Users/me") -> FolderBrowser {
        let tree = self.tree
        return FolderBrowser(directory: directory) { tree[$0] ?? [] }
    }

    func testListsTheParentThenVisibleFoldersInFinderOrder() {
        let b = browser()
        XCTAssertEqual(b.rows, [.parent, .folder("Desktop"), .folder("Developer"), .folder("docs"), .folder("downloads")])
        XCTAssertNil(b.selection)
    }

    func testTheRootHasNoParentRow() {
        XCTAssertEqual(browser(at: "/").rows, [.folder("tmp"), .folder("Users")])
    }

    func testWithNothingSelectedTheTargetIsTheBrowsedFolder() {
        XCTAssertEqual(browser().target, "/Users/me")
    }

    func testFilteringPutsPrefixMatchesFirstIgnoresCaseAndSelectsTheBest() {
        var b = browser()
        b.query = "d"
        XCTAssertEqual(b.rows, [.folder("Desktop"), .folder("Developer"), .folder("docs"), .folder("downloads")])
        b.query = "do"
        XCTAssertEqual(b.rows, [.folder("docs"), .folder("downloads")])
        b.query = "OWN"
        XCTAssertEqual(b.rows, [.folder("downloads")])
        XCTAssertEqual(b.selection, 0)
        XCTAssertEqual(b.target, "/Users/me/downloads")
    }

    func testPrefixMatchesComeBeforeOtherMatches() {
        let b0 = FolderBrowser(directory: "/x") { _ in ["abc", "cab", "b"] }
        var b = b0
        b.query = "b"
        XCTAssertEqual(b.rows, [.folder("b"), .folder("abc"), .folder("cab")])
    }

    func testHiddenFoldersShowOnlyWhenTheFilterStartsWithADot() {
        var b = browser()
        b.query = "c"
        XCTAssertEqual(b.rows, [.folder("docs")])
        b.query = ".c"
        XCTAssertEqual(b.rows, [.folder(".config")])
    }

    func testNoMatchesMeansNoSelectionAndTheBrowsedFolder() {
        var b = browser()
        b.query = "zzz"
        XCTAssertEqual(b.rows, [])
        XCTAssertNil(b.selection)
        XCTAssertEqual(b.target, "/Users/me")
    }

    func testClearingTheFilterClearsTheSelection() {
        var b = browser()
        b.query = "doc"
        b.query = ""
        XCTAssertNil(b.selection)
    }

    func testMovingTheSelectionWrapsAround() {
        var b = browser()
        b.moveSelection(by: 1)
        XCTAssertEqual(b.selection, 0)
        XCTAssertEqual(b.target, "/Users")
        b.moveSelection(by: -1)
        XCTAssertEqual(b.selection, 4)
        XCTAssertEqual(b.target, "/Users/me/downloads")
        b.moveSelection(by: 1)
        XCTAssertEqual(b.selection, 0)
    }

    func testMovingUpFromNothingSelectsTheLastRow() {
        var b = browser()
        b.moveSelection(by: -1)
        XCTAssertEqual(b.selection, 4)
    }

    func testMovingInAnEmptyListDoesNothing() {
        var b = FolderBrowser(directory: "/") { _ in [] }
        b.moveSelection(by: 1)
        XCTAssertNil(b.selection)
    }

    func testSteppingIntoTheSelectedFolderListsItAndClearsTheFilter() {
        var b = browser()
        b.query = "dev"
        XCTAssertTrue(b.stepIn())
        XCTAssertEqual(b.directory, "/Users/me/Developer")
        XCTAssertEqual(b.query, "")
        XCTAssertNil(b.selection)
        XCTAssertEqual(b.rows, [.parent, .folder("other"), .folder("promptty")])
    }

    func testSteppingIntoTheParentRowGoesUp() {
        var b = browser()
        b.moveSelection(by: 1)
        XCTAssertTrue(b.stepIn())
        XCTAssertEqual(b.directory, "/Users")
    }

    func testSteppingInWithNothingSelectedDoesNothing() {
        var b = browser()
        XCTAssertFalse(b.stepIn())
        XCTAssertEqual(b.directory, "/Users/me")
    }

    func testGoingUpSelectsTheFolderYouCameFrom() {
        var b = browser(at: "/Users/me/Developer")
        XCTAssertTrue(b.goUp())
        XCTAssertEqual(b.directory, "/Users/me")
        XCTAssertEqual(b.target, "/Users/me/Developer")
        XCTAssertEqual(b.rows[b.selection ?? -1], .folder("Developer"))
    }

    func testGoingUpFromTheRootDoesNothing() {
        var b = browser(at: "/")
        XCTAssertFalse(b.goUp())
        XCTAssertEqual(b.directory, "/")
    }

    func testOpeningARowByIndex() {
        var b = browser()
        XCTAssertTrue(b.stepIn(row: 2))
        XCTAssertEqual(b.directory, "/Users/me/Developer")
        XCTAssertEqual(browser().target(row: 3), "/Users/me/docs")
        XCTAssertEqual(browser().target(row: 0), "/Users")
    }
}
