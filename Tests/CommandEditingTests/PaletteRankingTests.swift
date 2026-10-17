import CommandEditing
import XCTest

final class PaletteRankingTests: XCTestCase {
    private let entries = [
        PaletteRanking.Entry(title: "Split Right", keywords: "Panes"),
        PaletteRanking.Entry(title: "Split Down", keywords: "Panes"),
        PaletteRanking.Entry(title: "New Tab", keywords: "Tabs"),
        PaletteRanking.Entry(title: "api", keywords: "~/Developer/promptty"),
    ]

    func testEmptyQueryKeepsEveryEntryInOrder() {
        XCTAssertEqual(PaletteRanking.rank("", entries), [0, 1, 2, 3])
        XCTAssertEqual(PaletteRanking.rank("  ", entries), [0, 1, 2, 3])
    }

    func testContiguousTitleMatchesComeBeforeFuzzyOnes() {
        XCTAssertEqual(PaletteRanking.rank("down", entries), [1])
        XCTAssertEqual(PaletteRanking.rank("sd", entries), [1])
        XCTAssertEqual(PaletteRanking.rank("split", entries), [0, 1])
    }

    func testTitleMatchesBeatKeywordMatches() {
        // "tab" is New Tab's title and nobody's keyword but its group's.
        XCTAssertEqual(PaletteRanking.rank("tab", entries).first, 2)
        // "promptty" only matches the tab's folder.
        XCTAssertEqual(PaletteRanking.rank("promptty", entries), [3])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(PaletteRanking.rank("NEW", entries), [2])
    }
}
