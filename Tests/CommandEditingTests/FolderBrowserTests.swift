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

    /// Delivers the browsed folder's listing, as the picker does once it has read the disk; a
    /// folder missing from `tree` cannot be read.
    private func load(_ b: inout FolderBrowser) {
        b.loaded(tree[b.directory], for: b.directory)
    }

    private func browser(at directory: String = "/Users/me") -> FolderBrowser {
        var b = FolderBrowser(directory: directory)
        load(&b)
        return b
    }

    func testListsTheParentThenVisibleFoldersInFinderOrder() {
        let b = browser()
        XCTAssertEqual(b.listing, .loaded)
        XCTAssertEqual(b.rows, [.parent, .folder("Desktop"), .folder("Developer"), .folder("docs"), .folder("downloads")])
        XCTAssertNil(b.selection)
    }

    func testUntilTheListingArrivesOnlyTheParentIsShown() {
        let b = FolderBrowser(directory: "/Users/me")
        XCTAssertEqual(b.listing, .loading)
        XCTAssertEqual(b.rows, [.parent])
    }

    func testAListingForAFolderNoLongerBrowsedIsIgnored() {
        var b = FolderBrowser(directory: "/Users/me")
        b.loaded(["stale"], for: "/somewhere/else")
        XCTAssertEqual(b.listing, .loading)
        XCTAssertEqual(b.rows, [.parent])
    }

    func testAnUnreadableFolderSaysSo() {
        let b = browser(at: "/private")
        XCTAssertEqual(b.listing, .unreadable)
        XCTAssertEqual(b.rows, [.parent])
    }

    func testTheRootHasNoParentRow() {
        XCTAssertEqual(browser(at: "/").rows, [.folder("tmp"), .folder("Users")])
    }

    func testWithNothingSelectedTheChoiceIsTheBrowsedFolder() {
        XCTAssertEqual(browser().choice, "/Users/me")
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
        XCTAssertEqual(b.choice, "/Users/me/downloads")
    }

    func testPrefixMatchesComeBeforeOtherMatches() {
        var b = FolderBrowser(directory: "/x")
        b.loaded(["abc", "cab", "b"], for: "/x")
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

    /// A typo and ⏎ must not run a `cd` to where the pane already is.
    func testNoMatchesMeansNothingToChoose() {
        var b = browser()
        b.query = "zzz"
        XCTAssertEqual(b.rows, [])
        XCTAssertNil(b.selection)
        XCTAssertNil(b.choice)
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
        XCTAssertEqual(b.choice, "/Users")
        b.moveSelection(by: -1)
        XCTAssertEqual(b.selection, 4)
        XCTAssertEqual(b.choice, "/Users/me/downloads")
        b.moveSelection(by: 1)
        XCTAssertEqual(b.selection, 0)
    }

    func testMovingUpFromNothingSelectsTheLastRow() {
        var b = browser()
        b.moveSelection(by: -1)
        XCTAssertEqual(b.selection, 4)
    }

    func testMovingInAnEmptyListDoesNothing() {
        var b = FolderBrowser(directory: "/")
        b.loaded([], for: "/")
        b.moveSelection(by: 1)
        XCTAssertNil(b.selection)
    }

    func testSteppingIntoTheSelectedFolderBrowsesItAndClearsTheFilter() {
        var b = browser()
        b.query = "dev"
        XCTAssertTrue(b.stepIn())
        XCTAssertEqual(b.directory, "/Users/me/Developer")
        XCTAssertEqual(b.query, "")
        XCTAssertEqual(b.listing, .loading)
        load(&b)
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

    func testGoingUpSelectsTheFolderYouCameFromOnceListed() {
        var b = browser(at: "/Users/me/Developer")
        XCTAssertTrue(b.goUp())
        XCTAssertEqual(b.directory, "/Users/me")
        load(&b)
        XCTAssertEqual(b.choice, "/Users/me/Developer")
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

    func testFilteringManyFoldersIsQuick() {
        var b = FolderBrowser(directory: "/big")
        b.loaded((0..<20_000).map { "folder-\($0)" }, for: "/big")
        measure { b.query = b.query == "1" ? "2" : "1" }
        XCTAssertFalse(b.rows.isEmpty)
    }
}

final class DroppedPathTests: XCTestCase {
    private func arg(_ path: String) -> String {
        ShellQuoting.pathArgument(path, directory: "/Users/me/app", home: "/Users/me")
    }

    func testInsideTheFolderIsRelative() {
        XCTAssertEqual(arg("/Users/me/app/Sources/main.swift"), "Sources/main.swift")
        XCTAssertEqual(arg("/Users/me/app/My File.txt"), #"My\ File.txt"#)
        XCTAssertEqual(arg("/Users/me/app"), ".")
    }

    func testUnderHomeStartsWithTilde() {
        XCTAssertEqual(arg("/Users/me/Downloads/report (1).pdf"), #"~/Downloads/report\ \(1\).pdf"#)
        XCTAssertEqual(arg("/Users/me/app-old/x"), "~/app-old/x")
    }

    func testElsewhereIsAbsolute() {
        XCTAssertEqual(arg("/tmp/x y"), #"/tmp/x\ y"#)
    }

    /// `-rf` relative to the folder would read as an option.
    func testANameStartingWithADashIsNotAnOption() {
        XCTAssertEqual(arg("/Users/me/app/-rf"), "./-rf")
    }

    func testZshReadsEachAsThePath() throws {
        let home = "/Users/me"
        for path in ["/Users/me/app/a b", "/Users/me/x$y", "/tmp/it's", "/Users/me/app/-rf", "/tmp/a\nb", "/Users/me/~odd"] {
            let word = arg(path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.environment = ["HOME": home]
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            process.arguments = ["-f", "-c", "x=( \(word) ); print -rn -- \"${#x}:${x[1]}\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // Relative words are relative to the pane's folder.
            let expected = path.hasPrefix("/Users/me/app/") ? String(word.unescapedForTest) : path
            XCTAssertEqual(out, "1:\(expected)", word)
        }
    }
}

private extension String {
    /// What zsh makes of a relative word this file's tests produce: the backslashes go.
    var unescapedForTest: String {
        var out = ""
        var escaped = false
        for ch in self {
            if !escaped, ch == "\\" { escaped = true; continue }
            out.append(ch)
            escaped = false
        }
        return out
    }
}
