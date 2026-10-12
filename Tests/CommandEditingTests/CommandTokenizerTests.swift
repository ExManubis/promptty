import XCTest
@testable import CommandEditing

final class CommandTokenizerTests: XCTestCase {
    /// (kind, text) pairs, so failures read like the command.
    private func tokens(_ text: String) -> [String] {
        let utf16 = Array(text.utf16)
        return CommandTokenizer.tokenize(text).map { t in
            "\(t.kind):" + String(decoding: utf16[t.range], as: UTF16.self)
        }
    }

    func testCommandFlagsArgumentsAndStrings() {
        XCTAssertEqual(tokens(#"git commit -m "msg" --amend file"#),
                       ["command:git", "argument:commit", "flag:-m", #"string:"msg""#, "flag:--amend", "argument:file"])
    }

    func testOperatorsStartANewCommand() {
        XCTAssertEqual(tokens("ls | grep x && make; echo"),
                       ["command:ls", "op:|", "command:grep", "argument:x", "op:&&", "command:make", "op:;", "command:echo"])
    }

    func testVariables() {
        XCTAssertEqual(tokens("echo $HOME ${PATH} $?"), ["command:echo", "variable:$HOME", "variable:${PATH}", "variable:$?"])
    }

    func testVariablesInsideDoubleQuotes() {
        XCTAssertEqual(tokens(#"echo "hi $USER!""#), ["command:echo", #"string:"hi "#, "variable:$USER", #"string:!""#])
    }

    func testSingleQuotesAndDollarQuotes() {
        XCTAssertEqual(tokens(#"printf 'a $b' $'\n'"#), ["command:printf", "string:'a $b'", #"string:$'\n'"#])
    }

    func testUnterminatedQuoteRunsToTheEnd() {
        XCTAssertEqual(tokens(#"echo "open"#), ["command:echo", #"string:"open"#])
    }

    func testComments() {
        XCTAssertEqual(tokens("ls # list it"), ["command:ls", "comment:# list it"])
        XCTAssertEqual(tokens("echo a#b"), ["command:echo", "argument:a#b"], "# inside a word is not a comment")
    }

    func testRedirectionsKeepTheCommandPosition() {
        XCTAssertEqual(tokens("make 2> err.log >> out"), ["command:make", "op:2>", "argument:err.log", "op:>>", "argument:out"])
    }

    func testAssignmentsBeforeTheCommand() {
        XCTAssertEqual(tokens("FOO=1 BAR=x make"), ["argument:FOO=1", "argument:BAR=x", "command:make"])
    }

    func testQuotedPartOfAWord() {
        XCTAssertEqual(tokens(#"git commit --message="a b""#),
                       ["command:git", "argument:commit", "flag:--message=", #"string:"a b""#])
    }

    func testEscapedSpaceStaysInTheWord() {
        XCTAssertEqual(tokens(#"cat My\ File"#), ["command:cat", #"argument:My\ File"#])
    }

    func testRangesAreUTF16() {
        XCTAssertEqual(tokens("echo 🙂 done"), ["command:echo", "argument:🙂", "argument:done"])
    }

    func testNewlinesStartANewCommand() {
        XCTAssertEqual(tokens("cd x\nls"), ["command:cd", "argument:x", "command:ls"])
    }

    func testSubshellParentheses() {
        XCTAssertEqual(tokens("(cd x)"), ["op:(", "command:cd", "argument:x", "op:)"])
    }
}
