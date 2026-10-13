import Preferences
import XCTest

final class VimNavigationTests: XCTestCase {
    private func command(_ key: String, _ modifiers: Shortcut.Modifiers) -> VimNavigation.Command? {
        VimNavigation.command(key: key, modifiers: modifiers)
    }

    func testOptionHJKLFocusesPanes() {
        XCTAssertEqual(command("h", .option), .focusPane(.left))
        XCTAssertEqual(command("j", .option), .focusPane(.down))
        XCTAssertEqual(command("k", .option), .focusPane(.up))
        XCTAssertEqual(command("l", .option), .focusPane(.right))
    }

    /// J goes down the tab list, to the next tab; K up, to the previous one. With Shift the
    /// layout reports the capital letter.
    func testOptionShiftJKMovesBetweenTabs() {
        XCTAssertEqual(command("J", [.option, .shift]), .nextTab)
        XCTAssertEqual(command("K", [.option, .shift]), .previousTab)
        XCTAssertEqual(command("j", [.option, .shift]), .nextTab)
    }

    func testOtherKeysAndModifiersAreTheTerminals() {
        XCTAssertNil(command("h", []))
        XCTAssertNil(command("h", .shift))
        XCTAssertNil(command("H", [.option, .shift]), "⌥⇧H and ⌥⇧L stay with the terminal")
        XCTAssertNil(command("l", [.option, .shift]))
        XCTAssertNil(command("h", [.option, .command]))
        XCTAssertNil(command("j", [.option, .control]))
        XCTAssertNil(command("x", .option))
        XCTAssertNil(command("", .option))
    }
}
