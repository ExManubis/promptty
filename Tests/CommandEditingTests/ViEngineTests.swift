import XCTest
@testable import CommandEditing

/// Buffers are written with `|` at the cursor; keys as a string where `⎋` is Escape.
final class ViEngineTests: XCTestCase {
    private func buffer(_ marked: String) -> EditBuffer {
        let cursor = marked.utf16.distance(from: marked.utf16.startIndex, to: marked.firstIndex(of: "|")!.samePosition(in: marked.utf16)!)
        return EditBuffer(text: marked.replacingOccurrences(of: "|", with: ""), cursor: cursor)
    }

    private func marked(_ b: EditBuffer) -> String {
        let ns = b.text as NSString
        return ns.substring(to: b.cursor) + "|" + ns.substring(from: b.cursor)
    }

    @discardableResult
    private func check(_ start: String, _ keys: String, _ expected: String, mode: ViMode = .normal,
                       register: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> ViEngine {
        var engine = ViEngine()
        var b = buffer(start)
        if !keys.hasPrefix("i!") { _ = engine.handle(.escape, buffer: &b); b = buffer(start) }
        for ch in keys.replacingOccurrences(of: "i!", with: "") {
            _ = engine.handle(ch == "⎋" ? .escape : .char(ch), buffer: &b)
        }
        XCTAssertEqual(marked(b), expected, "\(start) + \(keys)", file: file, line: line)
        XCTAssertEqual(engine.mode, mode, "mode after \(keys)", file: file, line: line)
        if let register { XCTAssertEqual(engine.register.text, register, "register", file: file, line: line) }
        return engine
    }

    // MARK: Modes

    func testStartsInInsertModeAndPassesKeysThrough() {
        var engine = ViEngine()
        var b = buffer("ab|")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.handle(.char("x"), buffer: &b), .unhandled)
        XCTAssertEqual(marked(b), "ab|")
    }

    func testEscapeEntersNormalModeAndStepsBack() {
        check("abc|", "i!⎋", "ab|c")
        check("|abc", "i!⎋", "|abc")
        check("ab\n|cd", "i!⎋", "ab\n|cd", mode: .normal)
    }

    func testUnknownKeysAreSwallowedInNormalMode() {
        var engine = ViEngine()
        var b = buffer("a|b")
        _ = engine.handle(.escape, buffer: &b)
        b = buffer("a|b")
        XCTAssertEqual(engine.handle(.char("Q"), buffer: &b), .handled)
        XCTAssertEqual(marked(b), "a|b")
    }

    // MARK: Motions

    func testCharacterMotionsStayOnTheLine() {
        check("ab|c", "h", "a|bc")
        check("|abc", "h", "|abc")
        check("a|bc", "l", "ab|c")
        check("ab|c", "l", "ab|c")
        check("ab|c\nde", "l", "ab|c\nde")
    }

    func testLineMotions() {
        check("  ab|c", "0", "|  abc")
        check("  ab|c", "^", "  |abc")
        check("|abc", "$", "ab|c")
        check("x\n  a|b\ny", "0", "x\n|  ab\ny")
    }

    func testWordMotions() {
        check("|git commit -m x", "w", "git |commit -m x")
        check("|foo.bar baz", "w", "foo|.bar baz")
        check("|foo.bar baz", "W", "foo.bar |baz")
        check("git com|mit", "b", "git |commit")
        check("foo.ba|r", "B", "|foo.bar")
        check("|git commit", "e", "gi|t commit")
        check("gi|t commit", "e", "git commi|t")
        check("|a.b c", "E", "a.|b c")
        check("one |two", "w", "one tw|o")
    }

    func testCounts() {
        check("|a b c d", "3w", "a b c |d")
        check("abcd|e", "3h", "a|bcde")
    }

    func testJAndKMoveBetweenLinesKeepingTheColumn() {
        check("ab|c\nx\nlong", "j", "abc\n|x\nlong")
        check("abc\nx\nl|ong", "k", "abc\n|x\nlong")
    }

    func testJAndKAtTheEdgesWalkHistory() {
        var engine = ViEngine()
        var b = buffer("on|e")
        _ = engine.handle(.escape, buffer: &b)
        XCTAssertEqual(engine.handle(.char("k"), buffer: &b), .historyOlder)
        XCTAssertEqual(engine.handle(.char("j"), buffer: &b), .historyNewer)
        b = buffer("a\n|b")
        XCTAssertEqual(engine.handle(.char("k"), buffer: &b), .handled)
        XCTAssertEqual(marked(b), "|a\nb")
    }

    // MARK: Simple edits

    func testDeleteCharacters() {
        check("a|bc", "x", "a|c", register: "b")
        check("ab|c", "x", "a|b")
        check("a|bcd", "2x", "a|d")
        check("ab|c", "X", "a|c")
        check("|", "x", "|")
    }

    func testReplaceAndToggleCase() {
        check("a|bc", "rX", "a|Xc")
        check("|abC", "3~", "AB|c")
    }

    func testToggleCaseWithCharactersThatChangeLength() {
        check("|ßa", "2~", "SS|A")
    }

    func testDeleteToLineEndOnAnEmptyLineDoesNothing() {
        check("abc\n|\ndef", "d$", "abc\n|\ndef")
        check("abc\n|\ndef", "D", "abc\n|\ndef")
    }

    func testHugeCountsAreCapped() {
        check("|a b", "99999999999999999999w", "a |b")
        check("|a b c", "d99999999999w", "|")
    }

    func testDeleteAndChangeToLineEnd() {
        check("git |commit -m", "D", "git| ", register: "commit -m")
        check("git |commit\nnext", "C", "git |\nnext", mode: .insert)
        check("a|bc", "s", "a|c", mode: .insert)
    }

    func testEnteringInsertMode() {
        check("a|bc", "i", "a|bc", mode: .insert)
        check("a|bc", "a", "ab|c", mode: .insert)
        check("ab|c", "a", "abc|", mode: .insert)
        check("  a|bc", "I", "  |abc", mode: .insert)
        check("a|bc", "A", "abc|", mode: .insert)
        check("a|b\nc", "o", "ab\n|\nc", mode: .insert)
        check("a\nb|c", "O", "a\n|\nbc", mode: .insert)
    }

    func testUndoIsReportedToTheTextView() {
        var engine = ViEngine()
        var b = buffer("a|b")
        _ = engine.handle(.escape, buffer: &b)
        XCTAssertEqual(engine.handle(.char("u"), buffer: &b), .undo)
    }

    // MARK: Operators

    func testDeleteWithMotions() {
        check("git |commit -m", "dw", "git |-m", register: "commit ")
        check("git commit |-m", "dw", "git commit |m", register: "-")
        check("git commit |-m", "dW", "git commit| ", register: "-m")
        check("git com|mit", "db", "git |mit", register: "com")
        check("|git commit", "de", "| commit", register: "git")
        check("git |commit -m", "d$", "git| ", register: "commit -m")
        check("  git |commit", "d0", "|commit", register: "  git ")
        check("|a b c d", "d2w", "|c d")
        check("|a b c d", "2dw", "|c d")
    }

    func testDeleteWordDoesNotJoinLines() {
        check("a |b\nc", "dw", "a| \nc")
    }

    func testChangeWithMotions() {
        check("git |commit -m", "cw", "git | -m", mode: .insert, register: "commit")
        check("git |commit -m", "c$", "git |", mode: .insert)
        check("a |b c", "cb", "|b c", mode: .insert)
    }

    func testYankDoesNotChangeTheText() {
        check("git |commit -m", "yw", "git |commit -m", register: "commit ")
        check("git commit |-m", "y0", "|git commit -m", register: "git commit ")
    }

    func testTextObjects() {
        check("git com|mit -m", "diw", "git | -m", register: "commit")
        check("git com|mit -m", "daw", "git |-m", register: "commit ")
        check("git com|mit", "daw", "gi|t", register: " commit")
        check("echo foo|.bar", "ciw", "echo foo|bar", mode: .insert)
        check("a com|mit b", "yiw", "a |commit b", register: "commit")
    }

    func testLinewiseOperators() {
        check("a\nb|c\nd", "dd", "a\n|d", register: "bc\n")
        check("a\nb|c", "dd", "|a", register: "bc\n")
        check("on|ly", "dd", "|", register: "only\n")
        check("a\n  b|c\nd", "cc", "a\n|\nd", mode: .insert)
        check("a\nb|c", "yy", "a\nb|c", register: "bc\n")
        check("|a\nb\nc", "dj", "|c")
    }

    func testEscapeCancelsAPendingOperator() {
        check("a|bc", "d⎋x", "a|c")
    }

    // MARK: Paste

    func testPasteCharwise() {
        check("|ab cd", "dwP", "ab| cd")
        check("|ab cd", "dwp", "cab| d")
        check("a|b", "yl", "a|b", register: "b")
        check("a|b", "ylp", "ab|b")
    }

    func testPasteLinewise() {
        check("a|b\ncd", "yyjp", "ab\ncd\n|ab")
        check("ab\nc|d", "yykP", "|cd\nab\ncd")
    }
}
