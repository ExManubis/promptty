import XCTest

/// The demo, driven: open a tab from the sidebar, answer its agent's permission prompt, go back.
final class SmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenATabAndAnswerThePermissionPrompt() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-posture", "compact"]
        app.launch()

        let row = app.buttons["tab.Remote API"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let banner = app.descendants(matching: .any)["permission"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        app.buttons["Yes"].firstMatch.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))

        app.buttons["sidebar"].tap()
        XCTAssertTrue(app.buttons["tab.Remote API"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheActivityListsTheAgents() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-posture", "compact"]
        app.launch()

        let eye = app.buttons["activity"]
        XCTAssertTrue(eye.waitForExistence(timeout: 10))
        eye.tap()
        XCTAssertEqual(eye.value as? String, "on")
        XCTAssertTrue(app.buttons["activity.Remote API"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["activity.Engine patch: pty tap"].exists)
        XCTAssertFalse(app.buttons["tab.nvim"].exists)
    }

    @MainActor
    func testTheGlassControlsTakeTaps() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-posture", "compact", "-open", "zsh"]
        app.launch()

        let command = app.buttons["key.command"]
        XCTAssertTrue(command.waitForExistence(timeout: 10))
        command.tap()
        XCTAssertEqual(command.value as? String, "on")

        app.buttons["sidebar"].tap()
        let search = app.buttons["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mac-switcher"].waitForExistence(timeout: 5))
    }
}

/// Against a Mac's Debug build listening on the loopback address, with a pane labelled `gitlog`:
/// `PROMPTTY_REMOTE_HOST=127.0.0.1` for the Mac, and `TEST_RUNNER_PROMPTTY_LIVE_MAC=1` for
/// `xcodebuild test`. Skipped otherwise.
final class LiveMacTests: XCTestCase {
    @MainActor
    func testRunsACommandOnTheMac() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMPTTY_LIVE_MAC"] == "1", "no Mac to talk to")
        let app = XCUIApplication()
        app.launchArguments = ["-connect", "127.0.0.1", "-requireFaceID", "NO", "-posture", "compact", "-open", "gitlog"]
        app.launch()

        let field = app.textFields["command"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let marker = "hello-from-iphone-\(Int.random(in: 1000...9999))"
        field.tap()
        field.typeText("echo \(marker)\n")
        // The command's block: its line, and its output read back from the Mac (two lines with it).
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker))
        let both = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: lines)
        wait(for: [both], timeout: 15)
    }
}
