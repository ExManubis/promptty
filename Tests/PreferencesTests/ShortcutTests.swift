import XCTest
@testable import Preferences

final class ShortcutTests: XCTestCase {
    func testParsesModifiersAndKey() {
        let s = Shortcut(string: "cmd+shift+d")
        XCTAssertEqual(s?.key, "d")
        XCTAssertEqual(s?.modifiers, [.command, .shift])
    }

    func testCanonicalStringOrdersModifiers() {
        XCTAssertEqual(Shortcut(string: "cmd+ctrl+shift+opt+x")?.string, "ctrl+opt+shift+cmd+x")
        XCTAssertEqual(Shortcut(string: "CMD+D")?.string, "cmd+d")
        XCTAssertEqual(Shortcut(string: "alt+cmd+left")?.string, "opt+cmd+left")
    }

    func testRejectsInvalidStrings() {
        XCTAssertNil(Shortcut(string: ""))
        XCTAssertNil(Shortcut(string: "cmd"))
        XCTAssertNil(Shortcut(string: "cmd+"))
        XCTAssertNil(Shortcut(string: "cmd+ab"))
        XCTAssertNil(Shortcut(string: "cmd+d+e"))
        XCTAssertNil(Shortcut(string: "hyper+d"))
    }

    func testAcceptsNamedKeysAndPunctuation() {
        for name in ["left", "right", "up", "down", "return", "tab", "delete", "escape", "space", "[", "]", "=", "-", ",", "/"] {
            XCTAssertNotNil(Shortcut(string: "cmd+\(name)"), name)
        }
    }

    func testDisplayString() {
        XCTAssertEqual(Shortcut(string: "cmd+shift+d")?.displayString, "⇧⌘D")
        XCTAssertEqual(Shortcut(string: "opt+cmd+left")?.displayString, "⌥⌘←")
        XCTAssertEqual(Shortcut(string: "ctrl+cmd+=")?.displayString, "⌃⌘=")
        XCTAssertEqual(Shortcut(string: "shift+cmd+]")?.displayString, "⇧⌘]")
        XCTAssertEqual(Shortcut(string: "cmd+return")?.displayString, "⌘↩")
    }

    func testCodableAsCanonicalString() throws {
        let s = Shortcut(string: "shift+cmd+d")!
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""shift+cmd+d""#)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), s)
        XCTAssertThrowsError(try JSONDecoder().decode(Shortcut.self, from: Data(#""nope+""#.utf8)))
    }

    func testContainsCommand() {
        XCTAssertTrue(Shortcut(string: "cmd+d")!.containsCommand)
        XCTAssertFalse(Shortcut(string: "ctrl+d")!.containsCommand)
    }
}

final class ShortcutMapTests: XCTestCase {
    private func s(_ string: String) -> Shortcut { Shortcut(string: string)! }

    func testDefaultsCoverEveryActionAndAllUseCommand() {
        for action in ShortcutAction.allCases {
            let shortcut = ShortcutMap.defaults[action]
            XCTAssertNotNil(shortcut, "\(action)")
            XCTAssertTrue(shortcut?.containsCommand ?? false, "\(action)")
        }
    }

    func testDefaultsAreUniqueAndAvoidReserved() {
        let values = ShortcutAction.allCases.compactMap { ShortcutMap.defaults[$0] }
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertTrue(Set(values).isDisjoint(with: ShortcutMap.reserved))
    }

    func testSpecDefaults() {
        let m = ShortcutMap(overrides: [:])
        XCTAssertEqual(m.shortcut(for: .newTab), s("cmd+t"))
        XCTAssertEqual(m.shortcut(for: .closePane), s("cmd+w"))
        XCTAssertEqual(m.shortcut(for: .closeTab), s("opt+cmd+w"))
        XCTAssertEqual(m.shortcut(for: .closeWindow), s("shift+cmd+w"))
        XCTAssertEqual(m.shortcut(for: .splitRight), s("cmd+d"))
        XCTAssertEqual(m.shortcut(for: .splitDown), s("shift+cmd+d"))
        XCTAssertEqual(m.shortcut(for: .focusPaneLeft), s("opt+cmd+left"))
        XCTAssertEqual(m.shortcut(for: .equalizePanes), s("ctrl+cmd+="))
        XCTAssertEqual(m.shortcut(for: .toggleTabLayout), s("ctrl+cmd+s"))
        XCTAssertEqual(m.shortcut(for: .gotoTab9), s("cmd+9"))
        XCTAssertEqual(m.shortcut(for: .clear), s("cmd+k"))
        XCTAssertEqual(m.shortcut(for: .biggerFont), s("cmd+="))
    }

    func testOverrideReplacesDefault() {
        let m = ShortcutMap(overrides: ["splitRight": s("opt+cmd+d")])
        XCTAssertEqual(m.shortcut(for: .splitRight), s("opt+cmd+d"))
        XCTAssertEqual(m.overrides, ["splitRight": s("opt+cmd+d")])
    }

    func testInvalidOrUnknownOverridesAreIgnored() {
        let m = ShortcutMap(overrides: [
            "splitRight": s("ctrl+d"),          // no ⌘
            "splitDown": s("cmd+q"),            // reserved
            "doesNotExist": s("opt+cmd+x"),
        ])
        XCTAssertEqual(m.shortcut(for: .splitRight), s("cmd+d"))
        XCTAssertEqual(m.shortcut(for: .splitDown), s("shift+cmd+d"))
        XCTAssertTrue(m.overrides.isEmpty)
    }

    func testDuplicateOverrideIsDropped() {
        // Hand-edited file gives splitRight the same shortcut as newTab.
        let m = ShortcutMap(overrides: ["splitRight": s("cmd+t")])
        XCTAssertEqual(m.shortcut(for: .newTab), s("cmd+t"))
        XCTAssertEqual(m.shortcut(for: .splitRight), s("cmd+d"))
    }

    func testValidation() {
        let m = ShortcutMap(overrides: [:])
        XCTAssertEqual(m.validate(s("ctrl+d"), for: .splitRight), .missingCommand)
        XCTAssertEqual(m.validate(s("cmd+q"), for: .splitRight), .reserved)
        XCTAssertEqual(m.validate(s("cmd+,"), for: .splitRight), .reserved)
        XCTAssertEqual(m.validate(s("cmd+t"), for: .splitRight), .conflict(.newTab))
        XCTAssertNil(m.validate(s("cmd+d"), for: .splitRight), "its own shortcut is fine")
        XCTAssertNil(m.validate(s("opt+cmd+d"), for: .splitRight))
    }

    func testAssigningSwapsWithConflictingAction() {
        let m = ShortcutMap(overrides: [:]).assigning(s("cmd+t"), to: .splitRight)
        XCTAssertEqual(m.shortcut(for: .splitRight), s("cmd+t"))
        XCTAssertEqual(m.shortcut(for: .newTab), s("cmd+d"))
        // Rebuilding from the stored overrides gives the same map.
        XCTAssertEqual(ShortcutMap(overrides: m.overrides), m)
    }

    func testAssigningInvalidShortcutChangesNothing() {
        let m = ShortcutMap(overrides: [:])
        XCTAssertEqual(m.assigning(s("ctrl+x"), to: .splitRight), m)
        XCTAssertEqual(m.assigning(s("cmd+q"), to: .splitRight), m)
    }

    func testAssigningDefaultBackRemovesOverride() {
        let m = ShortcutMap(overrides: ["splitRight": s("opt+cmd+d")]).assigning(s("cmd+d"), to: .splitRight)
        XCTAssertTrue(m.overrides.isEmpty)
    }

    func testResettingOneAction() {
        let m = ShortcutMap(overrides: ["splitRight": s("opt+cmd+d")]).resetting(.splitRight)
        XCTAssertEqual(m.shortcut(for: .splitRight), s("cmd+d"))
    }

    func testResettingIntoAConflictSwapsBack() {
        // newTab moved to ⌘D (swapping splitRight to ⌘T); resetting newTab restores both.
        let m = ShortcutMap(overrides: [:]).assigning(s("cmd+d"), to: .newTab).resetting(.newTab)
        XCTAssertEqual(m.shortcut(for: .newTab), s("cmd+t"))
        XCTAssertEqual(m.shortcut(for: .splitRight), s("cmd+d"))
    }

    func testActionsHaveTitlesAndGroups() {
        XCTAssertEqual(ShortcutAction.splitRight.title, "Split Right")
        XCTAssertEqual(ShortcutAction.splitRight.group, .panes)
        XCTAssertEqual(ShortcutAction.gotoTab3.title, "Go to Tab 3")
        XCTAssertEqual(ShortcutAction.copy.group, .terminal)
        XCTAssertEqual(ShortcutAction.newWindow.group, .window)
    }
}
