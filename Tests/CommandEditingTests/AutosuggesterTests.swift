import XCTest
@testable import CommandEditing

final class AutosuggesterTests: XCTestCase {
    let history = ["git push --force-with-lease origin main", "git pull", "ls -la"]

    func testSuggestsTheRestOfTheNewestMatch() {
        XCTAssertEqual(Autosuggester.suggestion(for: "git p", history: history), "ush --force-with-lease origin main")
        XCTAssertEqual(Autosuggester.suggestion(for: "ls", history: history), " -la")
    }

    func testNothingForEmptyTextExactMatchesOrNoMatch() {
        XCTAssertNil(Autosuggester.suggestion(for: "", history: history))
        XCTAssertNil(Autosuggester.suggestion(for: "git pull", history: history))
        XCTAssertNil(Autosuggester.suggestion(for: "make", history: history))
    }

    func testSkipsAnExactMatchForALongerOne() {
        XCTAssertEqual(Autosuggester.suggestion(for: "ls", history: ["ls", "ls -la"]), " -la")
    }

    func testNothingForMultiLineText() {
        XCTAssertNil(Autosuggester.suggestion(for: "for x\n", history: ["for x\ndo"]))
    }

    func testFirstWordOfASuggestion() {
        XCTAssertEqual(Autosuggester.firstWord(of: "ush --force-with-lease origin"), "ush")
        XCTAssertEqual(Autosuggester.firstWord(of: " --force-with-lease origin"), " --force-with-lease")
        XCTAssertEqual(Autosuggester.firstWord(of: "  "), "  ")
        XCTAssertEqual(Autosuggester.firstWord(of: ""), "")
    }

    // MARK: Incremental

    func testIncrementalAgreesWithTheStatelessSuggestionWhileTyping() {
        let local = ["make test", "make"]
        let full = ["git push origin", "git pull", "gh pr", "ls -la", "make clean"]
        var s = IncrementalSuggester()
        for text in ["g", "gi", "git", "git p", "git pu", "git pus", "git push", "git push x", "m", "ma", "mak", "make", "make "] {
            XCTAssertEqual(s.suggestion(for: text, local: local, history: full, generation: 1),
                           Autosuggester.suggestion(for: text, local: local, history: full), text)
        }
    }

    func testExtendingATextWithNoMatchDoesNotScanAgain() {
        var s = IncrementalSuggester()
        let full = (0..<1000).map { "command \($0)" }
        XCTAssertNil(s.suggestion(for: "zz", local: [], history: full, generation: 1))
        let scanned = s.scanCount
        XCTAssertEqual(scanned, 1000)
        XCTAssertNil(s.suggestion(for: "zzz", local: [], history: full, generation: 1))
        XCTAssertNil(s.suggestion(for: "zzzz", local: [], history: full, generation: 1))
        XCTAssertEqual(s.scanCount, scanned)
    }

    func testExtendingContinuesFromTheLastMatch() {
        var s = IncrementalSuggester()
        let full = (0..<1000).map { "a\($0)" } + ["b-target"]
        XCTAssertEqual(s.suggestion(for: "b", local: [], history: full, generation: 1), "-target")
        let scanned = s.scanCount
        XCTAssertEqual(scanned, 1001)
        XCTAssertEqual(s.suggestion(for: "b-", local: [], history: full, generation: 1), "target")
        XCTAssertEqual(s.scanCount, scanned + 1, "starts at the previous match, not the top")
    }

    func testTheSameTextAgainDoesNotScan() {
        var s = IncrementalSuggester()
        let full = ["git status"]
        XCTAssertEqual(s.suggestion(for: "git", local: [], history: full, generation: 1), " status")
        let scanned = s.scanCount
        XCTAssertEqual(s.suggestion(for: "git", local: [], history: full, generation: 1), " status")
        XCTAssertEqual(s.scanCount, scanned)
    }

    func testShorteningEditingOrANewGenerationScansAgain() {
        var s = IncrementalSuggester()
        var full = ["git status"]
        XCTAssertNil(s.suggestion(for: "gz", local: [], history: full, generation: 1))
        XCTAssertEqual(s.suggestion(for: "g", local: [], history: full, generation: 1), "it status")
        XCTAssertNil(s.suggestion(for: "gx", local: [], history: full, generation: 1))
        full.insert("gx --help", at: 0)
        XCTAssertEqual(s.suggestion(for: "gx", local: [], history: full, generation: 2), " --help")
        XCTAssertNil(s.suggestion(for: "", local: [], history: full, generation: 2))
        XCTAssertEqual(s.suggestion(for: "g", local: [], history: full, generation: 2), "x --help")
    }

    func testAnEarlierMatchIsStillFoundAfterTheLastOneStopsMatching() {
        var s = IncrementalSuggester()
        let full = ["git push", "git pull"]
        XCTAssertEqual(s.suggestion(for: "git p", local: [], history: full, generation: 1), "ush")
        XCTAssertEqual(s.suggestion(for: "git pul", local: [], history: full, generation: 1), "l")
    }

    func testLocalHistoryStillWinsIncrementally() {
        var s = IncrementalSuggester()
        XCTAssertEqual(s.suggestion(for: "m", local: ["make local"], history: ["make global"], generation: 1), "ake local")
        XCTAssertEqual(s.suggestion(for: "make g", local: ["make local"], history: ["make global"], generation: 1), "lobal")
    }
}
