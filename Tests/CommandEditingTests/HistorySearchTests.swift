import XCTest
@testable import CommandEditing

final class HistorySearchTests: XCTestCase {
    func testEmptyQueryIsNewestFirstWithFolderCommandsOnTop() {
        var search = HistorySearch(newestFirst: ["ls", "make", "git push", "swift test"], folder: ["swift test", "make"])
        XCTAssertEqual(search.search(""), ["swift test", "make", "ls", "git push"])
    }

    func testWithoutFolderInfoItKeepsTheOrderGiven() {
        var search = HistorySearch(newestFirst: ["b", "a", "c"])
        XCTAssertEqual(search.search(""), ["b", "a", "c"])
    }

    func testFuzzyMatchesASubsequenceIgnoringCase() {
        var search = HistorySearch(newestFirst: ["git status", "ls -la", "Git Stash"])
        XCTAssertEqual(search.search("gtst"), ["git status", "Git Stash"])
        XCTAssertEqual(search.search("zzz"), [])
    }

    func testContiguousBeatsScatteredAndAPrefixBeatsTheMiddle() {
        var search = HistorySearch(newestFirst: ["cargo build --test", "echo test", "t e s t", "test all"])
        XCTAssertEqual(search.search("test"), ["test all", "cargo build --test", "echo test", "t e s t"])
    }

    func testFolderCommandsOutrankFuzzyMatchesButNotContiguousOnes() {
        var search = HistorySearch(newestFirst: ["npm run dev", "n p m", "npm test"], folder: ["n p m"])
        XCTAssertEqual(search.search("npm"), ["npm run dev", "npm test", "n p m"])
        // Both are fuzzy-only, so the one run here wins.
        var other = HistorySearch(newestFirst: ["a x b", "a b"], folder: ["a b"])
        XCTAssertEqual(other.search("ab").first, "a b")
    }

    func testAFolderCommandWinsAmongEqualMatches() {
        var search = HistorySearch(newestFirst: ["make a", "make b"], folder: ["make b"])
        XCTAssertEqual(search.search("make"), ["make b", "make a"])
    }

    func testDuplicatesAppearOnce() {
        var search = HistorySearch(newestFirst: ["ls", "pwd", "ls"])
        XCTAssertEqual(search.search(""), ["ls", "pwd"])
    }

    func testResultsAreCapped() {
        var search = HistorySearch(newestFirst: (0..<1000).map { "cmd \($0)" })
        XCTAssertEqual(search.search("cmd").count, HistorySearch.limit)
    }

    func testNarrowingAQueryGivesTheSameAsSearchingFresh() {
        let history = (0..<500).map { "run \($0 % 37) --flag\($0)" }
        var incremental = HistorySearch(newestFirst: history)
        _ = incremental.search("r")
        _ = incremental.search("ru")
        let narrowed = incremental.search("run 3")
        var fresh = HistorySearch(newestFirst: history)
        XCTAssertEqual(narrowed, fresh.search("run 3"))
        // Backspacing widens again.
        var wide = HistorySearch(newestFirst: history)
        XCTAssertEqual(incremental.search("r"), wide.search("r"))
    }
}
