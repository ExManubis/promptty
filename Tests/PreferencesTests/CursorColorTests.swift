@testable import Preferences
import XCTest

final class CursorColorTests: XCTestCase {
    private func lines(_ s: Settings, accent: UInt32? = nil) -> [String] {
        TerminalConfigWriter.render(s, knownThemes: nil, accentColor: accent).split(separator: "\n").map(String.init)
    }

    func testTheThemesCursorByDefault() {
        XCTAssertEqual(Settings().cursorColor, .theme)
        XCTAssertFalse(lines(Settings()).contains { $0.hasPrefix("cursor-color") || $0.hasPrefix("cursor-text") })
    }

    /// A custom color, with black or white for the character under a block cursor, whichever
    /// reads better on it.
    func testACustomColorAndTheTextUnderIt() {
        var s = Settings()
        s.cursorColor = .custom(0xFFD60A)
        XCTAssertTrue(lines(s).contains("cursor-color = #FFD60A"))
        XCTAssertTrue(lines(s).contains("cursor-text = #000000"))
        s.cursorColor = .custom(0x1E40AF)
        XCTAssertTrue(lines(s).contains("cursor-color = #1E40AF"))
        XCTAssertTrue(lines(s).contains("cursor-text = #FFFFFF"))
    }

    func testTheAccentColorIsTheSystemsOwn() {
        var s = Settings()
        s.cursorColor = .accent
        XCTAssertTrue(lines(s, accent: 0x007AFF).contains("cursor-color = #007AFF"))
        // Unknown (no AppKit to ask): the theme's.
        XCTAssertFalse(lines(s, accent: nil).contains { $0.hasPrefix("cursor-color") })
        XCTAssertEqual(s.resolvedCursorColor(accent: 0x007AFF), 0x007AFF)
    }

    func testSavedAsReadableStrings() throws {
        for color: CursorColor in [.theme, .accent, .custom(0x00FF7F)] {
            var s = Settings()
            s.cursorColor = color
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data).cursorColor, color)
        }
        var s = Settings()
        s.cursorColor = .custom(0x00FF7F)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertTrue(json.contains(##""cursorColor":"#00FF7F""##), json)
    }

    func testAnUnreadableValueIsTheThemesCursor() throws {
        for raw in [#""rainbow""#, ##""#12""##, ##""#GGGGGG""##, "42"] {
            let data = Data((#"{"version":2,"cursorColor":"# + raw + "}").utf8)
            XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data).cursorColor, .theme, raw)
        }
    }
}

final class HexColorInputTests: XCTestCase {
    func testAcceptsTheWaysPeopleWriteHexColors() {
        XCTAssertEqual(CursorColor.parseHex("#FF2D55"), 0xFF2D55)
        XCTAssertEqual(CursorColor.parseHex("ff2d55"), 0xFF2D55)
        XCTAssertEqual(CursorColor.parseHex("  #ff2d55 "), 0xFF2D55)
        XCTAssertEqual(CursorColor.parseHex("#F25"), 0xFF2255, "three digits double up, as in CSS")
        XCTAssertEqual(CursorColor.parseHex("0xFF2D55"), 0xFF2D55)
    }

    func testRejectsWhatIsNotAColor() {
        for text in ["", "#", "#FF2D5", "#FF2D555", "#GG2D55", "red", "#FF 2D55", "-FF2D5"] {
            XCTAssertNil(CursorColor.parseHex(text), text)
        }
    }

    func testFormatsAsUppercaseWithAHash() {
        XCTAssertEqual(CursorColor.formatHex(0xff2d55), "#FF2D55")
        XCTAssertEqual(CursorColor.formatHex(0x00007f), "#00007F")
    }
}
