import XCTest

/// The debug screen's libghostty surface (`-mirror`): it draws a recording at the recording's grid,
/// and what is typed on it comes out as the bytes a program on the Mac would read.
final class MirrorTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTypingOnTheMirroredSurfaceSendsItsBytes() {
        let app = XCUIApplication()
        app.launchArguments = ["-mirror", "vim"]
        app.launch()

        // Sized to the recording's 54×40, then played.
        let grid = app.staticTexts["mirror.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: grid, label: "54×40"))

        let written = app.staticTexts["mirror.written"]
        // vim's queries were answered: a cursor position report and the background color.
        XCTAssertTrue(wait(for: written, value: "\\e[2;2R"))
        XCTAssertTrue(wait(for: written, value: "\\e]11;rgb:"))

        app.descendants(matching: .any)["mirror.surface"].tap()
        app.typeText("ab")
        app.buttons["mirror.key.ctrl-c"].tap()
        app.buttons["mirror.key.up"].tap()
        app.typeText("\n")
        // Typed text, then ⌃C and ↑ as the Kitty keyboard protocol has them (vim turned on its
        // first level, `\e[=1;1u`), and Return.
        XCTAssertTrue(wait(for: written, value: "ab\\e[99;5u\\e[A\\r"), "sent: \(written.value ?? "")")
    }

    private func wait(for element: XCUIElement, value: String) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", value)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10) == .completed
    }

    private func wait(for element: XCUIElement, label: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10) == .completed
    }
}
