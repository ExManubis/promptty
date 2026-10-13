import XCTest
import GhosttyKit
@testable import GhosttyBridge

final class GhosttyActionTests: XCTestCase {
    private func action(_ tag: ghostty_action_tag_e) -> ghostty_action_s {
        var a = ghostty_action_s()
        a.tag = tag
        return a
    }

    func testSimpleTags() {
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_QUIT)), .quit)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_NEW_WINDOW)), .newWindow)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_NEW_TAB)), .newTab)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_CLOSE_WINDOW)), .closeWindow)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_RENDER)), .render)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_OPEN_CONFIG)), .openConfig)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_CONFIG_CHANGE)), .configChange)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_RING_BELL)), .ringBell)
    }

    func testCloseTabMode() {
        var a = action(GHOSTTY_ACTION_CLOSE_TAB)
        a.action.close_tab_mode = GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER
        XCTAssertEqual(GhosttyAction(a), .closeTab(.others))
    }

    func testGotoTabVariants() {
        var a = action(GHOSTTY_ACTION_GOTO_TAB)
        a.action.goto_tab = GHOSTTY_GOTO_TAB_PREVIOUS
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.previous))
        a.action.goto_tab = GHOSTTY_GOTO_TAB_NEXT
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.next))
        a.action.goto_tab = GHOSTTY_GOTO_TAB_LAST
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.last))
        a.action.goto_tab = ghostty_action_goto_tab_e(rawValue: 3)
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.index(3)))
    }

    func testMoveTab() {
        var a = action(GHOSTTY_ACTION_MOVE_TAB)
        a.action.move_tab.amount = -2
        XCTAssertEqual(GhosttyAction(a), .moveTab(-2))
    }

    func testStringPayloadsAreCopied() {
        var a = action(GHOSTTY_ACTION_SET_TITLE)
        let decoded: GhosttyAction = "hello".withCString { ptr in
            a.action.set_title.title = ptr
            return GhosttyAction(a)
        }
        XCTAssertEqual(decoded, .setTitle("hello"))

        var p = action(GHOSTTY_ACTION_PWD)
        let pwd: GhosttyAction = "/tmp/x".withCString { ptr in
            p.action.pwd.pwd = ptr
            return GhosttyAction(p)
        }
        XCTAssertEqual(pwd, .pwd("/tmp/x"))
    }

    func testNullStringBecomesEmpty() {
        let a = action(GHOSTTY_ACTION_SET_TITLE)
        XCTAssertEqual(GhosttyAction(a), .setTitle(""))
    }

    func testSizes() {
        var a = action(GHOSTTY_ACTION_INITIAL_SIZE)
        a.action.initial_size = ghostty_action_initial_size_s(width: 1200, height: 800)
        XCTAssertEqual(GhosttyAction(a), .initialSize(width: 1200, height: 800))

        var c = action(GHOSTTY_ACTION_CELL_SIZE)
        c.action.cell_size = ghostty_action_cell_size_s(width: 9, height: 20)
        XCTAssertEqual(GhosttyAction(c), .cellSize(width: 9, height: 20))
    }

    func testMouseShapeAndVisibility() {
        var a = action(GHOSTTY_ACTION_MOUSE_SHAPE)
        a.action.mouse_shape = GHOSTTY_MOUSE_SHAPE_TEXT
        XCTAssertEqual(GhosttyAction(a), .mouseShape(.text))
        a.action.mouse_shape = GHOSTTY_MOUSE_SHAPE_ZOOM_IN
        XCTAssertEqual(GhosttyAction(a), .mouseShape(.other))

        var v = action(GHOSTTY_ACTION_MOUSE_VISIBILITY)
        v.action.mouse_visibility = GHOSTTY_MOUSE_HIDDEN
        XCTAssertEqual(GhosttyAction(v), .mouseVisibility(visible: false))
    }

    func testColorChangeKinds() {
        var a = action(GHOSTTY_ACTION_COLOR_CHANGE)
        a.action.color_change = ghostty_action_color_change_s(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, r: 1, g: 2, b: 3)
        XCTAssertEqual(GhosttyAction(a), .colorChange(kind: .background, red: 1, green: 2, blue: 3))
        a.action.color_change.kind = ghostty_action_color_kind_e(rawValue: 7)
        XCTAssertEqual(GhosttyAction(a), .colorChange(kind: .palette(7), red: 1, green: 2, blue: 3))
    }

    func testReloadConfigSoftFlag() {
        var a = action(GHOSTTY_ACTION_RELOAD_CONFIG)
        a.action.reload_config.soft = true
        XCTAssertEqual(GhosttyAction(a), .reloadConfig(soft: true))
    }

    func testChildExitedAndNotification() {
        var a = action(GHOSTTY_ACTION_SHOW_CHILD_EXITED)
        a.action.child_exited = ghostty_surface_message_childexited_s(exit_code: 3, timetime_ms: 1500)
        XCTAssertEqual(GhosttyAction(a), .showChildExited(exitCode: 3, runtimeMs: 1500))

        var n = action(GHOSTTY_ACTION_DESKTOP_NOTIFICATION)
        let decoded: GhosttyAction = "T".withCString { t in
            "B".withCString { b in
                n.action.desktop_notification = ghostty_action_desktop_notification_s(title: t, body: b)
                return GhosttyAction(n)
            }
        }
        XCTAssertEqual(decoded, .desktopNotification(title: "T", body: "B"))
    }

    func testCommandFinished() {
        var a = action(GHOSTTY_ACTION_COMMAND_FINISHED)
        a.action.command_finished = ghostty_action_command_finished_s(exit_code: 1, duration: 2_500_000_000)
        XCTAssertEqual(GhosttyAction(a), .commandFinished(exitCode: 1, durationNs: 2_500_000_000))
        a.action.command_finished = ghostty_action_command_finished_s(exit_code: -1, duration: 0)
        XCTAssertEqual(GhosttyAction(a), .commandFinished(exitCode: -1, durationNs: 0))
    }

    func testScrollbar() {
        var a = action(GHOSTTY_ACTION_SCROLLBAR)
        a.action.scrollbar = ghostty_action_scrollbar_s(total: 500, offset: 120, len: 40)
        XCTAssertEqual(GhosttyAction(a), .scrollbar(total: 500, offset: 120, length: 40))
    }

    func testUnknownTagIsUnhandled() {
        let a = action(GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL)
        XCTAssertEqual(GhosttyAction(a), .unhandled(tag: GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL.rawValue))
        XCTAssertFalse(GhosttyAction(a).isImplemented)
        XCTAssertTrue(GhosttyAction.newTab.isImplemented)
    }

    func testOpenURLUsesItsLengthNotATerminator() {
        var a = action(GHOSTTY_ACTION_OPEN_URL)
        a.action.open_url.kind = GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
        let decoded: GhosttyAction = "https://example.com/abc".withCString { ptr in
            a.action.open_url.url = ptr
            a.action.open_url.len = 19
            return GhosttyAction(a)
        }
        XCTAssertEqual(decoded, .openURL(kind: .text, url: "https://example.com"))
        a.action.open_url.kind = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
        a.action.open_url.url = nil
        a.action.open_url.len = 0
        XCTAssertEqual(GhosttyAction(a), .openURL(kind: .unknown, url: ""))
    }

    func testMouseOverLink() {
        var a = action(GHOSTTY_ACTION_MOUSE_OVER_LINK)
        let over: GhosttyAction = "https://example.com".withCString { ptr in
            a.action.mouse_over_link.url = ptr
            a.action.mouse_over_link.len = 19
            return GhosttyAction(a)
        }
        XCTAssertEqual(over, .mouseOverLink("https://example.com"))
        a.action.mouse_over_link.url = nil
        a.action.mouse_over_link.len = 0
        XCTAssertEqual(GhosttyAction(a), .mouseOverLink(nil))
    }
}
