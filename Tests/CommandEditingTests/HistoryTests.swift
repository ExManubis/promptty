import XCTest
@testable import CommandEditing

final class ZshHistoryTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> [String] { ZshHistory.parse(Data(bytes)) }
    private func parse(_ text: String) -> [String] { ZshHistory.parse(Data(text.utf8)) }

    func testExtendedFormat() {
        XCTAssertEqual(parse(": 1700000000:0;git status\n: 1700000001:3;make test\n"), ["git status", "make test"])
    }

    func testPlainLines() {
        XCTAssertEqual(parse("ls\ncd ~\n"), ["ls", "cd ~"])
    }

    func testMultiLineEntries() {
        XCTAssertEqual(parse(": 1:0;for x in 1 2\\\ndo echo $x\\\ndone\n: 2:0;ls\n"), ["for x in 1 2\ndo echo $x\ndone", "ls"])
    }

    func testMetafiedBytesAreRestored() {
        // "echo →": → is E2 86 92; zsh writes 0x86 and 0x92 as 0x83 followed by the byte xor 0x20.
        let bytes: [UInt8] = Array(": 1:0;echo ".utf8) + [0xE2, 0x83, 0xA6, 0x83, 0xB2] + [0x0A]
        XCTAssertEqual(parse(bytes), ["echo →"])
    }

    func testPlainUTF8PassesThrough() {
        XCTAssertEqual(parse(": 1:0;echo café\n"), ["echo café"])
    }

    func testBlankLinesAndMissingFinalNewline() {
        XCTAssertEqual(parse("\n: 1:0;a\n\n: 2:0;b"), ["a", "b"])
    }

    func testMalformedExtendedHeaderIsKeptAsText() {
        XCTAssertEqual(parse(": not a header\n"), [": not a header"])
    }
}

final class CommandHistoryTests: XCTestCase {
    func testNewestFirstWithoutDuplicates() {
        var h = CommandHistory(fileEntries: ["ls", "git status", "ls", "make"])
        XCTAssertEqual(h.newestFirst, ["make", "ls", "git status"])
        h.add("git status")
        XCTAssertEqual(h.newestFirst, ["git status", "make", "ls"])
    }

    func testBlankCommandsAreNotAdded() {
        var h = CommandHistory(fileEntries: [])
        h.add("   ")
        h.add("")
        XCTAssertTrue(h.newestFirst.isEmpty)
    }

    func testReplacingFileEntriesKeepsSessionCommandsOnTop() {
        var h = CommandHistory(fileEntries: ["a"])
        h.add("mine")
        h.replaceFileEntries(["a", "b"])
        XCTAssertEqual(h.newestFirst, ["mine", "b", "a"])
    }
}

final class HistoryNavigatorTests: XCTestCase {
    func testWalksOlderThenBackToTheDraft() {
        var n = HistoryNavigator(history: ["make", "ls"])
        XCTAssertEqual(n.older(current: "draft"), "make")
        XCTAssertEqual(n.older(current: "make"), "ls")
        XCTAssertNil(n.older(current: "ls"), "no older entry")
        XCTAssertEqual(n.newer(), "make")
        XCTAssertEqual(n.newer(), "draft")
        XCTAssertNil(n.newer(), "already at the draft")
    }

    func testEmptyHistory() {
        var n = HistoryNavigator(history: [])
        XCTAssertNil(n.older(current: "x"))
        XCTAssertNil(n.newer())
    }

    func testIsBrowsing() {
        var n = HistoryNavigator(history: ["a"])
        XCTAssertFalse(n.isBrowsing)
        _ = n.older(current: "")
        XCTAssertTrue(n.isBrowsing)
        _ = n.newer()
        XCTAssertFalse(n.isBrowsing)
    }
}
