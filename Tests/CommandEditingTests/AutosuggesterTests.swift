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
}
