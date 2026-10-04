import XCTest
@testable import WorkspaceModel

@MainActor
final class TabTests: XCTestCase {
    func testDisplayTitlePrefersCustomTitle() {
        let tab = Tab(title: "zsh", workingDirectory: "/tmp")
        XCTAssertEqual(tab.displayTitle, "zsh")
        tab.customTitle = "build"
        XCTAssertEqual(tab.displayTitle, "build")
    }

    func testEmptyCustomTitleIsTreatedAsNone() {
        let tab = Tab(title: "zsh", workingDirectory: "/tmp")
        tab.customTitle = "   "
        XCTAssertEqual(tab.displayTitle, "zsh")
    }

    func testDisplayTitleStripsControlCharactersAndTruncates() {
        let nasty = "a\u{1B}[31mb\nc\u{07}" + String(repeating: "x", count: 500)
        let tab = Tab(title: nasty, workingDirectory: "/tmp")
        let shown = tab.displayTitle
        XCTAssertFalse(shown.contains("\u{1B}"))
        XCTAssertFalse(shown.contains("\n"))
        XCTAssertFalse(shown.contains("\u{07}"))
        XCTAssertLessThanOrEqual(shown.count, Tab.maxDisplayTitleLength)
        XCTAssertTrue(shown.hasPrefix("a[31mb c"))
    }

    func testBlankTitleFallsBackToShellPlaceholder() {
        let tab = Tab(title: "", workingDirectory: "/tmp")
        XCTAssertEqual(tab.displayTitle, "Terminal")
    }

    func testLineSeparatorDoesNotSplitTitle() {
        let tab = Tab(title: "one\u{2028}two\u{2029}three", workingDirectory: "/tmp")
        let shown = tab.displayTitle
        XCTAssertFalse(shown.unicodeScalars.contains("\u{2028}"))
        XCTAssertFalse(shown.unicodeScalars.contains("\u{2029}"))
        XCTAssertFalse(shown.contains("\n"))
    }

    func testTabMapsToSingleSpace() {
        let tab = Tab(title: "a\tb", workingDirectory: "/tmp")
        XCTAssertEqual(tab.displayTitle, "a b")
    }

    func testLeadingWhitespaceDoesNotCountTowardLength() {
        let tab = Tab(title: String(repeating: " ", count: 100) + "x", workingDirectory: "/tmp")
        XCTAssertEqual(tab.displayTitle, "x")
    }

    func testControlOnlyCustomTitleFallsBackToShellTitle() {
        let tab = Tab(title: "zsh", workingDirectory: "/tmp")
        tab.customTitle = "\u{1B}"
        XCTAssertEqual(tab.displayTitle, "zsh")
    }

    func testAbbreviatedDirectoryReplacesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tab = Tab(title: "zsh", workingDirectory: home + "/Developer/x")
        XCTAssertEqual(tab.abbreviatedDirectory, "~/Developer/x")
        tab.workingDirectory = home
        XCTAssertEqual(tab.abbreviatedDirectory, "~")
        tab.workingDirectory = "/usr/local"
        XCTAssertEqual(tab.abbreviatedDirectory, "/usr/local")
    }
}
